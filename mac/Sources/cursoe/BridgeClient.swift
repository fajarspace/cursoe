import Foundation
import Network
import SystemConfiguration

struct ScreenInfo: Equatable {
    var width: Int
    var height: Int
    var density: Double
    var cursorReady: Bool  // AccessibilityService Cursoe aktif di HP
    var keyboardReady: Bool // "Cursoe Keyboard" sudah diaktifkan di HP
}

enum LinkState: Equatable {
    case searching
    case connecting(String)
    case awaitingPin(String)
    case connected(String)
    case paused(String)  // butuh tindakan pengguna
}

/// Pilihan jalur koneksi (menu Koneksi).
enum ConnectionMode: String {
    case auto      // kabel USB bila tersedia, selain itu Wi-Fi/hotspot
    case usb       // hanya kabel USB (tethering USB, cadangan: USB debugging)
    case wireless  // hanya Wi-Fi/hotspot (Bonjour + IP manual)
}

/// Jalur koneksi yang sedang dipakai.
enum Transport {
    case bonjour, manual, usb

    var label: String {
        switch self {
        case .bonjour: return "Wi-Fi/hotspot"
        case .manual: return L("manual IP", "IP manual")
        case .usb: return L("USB cable", "kabel USB")
        }
    }
}

struct LinkSnapshot {
    var state: LinkState = .searching
    var screen: ScreenInfo?
    var rttMs: Int?
    var transport: Transport?
    var usbStatus = L("checking…", "memeriksa…")
}

private struct MacIdentity {
    let id: String
    let name: String

    static func load() -> MacIdentity {
        let defaults = UserDefaults.standard
        let id: String
        if let saved = defaults.string(forKey: "macId") {
            id = saved
        } else {
            id = UUID().uuidString
            defaults.set(id, forKey: "macId")
        }
        let name = (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? Host.current().localizedName ?? "Mac"
        return MacIdentity(id: id, name: name)
    }
}

/// Satu koneksi TCP ke HP beserta state handshake-nya.
private final class Session {
    let connection: NWConnection
    let transport: Transport
    var name: String
    var deviceId: String?
    let handshake = Handshake()
    var hello = Data()
    var channel: SecureChannel?
    var token: Data?
    var authenticated = false
    var viable = true
    var rttSamples: [Int] = []
    var lastReceived = DispatchTime.now()

    init(connection: NWConnection, transport: Transport, name: String, deviceId: String?) {
        self.connection = connection
        self.transport = transport
        self.name = name
        self.deviceId = deviceId
    }
}

/// Discovery (Bonjour), koneksi, handshake terenkripsi, pairing, dan keep-alive.
/// Semua state hanya disentuh dari `queue`; callback UI dikirim ke main thread.
final class BridgeClient {
    static let serviceType = "_cursoe._tcp"
    private static let authMacLabel = "cursoe/v1/auth-mac"
    private static let authFoldLabel = "cursoe/v1/auth-fold"

    /// Dipanggil di main thread setiap status berubah.
    var onChange: ((LinkSnapshot) -> Void)?
    /// Dipanggil di main thread (di luar blok GCD) untuk meminta PIN.
    var onPinRequested: ((_ device: String, _ message: String?) -> String?)?
    /// Dipanggil di main thread bila dialog PIN harus ditutup.
    var onPinCancelled: (() -> Void)?
    /// Pesan aplikasi dari HP (LEAVE, CLIPBOARD, …), dipanggil di main thread.
    var onRemoteMessage: ((_ type: String, _ message: Message) -> Void)?

    /// Saat mode REMOTE: PING tiap 1 detik & anggap putus setelah 3,5 detik
    /// (supaya Mac cepat kembali ke mode lokal bila HP hilang).
    var fastKeepAlive = false {
        didSet { queue.async { self.fastKeepAliveOnQueue = self.fastKeepAlive } }
    }
    private var fastKeepAliveOnQueue = false
    private var tickCount = 0

    // Penggabungan MOVE & SCROLL: masing-masing maksimal ~120 pesan/detik.
    private var pendingDx = 0.0
    private var pendingDy = 0.0
    private var pendingScrollX = 0.0
    private var pendingScrollY = 0.0
    private var pendingPinchScale = 1.0 // hasil kali (1 + magnification)
    private var moveFlushScheduled = false
    private var lastMoveSentNs: UInt64 = 0
    private static let moveIntervalNs: UInt64 = 8_333_333

