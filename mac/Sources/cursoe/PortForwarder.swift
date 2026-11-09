import Foundation
import Network

/// Dipanggil BridgeClient dari antrean jaringannya.
protocol TunnelHandler: AnyObject {
    func tunnelSessionStarted()
    func tunnelSessionEnded()
    func handleTunnelMessage(_ type: String, _ message: Message)
    func handleTunnelData(_ id: UInt32, _ data: Data)
}

/// Port forwarding: `localhost:PORT` di HP → `localhost:PORT` di Mac, lewat koneksi Cursoe yang terenkripsi
/// (kabel, hotspot, atau Wi-Fi). Seperti `adb reverse`, tanpa adb.
///
/// HP membuka port yang sama di 127.0.0.1. Setiap koneksi masuk di HP (mis. dari Chrome) menjadi satu aliran
/// yang di Mac disambungkan ke `localhost:PORT`. Mac hanya menerima port yang didaftarkan pengguna di menu.
///
/// Protokol:  FORWARD {ports} (Mac → HP)  ·  TUNNEL_OPEN {id, port} (HP → Mac)
///            data: frame biner [0x02][id UInt32 big-endian][data] (dua arah)
///            TUNNEL_EOF {id} (dua arah): pengirim selesai mengirim (half-close, seperti TCP); aliran selesai bila
///            kedua arah EOF. TUNNEL_CLOSE {id} (dua arah): batalkan aliran (galat).
/// Laju: potongan berikutnya dari server lokal baru dibaca setelah potongan sebelumnya diproses jaringan, jadi
/// pesan kursor tetap bisa menyelip saat halaman besar sedang dimuat.
final class PortForwarder: TunnelHandler {
    static let binaryMarker: UInt8 = 0x02
    /// Android tidak mengizinkan aplikasi membuka port di bawah 1024.
    static let allowedPorts = 1024...65535
    private static let chunkBytes = 32 * 1024
    private static let defaultsKey = "forwardPorts"

    private let client: BridgeClient
    private let queue = DispatchQueue(label: "dev.cursoe.forward", qos: .userInitiated)
    private let lock = NSLock()
    private var storedPorts: [Int]
    private final class Stream {
        let connection: NWConnection
        var ready = false      // sudah tersambung ke server lokal
        var serverDone = false // server lokal di Mac selesai mengirim
        var clientDone = false // aplikasi di HP selesai mengirim
        init(_ connection: NWConnection) { self.connection = connection }
    }

    private var streams: [UInt32: Stream] = [:]

    init(client: BridgeClient) {
        self.client = client
        let saved = UserDefaults.standard.array(forKey: Self.defaultsKey) as? [Int] ?? []
        storedPorts = saved.filter { Self.allowedPorts.contains($0) }
    }

    /// Port yang diteruskan, urut naik.
    var ports: [Int] {
        lock.lock()
        defer { lock.unlock() }
        return storedPorts
    }

    func add(_ port: Int) {
        guard Self.allowedPorts.contains(port) else { return }
        update { ports in if !ports.contains(port) { ports.append(port); ports.sort() } }
    }

    func remove(_ port: Int) {
        update { ports in ports.removeAll { $0 == port } }
    }

    private func update(_ change: (inout [Int]) -> Void) {
        lock.lock()
        change(&storedPorts)
        let current = storedPorts
        lock.unlock()
        UserDefaults.standard.set(current, forKey: Self.defaultsKey)
        Log.info("Port forwarding: \(current.isEmpty ? "mati" : current.map(String.init).joined(separator: ", "))")
        client.send(["t": "FORWARD", "ports": current]) // diabaikan bila belum terhubung; dikirim lagi saat tersambung
    }

    // MARK: TunnelHandler (antrean BridgeClient)

    func tunnelSessionStarted() {
        queue.async { self.closeAll() }
        client.sendOnQueue(["t": "FORWARD", "ports": ports])
    }

    func tunnelSessionEnded() {
        queue.async { self.closeAll() }
    }

