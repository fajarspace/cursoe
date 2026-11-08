import Darwin
import Foundation
import Network
import SystemConfiguration

/// Koneksi lewat kabel USB. Dicek tiap 2 detik, dua jalur:
///
/// 1. **Tethering USB** (utama, tanpa USB debugging): HP menyalakan "Tethering USB" → Mac mendapat
///    jaringan kabel dengan HP sebagai gateway. Mac mengirim "CURSOE?" (UDP) ke gateway setiap
///    jaringan kabel non-Wi-Fi; bila HP menjawab "CURSOE!", koneksi langsung ke gateway:47800.
///    Catatan: macOS hanya mengenali tethering mode NCM (bukan RNDIS).
/// 2. **USB debugging** (cadangan): `adb forward` port lokal 47801 → port Cursoe 47800 di HP.
///
/// Keduanya tidak butuh Wi-Fi; latensi paling rendah.
final class UsbLink {
    static let localPort: UInt16 = 47801
    static let remotePort: UInt16 = 47800

    enum Path: Equatable {
        case tether(host: String, interface: String, name: String)
        case adb(serial: String)
    }

    enum State: Equatable {
        case noDevice(adbUnauthorized: Bool)
        case ready(Path)

        var isReady: Bool {
            if case .ready = self { return true }
            return false
        }