    private let queue = DispatchQueue(label: "dev.cursoe.net", qos: .userInteractive)
    var networkQueue: DispatchQueue { queue }
    /// Transfer file (dipanggil di `queue`).
    weak var fileHandler: FileTransferHandler?
    private let identity = MacIdentity.load()
    private var browser: NWBrowser?
    private var results: [NWBrowser.Result] = []
    private var session: Session?
    private var snapshot = LinkSnapshot()
    private var timer: DispatchSourceTimer?
    private var reconnectWork: DispatchWorkItem?
    private var declined: Set<String> = []       // HP yang pairing-nya dibatalkan pengguna
    private var tokenCache: [String: Data?] = [:]
    private var manualEndpoint = BridgeClient.parseEndpoint(UserDefaults.standard.string(forKey: "manualHost"))
    private var manualPaused = false

    // Kabel USB (adb forward)
    private let usb = UsbLink()
    private var usbState: UsbLink.State = .noDevice(adbUnauthorized: false)
    private var usbPaused = false
    private var usbChecked = false // hasil pemeriksaan kabel pertama sudah ada
    private var mode = ConnectionMode(rawValue: UserDefaults.standard.string(forKey: "connectionMode") ?? "") ?? .auto

    /// Mode koneksi tersimpan (dibaca menu di main thread).
    var connectionMode: ConnectionMode {
        ConnectionMode(rawValue: UserDefaults.standard.string(forKey: "connectionMode") ?? "") ?? .auto
    }

    func setConnectionMode(_ newMode: ConnectionMode) {
        UserDefaults.standard.set(newMode.rawValue, forKey: "connectionMode")
        queue.async {
            self.mode = newMode
            self.usbPaused = false
            self.manualPaused = false
            if case .paused = self.snapshot.state { self.snapshot.state = .searching }
            Log.info("Mode koneksi: \(newMode.rawValue)")
            self.teardown(L("connection mode changed", "mode koneksi diubah"), retryAfter: 0.2)
        }
    }

    static let defaultPort: UInt16 = 47800

    /// Alamat manual tersimpan ("ip:port"), cadangan bila Bonjour diblokir jaringan.
    var manualHost: String? { UserDefaults.standard.string(forKey: "manualHost") }

    // MARK: API publik (aman dipanggil dari thread mana pun)

    func start() {
        queue.async {
            Log.info("Mac: \(self.identity.name) (\(self.identity.id))")
            self.startBrowser()
            self.startTimer()
            self.usb.onChange = { [weak self] state in
                self?.queue.async { self?.usbChanged(state) }
            }
            self.usb.start()
            self.publish()
            // Beri Bonjour waktu sebentar; setelah itu coba (juga alamat manual).
            self.scheduleConnect(after: 1.5)
        }
    }

    func reconnect(reason: String) {
        queue.async {
            self.declined.removeAll()
            self.manualPaused = false
            self.usbPaused = false
            if case .paused = self.snapshot.state { self.snapshot.state = .searching }
            self.teardown(reason, retryAfter: 0.3)
        }
    }

    /// Simpan alamat manual "ip[:port]"; string kosong mematikan koneksi manual.
    func setManualHost(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        queue.async {
            UserDefaults.standard.set(trimmed.isEmpty ? nil : trimmed, forKey: "manualHost")
            self.manualEndpoint = Self.parseEndpoint(trimmed)
            self.manualPaused = false
            Log.info("Alamat manual: \(self.manualEndpoint.map(Self.describe) ?? "tidak ada")")
            self.teardown(L("manual address changed", "alamat manual diubah"), retryAfter: 0.2)
        }
    }

    static func parseEndpoint(_ text: String?) -> NWEndpoint? {
        guard let text, !text.isEmpty else { return nil }
        var host = text
        var port = defaultPort
        if let colon = text.lastIndex(of: ":"), let parsed = UInt16(text[text.index(after: colon)...]) {
            host = String(text[..<colon])
            port = parsed
        }
        guard !host.isEmpty, let nwPort = NWEndpoint.Port(rawValue: port) else { return nil }
        return .hostPort(host: NWEndpoint.Host(host), port: nwPort)
    }

