import AppKit
import Carbon.HIToolbox

/// Posisi HP terhadap Mac.
enum FoldSide: String {
    case right, left
}

/// Mengatur mode LOCAL ↔ REMOTE beserta semua pengamannya.
final class RemoteController: InputCaptureDelegate {
    let capture = InputCapture()
    /// Panel "lepas untuk kirim ke HP" saat file dari Finder diseret ke tepi.
    let dropZone = DropZone()
    private var dragChangeCountAtMouseDown = 0
    private var checkedDragChangeCount = -1
    private var dragHasFiles = false
    private let client: BridgeClient

    private(set) var isRemote = false
    /// Alasan terakhir gagal masuk mode remote (ditampilkan di menu).
    private(set) var lastRefusal: String?
    var onChange: (() -> Void)?

    /// Diisi AppDelegate dari status koneksi.
    var connected = false {
        didSet { if !connected { exitRemote(reason: L("connection to the device lost", "koneksi ke HP putus"), notifyFold: false) } }
    }
    var foldCursorReady = false {
        didSet { if !foldCursorReady { exitRemote(reason: L("device cursor not active", "kursor HP tidak aktif")) } }
    }

    var sensitivity: Double {
        didSet { UserDefaults.standard.set(sensitivity, forKey: "sensitivity") }
    }

    var side: FoldSide {
        didSet {
            UserDefaults.standard.set(side.rawValue, forKey: "foldSide")
            exitRemote(reason: L("device position changed", "posisi HP diubah"))
            onChange?()
        }
    }

    // Deteksi dorongan di tepi layar (mode lokal)
    private static let edgePushThreshold = 24.0     // point
    private static let edgePushWindow = 0.35        // detik
    private static let returnCooldown = 0.5         // detik setelah kembali dari HP
    private var pushAccumulated = 0.0
    private var lastPushAt: TimeInterval = 0
    private var cooldownUntil: TimeInterval = 0
    private var displays: [CGRect] = []
    /// Layar Mac tempat kursor keluar ke HP (dan kembali ke sana).
    private var edgeDisplay: CGRect?

    init(client: BridgeClient) {
        self.client = client
        let saved = UserDefaults.standard.double(forKey: "sensitivity")
        sensitivity = saved > 0 ? saved : 1.0
        side = FoldSide(rawValue: UserDefaults.standard.string(forKey: "foldSide") ?? "") ?? .right
        refreshDisplays()
        SystemHotkeys.setAppSwitcherEnabled(true) // pulihkan bila sebelumnya crash saat remote
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            if self?.isRemote == true { CursorControl.reHide() }
        }