        /// Alamat yang dihubungi BridgeClient.
        var endpoint: NWEndpoint? {
            guard case .ready(let path) = self else { return nil }
            switch path {
            case .tether(let host, _, _):
                return .hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: UsbLink.remotePort)!)
            case .adb:
                return .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: UsbLink.localPort)!)
            }
        }

        var description: String {
            switch self {
            case .noDevice(let unauthorized):
                return unauthorized
                    ? "izinkan “USB debugging” untuk Mac ini di layar HP"
                    : "nyalakan Tethering USB di HP"
            case .ready(.tether(let host, let interface, _)): return "tethering USB (\(interface), \(host))"
            case .ready(.adb): return "USB debugging (adb)"
            }
        }
    }

    /// Dipanggil di antrean internal setiap status berubah.
    var onChange: ((State) -> Void)?
    private(set) var state: State = .noDevice(adbUnauthorized: false)
    private var checkedOnce = false

    private let queue = DispatchQueue(label: "dev.cursoe.usb", qos: .utility)
    private var timer: DispatchSourceTimer?

    /// Aplikasi yang dibuka lewat Finder/`open` tidak mewarisi PATH shell, jadi cari di lokasi umum.
    /// adb hanya cadangan; tanpa adb, tethering USB tetap jalan.
    private let adbPath: String? = {
        let home = NSHomeDirectory()
        let candidates = [
            "/opt/homebrew/bin/adb",
            "/usr/local/bin/adb",
            "/opt/homebrew/share/android-commandlinetools/platform-tools/adb",
            "\(home)/Library/Android/sdk/platform-tools/adb",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }()

    func start() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: 2)
        t.setEventHandler { [weak self] in self?.check() }
        t.resume()
        timer = t
    }

    private func check() {
        if let tether = findTether() { return update(.ready(tether)) }
        checkAdb()
    }

    // MARK: Tethering USB

    /// Jaringan kabel (bukan Wi-Fi) yang gateway-nya menjawab "CURSOE?" = HP dengan tethering USB.
    private func findTether() -> Path? {
        // Jalur yang sedang dipakai dicek lebih dulu agar tidak berpindah-pindah.
        var candidates = Self.wiredGateways()
        if case .ready(.tether(let host, let interface, _)) = state,
           let index = candidates.firstIndex(where: { $0.router == host && $0.interface == interface }) {
            candidates.insert(candidates.remove(at: index), at: 0)
        }
        for candidate in candidates {
            if let name = Self.probe(candidate.router) {
                return .tether(host: candidate.router, interface: candidate.interface, name: name)
            }
        }
        return nil
    }

    /// (antarmuka, gateway) untuk setiap layanan IPv4 aktif yang bukan Wi-Fi/VPN.
    private static func wiredGateways() -> [(interface: String, router: String)] {
        guard let store = SCDynamicStoreCreate(nil, "Cursoe" as CFString, nil, nil),
              let keys = SCDynamicStoreCopyKeyList(store, "State:/Network/Service/.*/IPv4" as CFString) as? [String]
        else { return [] }
        let wifi = Set((SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] ?? []).compactMap { iface -> String? in
            SCNetworkInterfaceGetInterfaceType(iface) == kSCNetworkInterfaceTypeIEEE80211
                ? SCNetworkInterfaceGetBSDName(iface) as String? : nil
        })
        var result: [(String, String)] = []
        for key in keys {
            guard let info = SCDynamicStoreCopyValue(store, key as CFString) as? [String: Any],
                  let interface = info["InterfaceName"] as? String,
                  let router = info["Router"] as? String,
                  interface.hasPrefix("en"), !wifi.contains(interface)
            else { continue }
            result.append((interface, router))
        }
        return result
    }

    /// Kirim "CURSOE?" ke host:47800 (UDP), tunggu maks. 0,4 detik. @return nama HP bila menjawab.
    private static func probe(_ host: String) -> String? {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var timeout = timeval(tv_sec: 0, tv_usec: 400_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = remotePort.bigEndian
        guard inet_pton(AF_INET, host, &address.sin_addr) == 1 else { return nil }

        let request = Array("CURSOE?".utf8)
        let sent = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                sendto(fd, request, request.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard sent == request.count else { return nil }

        var buffer = [UInt8](repeating: 0, count: 256)
        let count = recv(fd, &buffer, buffer.count, 0)
        guard count > 0, let reply = String(bytes: buffer[0..<count], encoding: .utf8),
              reply.hasPrefix("CURSOE! ") else { return nil }
        // Format: "CURSOE! id=<id> port=<port> name=<nama…>"
        guard let range = reply.range(of: " name=") else { return "HP" }
        return String(reply[range.upperBound...])
    }

    // MARK: USB debugging (cadangan)

    private func checkAdb() {
        guard let adb = adbPath, let devices = run(adb, ["devices"]) else {
            return update(.noDevice(adbUnauthorized: false))
        }
        // Format: "List of devices attached\n<serial>\tdevice\n…"
        var ready: String?
        var unauthorized = false
        for line in devices.split(separator: "\n").dropFirst() {
            let parts = line.split(separator: "\t")
            guard parts.count == 2 else { continue }
            if parts[1] == "device", ready == nil { ready = String(parts[0]) }
            if parts[1] == "unauthorized" { unauthorized = true }
        }
        guard let serial = ready else { return update(.noDevice(adbUnauthorized: unauthorized)) }

        let wanted = "\(serial) tcp:\(Self.localPort) tcp:\(Self.remotePort)"
        let existing = run(adb, ["forward", "--list"]) ?? ""
        if !existing.contains(wanted) {
            guard run(adb, ["-s", serial, "forward", "tcp:\(Self.localPort)", "tcp:\(Self.remotePort)"]) != nil else {
                return update(.noDevice(adbUnauthorized: false))
            }
            Log.info("Kabel USB: adb forward 127.0.0.1:\(Self.localPort) → HP:\(Self.remotePort) (\(serial))")
        }
        update(.ready(.adb(serial: serial)))
    }

    private func update(_ newState: State) {
        guard newState != state || !checkedOnce else { return }
        checkedOnce = true // pemeriksaan pertama selalu dilaporkan (mode Otomatis menunggunya)
        state = newState
        Log.info("Kabel USB: \(newState.description)")
        onChange?(newState)
    }

    /// Jalankan adb (maks. 3 detik). @return stdout, atau nil bila gagal.
    private func run(_ path: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return nil
        }
        let killer = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 3, execute: killer)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        killer.cancel()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