    private static func describe(_ endpoint: NWEndpoint) -> String {
        if case .hostPort(let host, let port) = endpoint { return "\(host):\(port)" }
        return "\(endpoint)"
    }

    func forgetPairings() {
        queue.async {
            Keychain.deleteAll()
            self.tokenCache.removeAll()
            self.declined.removeAll()
            self.teardown(L("all pairings removed", "semua pairing dihapus"), retryAfter: 0.3)
        }
    }

    /// Kirim pesan aplikasi. MOVE yang tertunda dikirim dulu agar urutan tetap benar.
    /// Diabaikan bila belum terautentikasi.
    func send(_ message: Message) {
        queue.async {
            self.flushPending()
            guard let s = self.session, s.authenticated else { return }
            self.sendSecure(message, on: s)
        }
    }

    /// Tambahkan delta gerak; dikirim tergabung maksimal ~120 Hz.
    func queueMove(dx: Double, dy: Double) {
        queue.async {
            self.pendingDx += dx
            self.pendingDy += dy
            self.scheduleFlush()
        }
    }

    /// Tambahkan delta scroll (point, sudah termasuk arah natural scrolling macOS).
    func queueScroll(dx: Double, dy: Double) {
        queue.async {
            self.pendingScrollX += dx
            self.pendingScrollY += dy
            self.scheduleFlush()
        }
    }

    /// Pinch trackpad: magnification digabung (dikalikan) dan dikirim ~120 Hz sebagai PINCH {mag}.
    func queuePinch(_ magnification: Double) {
        queue.async {
            self.pendingPinchScale *= 1 + magnification
            self.scheduleFlush()
        }
    }

    /// Jari pinch diangkat.
    func endPinch() {
        queue.async {
            self.flushPending()
            guard let s = self.session, s.authenticated else { return }
            self.sendSecure(["t": "PINCH", "mag": 0, "end": true, "ts": Self.nowMs()], on: s)
        }
    }

    /// Jari diangkat dari trackpad: kirim sisa delta lalu penanda akhir (HP mengangkat jari
    /// virtual dengan kecepatannya → fling bawaan Android).
    func endScroll() {
        queue.async {
            self.flushPending()
            guard let s = self.session, s.authenticated else { return }
            self.sendSecure(["t": "SCROLL", "dx": 0, "dy": 0, "end": true, "ts": Self.nowMs()], on: s)
        }
    }

    private func scheduleFlush() {
        guard !moveFlushScheduled else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        let due = lastMoveSentNs + Self.moveIntervalNs
        if now >= due {
            flushPending()
        } else {
            moveFlushScheduled = true
            queue.asyncAfter(deadline: .now() + .nanoseconds(Int(due - now))) {
                self.moveFlushScheduled = false
                self.flushPending()
            }
        }
    }

    private func flushPending() {
        let hasMove = pendingDx != 0 || pendingDy != 0
        let hasScroll = pendingScrollX != 0 || pendingScrollY != 0
        let hasPinch = pendingPinchScale != 1
        guard hasMove || hasScroll || hasPinch else { return }
        lastMoveSentNs = DispatchTime.now().uptimeNanoseconds
        // ts (ms, jam Mac): HP memakai selisih ts antar-pesan sebagai durasi segmen gesture,
        // sehingga gerakan tetap mengikuti ritme asli walau paket datang bergerombol.
        let ts = Self.nowMs()
        let s = session
        let ready = s?.authenticated == true
        if hasMove {
            if ready {
                sendSecure(["t": "MOVE", "dx": Self.round2(pendingDx), "dy": Self.round2(pendingDy), "ts": ts], on: s!)
            }
            pendingDx = 0
            pendingDy = 0
        }
        if hasScroll {
            if ready {
                sendSecure(["t": "SCROLL", "dx": Self.round2(pendingScrollX), "dy": Self.round2(pendingScrollY), "ts": ts], on: s!)
            }
            pendingScrollX = 0
            pendingScrollY = 0
        }
        if hasPinch {
            if ready {
                let mag = ((pendingPinchScale - 1) * 10000).rounded() / 10000
                sendSecure(["t": "PINCH", "mag": mag, "ts": ts], on: s!)
            }
            pendingPinchScale = 1
        }
    }