        capture.delegate = self
        capture.onMove = { [weak self] dx, dy in
            guard let self else { return }
            self.client.queueMove(dx: dx * self.sensitivity, dy: dy * self.sensitivity)
        }
        capture.onButton = { [weak self] button, down in
            self?.client.send(["t": "BUTTON", "button": button, "down": down])
        }
        capture.onScroll = { [weak self] sample in
            guard let self else { return }
            // Inersia (momentum) tidak dikirim: HP melakukan fling sendiri saat jari diangkat,
            // jauh lebih mulus daripada meniru momentum lewat jaringan.
            if sample.isMomentum { return }
            if sample.dx != 0 || sample.dy != 0 {
                self.client.queueScroll(dx: sample.dx, dy: sample.dy)
            }
            if sample.fingerLifted { self.client.endScroll() }
        }
        capture.onMagnify = { [weak self] magnification, phase in
            guard let self else { return }
            if magnification != 0 { self.client.queuePinch(magnification) }
            if phase.contains(.ended) || phase.contains(.cancelled) { self.client.endPinch() }
        }
        capture.onSmartMagnify = { [weak self] in
            self?.client.send(["t": "SMART_ZOOM"])
        }
        capture.onDockSwipe = { [weak self] direction in
            // Swipe 3 jari naik/turun (Mission Control/App Exposé di Mac) = daftar aplikasi aktif di HP.
            // Arah tanda progress belum pasti sama di semua Mac, jadi keduanya membuka Recents.
            switch direction {
            case .up, .down: self?.client.send(["t": "NAV", "action": "recents"])
            case .left, .right: break // pindah Space: tetap ditelan, tidak diteruskan
            }
        }
        capture.onKey = { [weak self] event, down in
            self?.forwardKey(event, down: down)
        }
        capture.onLocalLeftButton = { [weak self] down in
            guard let self else { return }
            if down {
                self.dragChangeCountAtMouseDown = NSPasteboard(name: .drag).changeCount
            } else {
                self.dropZone.hideSoon()
            }
        }
        capture.onLocalDrag = { [weak self] location in
            self?.checkFileDrag(at: location)
        }
        capture.onLocalMove = { [weak self] location, dx in
            self?.checkEdgePush(location: location, dx: dx)
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.refreshDisplays()
        }
    }

    // MARK: InputCaptureDelegate (dipanggil di main thread dari event tap)

    func captureCanToggle() -> Bool { connected }

    func captureToggleRequested() {
        if isRemote { exitRemote(reason: "⌘⌥T") } else { enterRemote() }
    }

    func captureEmergencyExit() {
        exitRemote(reason: "Esc 3x")
    }

    // MARK: Keyboard

    /// Tombol non-teks → nama yang dipahami HP (KEY).
    private static let specialKeys: [Int: String] = [
        kVK_Delete: "backspace", kVK_ForwardDelete: "delete",
        kVK_Return: "enter", kVK_ANSI_KeypadEnter: "enter", kVK_Tab: "tab", kVK_Escape: "esc",
        kVK_LeftArrow: "left", kVK_RightArrow: "right", kVK_UpArrow: "up", kVK_DownArrow: "down",
        kVK_Home: "home", kVK_End: "end", kVK_PageUp: "pageup", kVK_PageDown: "pagedown",
    ]

    /// Teks biasa → TEXT (karakter dari layout keyboard macOS, termasuk ⇧/⌥).
    /// Tombol khusus & shortcut ⌘/⌃ → KEY {key, mods}. HP mengirim down+up sendiri,
    /// jadi keyUp tidak perlu dikirim. Auto-repeat ikut terkirim sebagai keyDown berulang.
    private func forwardKey(_ event: CGEvent, down: Bool) {
        guard down else { return }
        let code = Int(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags
        var mods: [String] = []
        if flags.contains(.maskShift) { mods.append("shift") }
        if flags.contains(.maskControl) { mods.append("ctrl") }
        if flags.contains(.maskAlternate) { mods.append("alt") }
        if flags.contains(.maskCommand) { mods.append("cmd") }

        if let name = Self.specialKeys[code] {
            client.send(["t": "KEY", "key": name, "mods": mods])
            return
        }
        guard let nsEvent = NSEvent(cgEvent: event) else { return }
        if flags.contains(.maskCommand) || flags.contains(.maskControl) {
            guard let base = nsEvent.charactersIgnoringModifiers?.lowercased(), !base.isEmpty else { return }
            client.send(["t": "KEY", "key": base, "mods": mods])
            return
        }
        guard let text = nsEvent.characters, !text.isEmpty,
              !text.unicodeScalars.contains(where: Self.isNonPrintable) else { return }
        client.send(["t": "TEXT", "text": text])
    }

    /// Karakter kontrol & tombol fungsi macOS (F1…, area privat U+F700–U+F8FF) tidak dikirim sebagai teks.
    private static func isNonPrintable(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value < 0x20 || scalar.value == 0x7F || (0xF700...0xF8FF).contains(scalar.value)
    }

    // MARK: Drag file ke HP

    /// Saat file dari Finder diseret mendekati tepi sisi HP, tampilkan panel drop.
    private func checkFileDrag(at location: CGPoint) {
        guard connected else { return }
        let pasteboard = NSPasteboard(name: .drag)
        let changeCount = pasteboard.changeCount
        guard changeCount != dragChangeCountAtMouseDown else { return } // bukan sesi drag baru
        if changeCount != checkedDragChangeCount {
            checkedDragChangeCount = changeCount
            dragHasFiles = pasteboard.types?.contains(.fileURL) ?? false
        }
        guard dragHasFiles, let display = displays.first(where: { $0.contains(location) }) else { return }
        let distance: CGFloat
        let outer: Bool
        switch side {
        case .right:
            distance = display.maxX - location.x
            outer = !displays.contains { $0.contains(CGPoint(x: display.maxX + 1, y: location.y)) }
        case .left:
            distance = location.x - display.minX
            outer = !displays.contains { $0.contains(CGPoint(x: display.minX - 1, y: location.y)) }
        }
        if outer && distance < 90 {
            dropZone.show(on: display, side: side)
        } else if distance > 360 {
            dropZone.hide()
        }
    }

    // MARK: Tepi layar

    private func refreshDisplays() {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &ids, &count)
        displays = ids.prefix(Int(count)).map { CGDisplayBounds($0) }
        Log.info("Layar Mac: \(displays.map { "\(Int($0.width))×\(Int($0.height))@\(Int($0.minX)),\(Int($0.minY))" })")
    }

    /// Layar paling luar di sisi HP (dipakai bila masuk remote lewat ⌘⌥T).
    private func outermostDisplay() -> CGRect {
        let fallback = CGDisplayBounds(CGMainDisplayID())
        switch side {
        case .right: return displays.max { $0.maxX < $1.maxX } ?? fallback
        case .left: return displays.min { $0.minX < $1.minX } ?? fallback
        }
    }

    private func checkEdgePush(location: CGPoint, dx: Double) {
        guard !isRemote, connected, foldCursorReady else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard now >= cooldownUntil,
              let display = displays.first(where: { $0.contains(location) }) else {
            pushAccumulated = 0
            return
        }
        let atEdge: Bool
        let push: Double
        switch side {
        case .right:
            let beyond = CGPoint(x: display.maxX + 1, y: location.y)
            atEdge = location.x >= display.maxX - 1.5 && !displays.contains { $0.contains(beyond) }
            push = dx
        case .left:
            let beyond = CGPoint(x: display.minX - 1, y: location.y)
            atEdge = location.x <= display.minX + 0.5 && !displays.contains { $0.contains(beyond) }
            push = -dx
        }
        guard atEdge, push > 0 else {
            pushAccumulated = 0
            return
        }
        if now - lastPushAt > Self.edgePushWindow { pushAccumulated = 0 }
        lastPushAt = now
        pushAccumulated += push
        guard pushAccumulated >= Self.edgePushThreshold else { return }
        pushAccumulated = 0

        if let refusal = refusalReason() {
            // Dari tepi layar: jangan beep berulang, cukup catat & tahan sebentar.
            lastRefusal = refusal
            cooldownUntil = now + 1
            Log.info("Dorongan tepi diabaikan: \(refusal)")
            onChange?()
            return
        }
        let yRatio = (location.y - display.minY) / display.height
        startRemote(display: display, yRatio: yRatio, from: side == .right ? "left" : "right")
    }

    // MARK: Mode

    /// Setelah file di-drop di panel (opsi "pilih aplikasi di HP"): kursor pindah ke HP di tepi
    /// yang setara, agar menu Bagikan di HP bisa langsung diklik.
    func enterRemoteAfterDrop() {
        guard !isRemote, refusalReason() == nil else { return }
        let (point, display) = CursorControl.location()
        startRemote(display: display, yRatio: (point.y - display.minY) / display.height,
                    from: side == .right ? "left" : "right")
    }

    /// Masuk mode remote lewat ⌘⌥T / menu: kursor muncul di tengah layar HP.
    func enterRemote() {
        guard !isRemote else { return }
        if let refusal = refusalReason() {
            lastRefusal = refusal
            Log.info("Tidak masuk mode remote: \(refusal)")
            NSSound.beep()
            onChange?()
            return
        }
        let (point, display) = CursorControl.location()
        let yRatio = (point.y - display.minY) / display.height
        startRemote(display: outermostDisplay(), yRatio: yRatio, from: "center")
    }

    private func startRemote(display: CGRect, yRatio: Double, from: String) {
        lastRefusal = nil
        isRemote = true
        edgeDisplay = display
        capture.mode = .remote
        client.fastKeepAlive = true
        CursorControl.detachAndHide()
        SystemHotkeys.setAppSwitcherEnabled(false) // ⌘⇥ untuk Recents HP, bukan app switcher Mac
        client.send([
            "t": "ENTER",
            "yRatio": min(max(yRatio, 0), 1),
            "from": from,
            // Tepi HP yang menghadap Mac: dorong ke sana untuk kembali.
            "macEdge": side == .right ? "left" : "right",
        ])
        Log.info("Mode REMOTE (masuk dari \(from))")
        onChange?()
    }

    /// Kembali ke mode lokal. [leaveYRatio] diisi bila kursor keluar lewat tepi HP:
    /// kursor Mac ditempatkan sedikit ke dalam dari tepi pada ketinggian yang setara.
    func exitRemote(reason: String, notifyFold: Bool = true, leaveYRatio: Double? = nil) {
        guard isRemote else { return }
        isRemote = false
        capture.mode = .local
        client.fastKeepAlive = false
        pushAccumulated = 0
        cooldownUntil = ProcessInfo.processInfo.systemUptime + Self.returnCooldown

        var warp: CGPoint?
        if let ratio = leaveYRatio {
            let display = edgeDisplay ?? outermostDisplay()
            let y = display.minY + min(max(ratio, 0), 1) * (display.height - 1)
            let x = side == .right ? display.maxX - 8 : display.minX + 7
            warp = CGPoint(x: x, y: y)
        }
        CursorControl.attachAndShow(warpTo: warp)
        SystemHotkeys.setAppSwitcherEnabled(true)

        if notifyFold { client.send(["t": "EXIT"]) }
        Log.info("Mode LOKAL (\(reason))")
        onChange?()
    }

    private func refusalReason() -> String? {
        if !capture.isRunning { return L("Mac Accessibility permission not granted", "izin Accessibility Mac belum diberikan") }
        if !connected { return L("device not connected", "HP belum terhubung") }
        if !foldCursorReady { return L("turn on Cursoe Accessibility on the device", "aktifkan Aksesibilitas Cursoe di HP") }
        // Saat Secure Input aktif (mis. kolom password), event tap tidak menerima tombol,
        // sehingga ⌘⌥T/Esc tidak akan terbaca. Jangan ambil risiko Mac "terkunci".
        if IsSecureEventInputEnabled() { return L("macOS Secure Input is on (password field?)", "Secure Input macOS aktif (kolom password?)") }
        return nil
    }
}