    func handleTunnelMessage(_ type: String, _ message: Message) {
        guard let raw = message.int("id"), let id = UInt32(exactly: raw) else { return }
        switch type {
        case "TUNNEL_OPEN":
            let port = message.int("port") ?? 0
            queue.async { self.open(id, port: port) }
        case "TUNNEL_EOF":
            queue.async { self.clientFinished(id) }
        case "TUNNEL_CLOSE":
            queue.async { self.close(id, notify: false) }
        default:
            break
        }
    }

    func handleTunnelData(_ id: UInt32, _ data: Data) {
        queue.async {
            guard let connection = self.streams[id]?.connection else { return }
            connection.send(content: data, completion: .contentProcessed { [weak self] error in
                guard error != nil else { return }
                self?.queue.async { self?.close(id, notify: true) }
            })
        }
    }

    // MARK: Aliran (antrean `queue`)

    private func open(_ id: UInt32, port: Int) {
        guard ports.contains(port), let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            Log.info("Tunnel #\(id) ditolak: port \(port) tidak diteruskan")
            client.send(["t": "TUNNEL_CLOSE", "id": Int(id)])
            return
        }
        // "localhost" (bukan 127.0.0.1): server dev modern (mis. Vite/Node) sering hanya mendengarkan di ::1.
        let connection = NWConnection(host: "localhost", port: nwPort, using: .tcp)
        streams[id] = Stream(connection)
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            guard let stream = self.streams[id], stream.connection === connection else { return }
            switch state {
            case .ready:
                Log.debug("Tunnel #\(id) → localhost:\(port) tersambung")
                stream.ready = true
                self.receive(id, connection)
            case .waiting(let error), .failed(let error):
                if stream.ready {
                    // Sesudah tersambung, galat di sini biasanya akhir koneksi (server sudah menutup). Jangan batalkan:
                    // data yang sudah dibaca masih dikirim ke HP; penerima (receive) menutup aliran dengan rapi.
                    Log.debug("Tunnel #\(id) → localhost:\(port) berakhir: \(error)")
                } else {
                    // Mis. tidak ada server di port itu (connection refused): jangan menunggu, tutup aliran.
                    Log.info("Tunnel #\(id) → localhost:\(port) gagal: \(error)")
                    self.close(id, notify: true)
                }
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func receive(_ id: UInt32, _ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: Self.chunkBytes) { [weak self] data, _, isComplete, error in
            guard let self, self.streams[id]?.connection === connection else { return }
            // Galat saat membaca = server tidak akan mengirim lagi: perlakukan sebagai akhir (EOF), bukan pembatalan,
            // agar data yang sudah terkirim ke HP tidak terbuang.
            let finished = isComplete || error != nil
            guard let data, !data.isEmpty else {
                if finished { self.serverFinished(id) } else { self.receive(id, connection) }
                return
            }
            var frame = Data([Self.binaryMarker])
            withUnsafeBytes(of: id.bigEndian) { frame.append(contentsOf: $0) }
            frame.append(data)
            self.client.sendTunnelData(frame) { [weak self] in
                self?.queue.async {
                    guard let self, self.streams[id]?.connection === connection else { return }
                    if finished { self.serverFinished(id) } else { self.receive(id, connection) }
                }
            }
        }
    }

    /// Server lokal selesai mengirim: kabari HP (aplikasi di sana menerima EOF), tetap terima dari HP.
    private func serverFinished(_ id: UInt32) {
        guard let stream = streams[id] else { return }
        stream.serverDone = true
        client.send(["t": "TUNNEL_EOF", "id": Int(id)])
        if stream.clientDone { close(id, notify: false) }
    }

    /// Aplikasi di HP selesai mengirim: tutup sisi kirim ke server lokal (FIN), tetap terima balasannya.
    private func clientFinished(_ id: UInt32) {
        guard let stream = streams[id] else { return }
        stream.clientDone = true
        stream.connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .idempotent)
        if stream.serverDone { close(id, notify: false) }
    }

    private func close(_ id: UInt32, notify: Bool) {
        guard let stream = streams.removeValue(forKey: id) else { return }
        stream.connection.stateUpdateHandler = nil
        stream.connection.cancel()
        if notify { client.send(["t": "TUNNEL_CLOSE", "id": Int(id)]) }
    }

    private func closeAll() {
        for stream in streams.values {
            stream.connection.stateUpdateHandler = nil
            stream.connection.cancel()
        }
        streams.removeAll()
    }
}