    private static func round2(_ value: Double) -> Double { (value * 100).rounded() / 100 }

    // MARK: Discovery

    private func startBrowser() {
        browser?.cancel()
        let params = NWParameters()
        params.includePeerToPeer = false
        let b = NWBrowser(for: .bonjourWithTXTRecord(type: Self.serviceType, domain: nil), using: params)
        b.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                Log.info("Bonjour: mencari \(Self.serviceType)")
            case .waiting(let error):
                Log.info("Bonjour menunggu: \(error)")
                if case .dns(let code) = error, code == -65570 /* kDNSServiceErr_PolicyDenied */ {
                    self.snapshot.state = .paused(L("Local Network access was denied. Open System Settings › Privacy & Security › Local Network and turn on Cursoe.", "Izin Local Network ditolak. Buka System Settings › Privacy & Security › Local Network, nyalakan cursoe."))
                    self.publish()
                }
            case .failed(let error):
                Log.info("Bonjour gagal: \(error); coba lagi 3 detik")
                self.queue.asyncAfter(deadline: .now() + 3) { self.startBrowser() }
            default:
                break
            }
        }
        b.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self else { return }
            self.results = Array(results)
            Log.info("Bonjour: \(results.count) HP ditemukan: \(results.map { Self.serviceName(of: $0) })")
            self.maybeConnect()
        }
        browser = b
        b.start(queue: queue)
    }

    private static func serviceName(of result: NWBrowser.Result) -> String {
        if case .service(let name, _, _, _) = result.endpoint { return name }
        return L("Android", "HP")
    }

    private static func deviceId(of result: NWBrowser.Result) -> String? {
        if case .bonjour(let txt) = result.metadata { return txt["id"] }
        return nil
    }

    private func token(for deviceId: String) -> Data? {
        if let cached = tokenCache[deviceId] { return cached }
        let token = Keychain.token(for: deviceId)
        tokenCache[deviceId] = token
        return token
    }

    private func maybeConnect() {
        guard session == nil else { return }
        reconnectWork?.cancel()
        reconnectWork = nil

        // Mode Otomatis: tunggu pemeriksaan kabel pertama agar tidak tersambung lewat Wi-Fi dulu.
        if mode == .auto, !usbChecked {
            scheduleConnect(after: 0.3)
            return
        }
        // Kabel USB didahulukan (mode Otomatis / Hanya kabel).
        if mode != .wireless, !usbPaused, let endpoint = usbState.endpoint {
            connect(to: endpoint, transport: .usb, name: L("Android (USB cable)", "HP (kabel USB)"), deviceId: nil)
            return
        }
        if mode == .usb {
            snapshot.state = .paused(usbPaused
                ? L("Pairing over USB was cancelled. Choose “Reconnect”.", "Pairing lewat kabel dibatalkan. Pilih “Hubungkan ulang”.")
                : L("Waiting for your device over USB: \(usbState.description)", "Menunggu HP lewat kabel USB: \(usbState.description)"))
            publish()
            return
        }

        let entries = results.map { (result: $0, id: Self.deviceId(of: $0), name: Self.serviceName(of: $0)) }
        let paired = entries.first { $0.id.map { token(for: $0) != nil } ?? false }
        let fresh = entries.first { !($0.id.map { declined.contains($0) } ?? false) }

        if let pick = paired ?? fresh {
            connect(to: pick.result.endpoint, transport: .bonjour, name: pick.name, deviceId: pick.id)
            return
        }
        if let endpoint = manualEndpoint, !manualPaused {
            connect(to: endpoint, transport: .manual, name: Self.describe(endpoint), deviceId: nil)
            return
        }

        if let first = entries.first {
            snapshot.state = .paused(L("Pairing with \(first.name) was cancelled. Choose “Reconnect” to try again.", "Pairing dengan \(first.name) dibatalkan. Pilih “Hubungkan ulang” untuk mencoba lagi."))
        } else if manualPaused {
            snapshot.state = .paused(L("Pairing was cancelled. Choose “Reconnect” to try again.", "Pairing dibatalkan. Pilih “Hubungkan ulang” untuk mencoba lagi."))
        } else if case .paused = snapshot.state {
            // pertahankan pesan (mis. izin Local Network)
        } else {
            snapshot.state = .searching
        }
        publish()
    }

    // MARK: Koneksi

    private func connect(to endpoint: NWEndpoint, transport: Transport, name: String, deviceId: String?) {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.connectionTimeout = 5
        let params = NWParameters(tls: nil, tcp: tcp)
        params.includePeerToPeer = false

        let connection = NWConnection(to: endpoint, using: params)
        let s = Session(connection: connection, transport: transport, name: name, deviceId: deviceId)
        session = s
        snapshot = LinkSnapshot(state: .connecting(name), transport: transport, usbStatus: snapshot.usbStatus)
        publish()
        Log.info("Menghubungkan ke \(name) lewat \(transport.label)…")

        // Jaringan berubah (pindah Wi-Fi/hotspot, sleep): jangan tunggu timeout PING.
        connection.viabilityUpdateHandler = { [weak self] viable in
            guard let self, self.session === s else { return }
            s.viable = viable
            guard !viable else { return }
            self.queue.asyncAfter(deadline: .now() + 1.5) {
                if self.session === s, !s.viable { self.teardown(L("no network path to the device", "jaringan ke HP tidak tersedia"), retryAfter: 0.5) }
            }
        }
        connection.stateUpdateHandler = { [weak self] state in
            guard let self, self.session === s else { return }
            switch state {
            case .ready:
                let remote = connection.currentPath?.remoteEndpoint.map { "\($0)" } ?? "?"
                Log.info("TCP tersambung ke \(name) [\(remote)]")
                s.lastReceived = .now()
                self.sendHello(on: s)
                self.receiveFrame(on: s)
            case .waiting(let error):
                self.teardown(L("cannot connect (\(error))", "tidak bisa tersambung (\(error))"))
            case .failed(let error):
                self.teardown(L("connection failed (\(error))", "koneksi gagal (\(error))"))
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func teardown(_ reason: String, retryAfter: Double = 2) {
        if let s = session {
            Log.info("Putus dari \(s.name): \(reason)")
            session = nil
            fileHandler?.connectionLost()
            s.connection.stateUpdateHandler = nil
            s.connection.cancel()
            if case .awaitingPin = snapshot.state {
                DispatchQueue.main.async { self.onPinCancelled?() }
            }
        }
        if case .paused = snapshot.state {} else { snapshot.state = .searching }
        snapshot.screen = nil
        snapshot.rttMs = nil
        publish()
        scheduleConnect(after: retryAfter)
    }

    private func scheduleConnect(after delay: Double) {
        reconnectWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.maybeConnect() }
        reconnectWork = work
        queue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func failIfCurrent(_ s: Session, _ reason: String) {
        guard session === s else { return }
        teardown(reason)
    }

    // MARK: Kirim / terima

    private func sendHello(on s: Session) {
        let hello: Message = [
            "t": "HELLO", "v": 1, "role": "mac",
            "id": identity.id, "name": identity.name,
            "nonce": s.handshake.nonce.base64EncodedString(),
            "epk": s.handshake.publicKeyDER.base64EncodedString(),
        ]
        s.hello = Wire.encodeJSON(hello)
        s.connection.send(content: Wire.frame(s.hello), completion: .contentProcessed { [weak self] error in
            if let error { self?.failIfCurrent(s, L("failed to send HELLO (\(error))", "gagal kirim HELLO (\(error))")) }
        })
    }

    private func sendSecure(_ message: Message, on s: Session, then: (() -> Void)? = nil) {
        sendSealed(Wire.encodeJSON(message), on: s, then: then)
    }

    /// Kirim pesan dari kode yang sudah berjalan di `queue` (transfer file).
    func sendOnQueue(_ message: Message) {
        guard let s = session, s.authenticated else { return }
        sendSecure(message, on: s)
    }

    /// Kirim frame biner (potongan file) dari `queue`. @return false bila tidak terhubung.
    func sendBinaryOnQueue(_ plaintext: Data, then: @escaping () -> Void) -> Bool {
        guard let s = session, s.authenticated else { return false }
        sendSealed(plaintext, on: s, then: then)
        return true
    }

    private func sendSealed(_ plaintext: Data, on s: Session, then: (() -> Void)? = nil) {
        guard let channel = s.channel else { return }
        do {
            let sealed = try channel.seal(plaintext)
            s.connection.send(content: Wire.frame(sealed), completion: .contentProcessed { [weak self] error in
                if let error {
                    self?.failIfCurrent(s, L("send failed (\(error))", "gagal kirim (\(error))"))
                } else {
                    then?()
                }
            })
        } catch {
            teardown(L("encryption failed (\(error))", "enkripsi gagal (\(error))"))
        }
    }

    // MARK: Gambar clipboard (dikirim bertahap)

    private static let imageChunkBytes = 48 * 1024

    /// Kirim gambar dalam potongan. Potongan berikutnya baru dikirim setelah yang sebelumnya
    /// diproses jaringan, sehingga MOVE/PING tetap bisa menyelip (kursor tidak macet).
    func sendClipboardImage(_ data: Data, mime: String, sha256: String) {
        queue.async {
            guard let s = self.session, s.authenticated else { return }
            let id = UUID().uuidString
            self.sendSecure(["t": "CLIP_IMAGE_BEGIN", "id": id, "mime": mime, "size": data.count, "sha256": sha256], on: s)
            self.sendImageChunk(data, id: id, offset: 0, seq: 0, on: s)
        }
    }

    private func sendImageChunk(_ data: Data, id: String, offset: Int, seq: Int, on s: Session) {
        guard session === s else { return } // koneksi berganti: batalkan
        guard offset < data.count else {
            sendSecure(["t": "CLIP_IMAGE_END", "id": id], on: s)
            return
        }
        let end = min(offset + Self.imageChunkBytes, data.count)
        let chunk = data.subdata(in: offset..<end)
        sendSecure(["t": "CLIP_IMAGE_DATA", "id": id, "seq": seq, "data": chunk.base64EncodedString()], on: s) { [weak self] in
            self?.sendImageChunk(data, id: id, offset: end, seq: seq + 1, on: s)
        }
    }

    private func receiveFrame(on s: Session) {
        s.connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] header, _, isComplete, error in
            guard let self, self.session === s else { return }
            if let error { self.teardown(L("receive failed (\(error))", "gagal menerima (\(error))")); return }
            guard let header, header.count == 4 else {
                self.teardown(isComplete ? L("the device closed the connection", "HP menutup koneksi") : L("invalid frame header", "header frame rusak"))
                return
            }
            let length = Wire.readLength(header)
            guard length > 0, length <= Wire.maxFrame else {
                self.teardown(L("invalid frame size (\(length))", "ukuran frame tidak valid (\(length))"))
                return
            }
            s.connection.receive(minimumIncompleteLength: length, maximumLength: length) { body, _, _, error in
                guard self.session === s else { return }
                if let error { self.teardown(L("receive failed (\(error))", "gagal menerima (\(error))")); return }
                guard let body, body.count == length else { self.teardown(L("truncated frame", "frame terpotong")); return }
                s.lastReceived = .now()
                self.handleFrame(body, on: s)
                if self.session === s { self.receiveFrame(on: s) }
            }
        }
    }

    private func handleFrame(_ payload: Data, on s: Session) {
        guard let channel = s.channel else {
            handleHello(payload, on: s)
            return
        }
        let plaintext: Data
        do {
            plaintext = try channel.open(payload)
        } catch {
            teardown(L("message could not be decrypted (\(error))", "pesan gagal didekripsi (\(error))"))
            return
        }
        if plaintext.first == FileTransfer.binaryMarker {
            // [0x01][16 byte UUID][data]: potongan file
            guard s.authenticated, plaintext.count > 17 else { return }
            let bytes = [UInt8](plaintext[plaintext.startIndex + 1 ..< plaintext.startIndex + 17])
            let id = UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                                 bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
            fileHandler?.handleFileChunk(id, plaintext.subdata(in: plaintext.startIndex + 17 ..< plaintext.endIndex))
            return
        }
        guard let message = Wire.decodeJSON(plaintext), let type = message.string("t") else {
            teardown(L("invalid JSON", "JSON tidak valid"))
            return
        }
        if type != "PONG" { Log.debug("← \(type)") }
        handleMessage(type, message, on: s)
    }

    private func handleHello(_ payload: Data, on s: Session) {
        guard let m = Wire.decodeJSON(payload), m.string("t") == "HELLO", m.int("v") == 1,
              let id = m.string("id"), let nonce = m.base64("nonce"), let epk = m.base64("epk") else {
            teardown(L("invalid HELLO from the device", "HELLO dari HP tidak valid"))
            return
        }
        s.deviceId = id
        if let name = m.string("name") { s.name = name }
        do {
            s.channel = try SecureChannel(handshake: s.handshake, macHello: s.hello, foldHello: payload,
                                          peerPublicKeyDER: epk, peerNonce: nonce)
        } catch {
            teardown(L("handshake failed (\(error))", "handshake gagal (\(error))"))
            return
        }
        Log.info("Kanal terenkripsi siap dengan \(s.name)")

        if m.bool("paired") == true, let token = token(for: id) {
            s.token = token
            sendSecure(["t": "AUTH", "proof": s.channel!.proof(token: token, label: Self.authMacLabel).base64EncodedString()], on: s)
        } else {
            sendSecure(["t": "PAIR_REQUEST"], on: s)
        }
    }

    private func handleMessage(_ type: String, _ m: Message, on s: Session) {
        switch type {
        case "AUTH_OK":
            guard let token = s.token, let proof = m.base64("proof"),
                  s.channel!.verify(proof: proof, token: token, label: Self.authFoldLabel) else {
                teardown(L("the device failed to prove its identity", "HP gagal membuktikan identitasnya"))
                return
            }
            markConnected(s)

        case "AUTH_FAIL":
            if let id = s.deviceId {
                Keychain.delete(id)
                tokenCache[id] = .some(nil)
            }
            teardown(L("the device rejected the token (\(m.string("reason") ?? "?")); pairing again", "HP menolak token (\(m.string("reason") ?? "?")); pairing ulang"), retryAfter: 0.5)

        case "PAIR_PIN_SHOWN":
            snapshot.state = .awaitingPin(s.name)
            publish()
            askPin(on: s, message: nil)

        case "PAIR_FAIL":
            let left = m.int("left") ?? 0
            if left > 0 {
                askPin(on: s, message: L("Wrong PIN. \(left) attempts left.", "PIN salah. Sisa \(left) percobaan."))
            } else {
                decline(s)
                teardown(L("pairing failed (\(m.string("reason") ?? "wrong PIN"))", "pairing gagal (\(m.string("reason") ?? "PIN salah"))"))
            }

        case "PAIR_OK":
            guard let token = m.base64("token"), token.count == 32, let id = s.deviceId else {
                teardown(L("invalid PAIR_OK", "PAIR_OK tidak valid"))
                return
            }
            Keychain.save(token: token, for: id, deviceName: s.name)
            tokenCache[id] = token
            s.token = token
            markConnected(s)

        case "SCREEN_INFO":
            if let w = m.int("w"), let h = m.int("h") {
                let info = ScreenInfo(width: w, height: h, density: m.double("density") ?? 1,
                                      cursorReady: m.bool("cursor") ?? false,
                                      keyboardReady: m.bool("ime") ?? false)
                snapshot.screen = info
                Log.info("Layar HP: \(w)×\(h) density \(info.density) kursor \(info.cursorReady ? "siap" : "belum aktif")")
                publish()
            }

        case "FILE_BEGIN", "FILE_END", "FILE_CANCEL", "FILE_RESULT":
            guard s.authenticated else { return }
            fileHandler?.handleFileMessage(type, m)

        case "LEAVE", "CLIPBOARD", "CLIP_IMAGE_BEGIN", "CLIP_IMAGE_DATA", "CLIP_IMAGE_END":
            guard s.authenticated else { return }
            DispatchQueue.main.async { self.onRemoteMessage?(type, m) }

        case "PONG":
            if let ts = m.int64("ts") {
                let rtt = Int(Self.nowMs() - ts)
                snapshot.rttMs = rtt
                if s.rttSamples.count < 5 {
                    s.rttSamples.append(rtt)
                    if s.rttSamples.count == 5 {
                        Log.info("RTT lewat \(s.transport.label): \(s.rttSamples.map(String.init).joined(separator: ", ")) ms")
                    }
                }
                publish()
            }

        case "PING":
            sendSecure(["t": "PONG", "ts": m["ts"] ?? 0], on: s)

        default:
            Log.debug("Pesan tidak dikenal: \(type)")
        }
    }

    /// Jangan otomatis mencoba pairing lagi ke HP ini sampai pengguna memilih "Hubungkan ulang".
    private func decline(_ s: Session) {
        if let id = s.deviceId { declined.insert(id) }
        if s.transport == .manual { manualPaused = true }
        if s.transport == .usb { usbPaused = true }
    }

    private func markConnected(_ s: Session) {
        s.authenticated = true
        if let id = s.deviceId { declined.remove(id) }
        snapshot.state = .connected(s.name)
        publish()
        Log.info("Terhubung & terautentikasi dengan \(s.name)")
    }

    private func askPin(on s: Session, message: String?) {
        let device = s.name
        runOnMainRunLoop { [weak self] in
            guard let self else { return }
            let pin = self.onPinRequested?(device, message)
            self.queue.async {
                guard self.session === s, !s.authenticated else { return }
                guard let pin else {
                    self.decline(s)
                    self.teardown(L("pairing cancelled by user", "pairing dibatalkan pengguna"))
                    return
                }
                self.sendSecure(["t": "PAIR", "pin": pin], on: s)
            }
        }
    }

    /// Jalankan blok di run loop utama, bukan sebagai blok GCD main queue, supaya
    /// DispatchQueue.main tetap diproses selama dialog modal terbuka.
    private func runOnMainRunLoop(_ block: @escaping () -> Void) {
        let loop = CFRunLoopGetMain()
        CFRunLoopPerformBlock(loop, CFRunLoopMode.defaultMode.rawValue, block)
        CFRunLoopWakeUp(loop)
    }

    // MARK: Keep-alive

    private func startTimer() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 1, repeating: 1)
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    private func tick() {
        tickCount += 1
        guard let s = session else {
            // Tidak ada koneksi & tidak ada percobaan terjadwal: coba lagi (mis. alamat manual).
            if reconnectWork == nil, tickCount % 2 == 0 { maybeConnect() }
            return
        }
        switchToUsbIfBetter()
        guard session === s else { return }
        let fast = fastKeepAliveOnQueue && s.authenticated
        let idle = Double(DispatchTime.now().uptimeNanoseconds - s.lastReceived.uptimeNanoseconds) / 1e9
        if idle > (fast ? 3.5 : 7) {
            teardown(L("no response from the device for \(String(format: "%.1f", idle)) s", "HP tidak merespons \(String(format: "%.1f", idle)) detik"))
            return
        }
        if s.channel != nil, fast || tickCount % 2 == 0 {
            sendSecure(["t": "PING", "ts": Self.nowMs()], on: s)
        }
    }

    // MARK: Kabel USB

    private func usbChanged(_ state: UsbLink.State) {
        usbState = state
        usbChecked = true
        snapshot.usbStatus = state.description
        publish()
        if let s = session, s.transport == .usb, !state.isReady {
            teardown(L("USB cable unplugged", "kabel USB dicabut"), retryAfter: 0.3) // mode Otomatis: lanjut lewat Wi-Fi/hotspot
            return
        }
        if session == nil {
            scheduleConnect(after: 0.2)
        } else {
            switchToUsbIfBetter()
        }
    }

    /// Mode Otomatis: kabel tersedia sementara koneksi lewat Wi-Fi → pindah ke kabel,
    /// tetapi tidak saat kursor sedang di HP (ditunda sampai mode lokal).
    private func switchToUsbIfBetter() {
        guard mode == .auto, usbState.isReady, !usbPaused, let s = session,
              s.transport != .usb, s.authenticated, !fastKeepAliveOnQueue else { return }
        teardown(L("switching to USB cable", "beralih ke kabel USB"), retryAfter: 0.1)
    }

    private static func nowMs() -> Int64 {
        Int64(DispatchTime.now().uptimeNanoseconds / 1_000_000)
    }

    private func publish() {
        let snap = snapshot
        DispatchQueue.main.async { self.onChange?(snap) }
    }
}
