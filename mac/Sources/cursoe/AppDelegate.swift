import AppKit
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let statusLine = NSMenuItem(title: L("Searching for your device…", "Mencari HP…"), action: nil, keyEquivalent: "")
    /// Hanya tampil bila ada yang perlu dibereskan (izin/keyboard di HP, alasan tidak bisa remote).
    private let alertLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private var toggleItem: NSMenuItem!
    private var permissionItem: NSMenuItem!
    private var sideItem: NSMenuItem!
    private var sideRightItem: NSMenuItem!
    private var sideLeftItem: NSMenuItem!
    private let sensitivityValue = NSTextField(labelWithString: "")

    private let client = BridgeClient()
    private lazy var remote = RemoteController(client: client)
    private lazy var clipboard = ClipboardSync(client: client)
    private lazy var files = FileTransfer(client: client)
    private lazy var forwarder = PortForwarder(client: client)
    private let forwardMenu = NSMenu()
    private let transferLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private var clipboardItem: NSMenuItem!
    private var sendFilesItem: NSMenuItem!
    private var loginItem: NSMenuItem!
    private var modeAutoItem: NSMenuItem!
    private var modeUsbItem: NSMenuItem!
    private var modeWirelessItem: NSMenuItem!
    private let usbLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private var debugLogItem: NSMenuItem!

    /// File dari HP yang diterima dalam kiriman yang sedang berjalan (untuk satu menu "Buka dengan").
    private var receivedBatch: [URL] = []

    private var lastSnapshot = LinkSnapshot()
    private var permissionTimer: Timer?

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        setUpStatusItem()

        client.onChange = { [weak self] snapshot in self?.apply(snapshot) }
        client.onPinRequested = { device, message in PinPrompt.ask(device: device, message: message) }
        client.onPinCancelled = { PinPrompt.cancel() }
        client.onRemoteMessage = { [weak self] type, message in self?.handleRemote(type, message) }
        remote.onChange = { [weak self] in self?.render() }

        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.client.reconnect(reason: L("Mac woke from sleep", "Mac bangun dari sleep"))
        }
        // Pengaman: kursor selalu kembali ke Mac saat Mac tidur, layar mati, atau sesi dikunci/berganti.
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification,
                     NSWorkspace.sessionDidResignActiveNotification] {
            workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                self?.remote.exitRemote(reason: note.name.rawValue)
            }
        }
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.screenIsLocked"), object: nil, queue: .main
        ) { [weak self] _ in
            self?.remote.exitRemote(reason: L("Mac screen locked", "layar Mac dikunci"))
        }

        Notifier.shared.setup()
        client.fileHandler = files
        client.tunnelHandler = forwarder
        files.onStatus = { [weak self] status in
            self?.transferLine.title = status ?? ""
            self?.transferLine.isHidden = status == nil
        }
        files.onReceived = { [weak self] url, last in self?.fileFromPhone(url, last: last) }
        remote.dropZone.onDrop = { [weak self] urls in self?.sendToPhone(urls) }


        startCaptureWhenPermitted()
        clipboard.start()
        client.start()
        render()
    }

    /// `open -a Cursoe file…` / Finder › Open With: kirim file ke HP.
    func application(_ application: NSApplication, open urls: [URL]) {
        sendToPhone(urls.filter(\.isFileURL))
    }

    /// Mac → HP: kirim, lalu kursor pindah ke HP untuk memilih "Simpan saja / Buka dengan…" di sana.
    private func sendToPhone(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        files.send(urls, share: true)
        remote.enterRemoteAfterDrop()
    }

    /// HP → Mac: setelah file terakhir dalam kiriman tersimpan, tampilkan panel pilihan dekat kursor.
    private func fileFromPhone(_ url: URL, last: Bool) {
        receivedBatch.append(url)
        guard last else { return }
        let urls = receivedBatch
        receivedBatch = []
        // Panel pilihan: Simpan · aplikasi yang cocok · Finder; × = jangan simpan (Tempat Sampah).
        ReceivedPanel.shared.show(for: urls)
    }

    func applicationWillTerminate(_ notification: Notification) {
        remote.exitRemote(reason: L("app quit", "aplikasi ditutup"))
    }

    // MARK: Izin Accessibility & event tap

    private func startCaptureWhenPermitted() {
        if remote.capture.start() { return }
        Log.info("Izin Accessibility belum ada; menunggu…")
        InputCapture.requestAccessibility()
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] timer in
            guard let self else { return timer.invalidate() }
            if self.remote.capture.start() {
                timer.invalidate()
                self.render()
            }
        }
    }

    // MARK: Status

    private func apply(_ snapshot: LinkSnapshot) {
        lastSnapshot = snapshot
        if case .connected = snapshot.state {
            remote.connected = true
        } else {
            remote.connected = false
        }
        remote.foldCursorReady = snapshot.screen?.cursorReady ?? false
        clipboard.connected = remote.connected
        render()
    }

    private func handleRemote(_ type: String, _ message: Message) {
        switch type {
        case "LEAVE":
            remote.exitRemote(reason: L("cursor left through the device edge", "kursor keluar lewat tepi HP"), notifyFold: false,
                              leaveYRatio: message.double("yRatio") ?? 0.5)

        case "CLIPBOARD", "CLIP_IMAGE_BEGIN", "CLIP_IMAGE_DATA", "CLIP_IMAGE_END":
            clipboard.handle(type, message)
        default:
            break
        }
    }

    // MARK: Menu

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = BrandIcon.menuBarImage()
        }

        let menu = NSMenu()
        menu.autoenablesItems = false

        for line in [statusLine, alertLine, transferLine] {
            line.isEnabled = false
            menu.addItem(line)
        }
        alertLine.isHidden = true
        transferLine.isHidden = true
        permissionItem = item(L("⚠︎ Grant Accessibility Access…", "⚠︎ Beri izin Aksesibilitas…"), #selector(openAccessibilitySettings))
        menu.addItem(permissionItem)

        menu.addItem(.separator())
        toggleItem = item(L("Control Android Device", "Kendalikan HP"), #selector(toggleRemote), key: "t")
        toggleItem.keyEquivalentModifierMask = [.command, .option] // hanya tampilan; ditangani event tap
        menu.addItem(toggleItem)
        menu.addItem(sensitivityItem())

        menu.addItem(.separator())
        clipboardItem = item(L("Sync Clipboard", "Sinkron clipboard"), #selector(toggleClipboard))
        menu.addItem(clipboardItem)
        sendFilesItem = item(L("Send File…", "Kirim file…"), #selector(chooseFilesToSend))
        menu.addItem(sendFilesItem)

        menu.addItem(.separator())
        menu.addItem(sideMenuItem())
        menu.addItem(connectionMenuItem())
        menu.addItem(forwardMenuItem())
        menu.addItem(settingsMenuItem())

        menu.addItem(.separator())
        menu.addItem(item(L("Quit", "Keluar"), #selector(quit), key: "q"))
        statusItem.menu = menu
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    /// Satu baris: "Kecepatan  ——o——  0.70×".
    private func sensitivityItem() -> NSMenuItem {
        let width: CGFloat = 240
        let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 26))
        container.autoresizingMask = [.width]

        let label = NSTextField(labelWithString: L("Speed", "Kecepatan"))
        label.font = .menuFont(ofSize: 0)
        label.frame = NSRect(x: 28, y: 4, width: 70, height: 18)

        let slider = NSSlider(value: remote.sensitivity, minValue: 0.25, maxValue: 3.0,
                              target: self, action: #selector(sensitivityChanged(_:)))
        slider.controlSize = .small
        slider.isContinuous = true
        slider.frame = NSRect(x: 100, y: 5, width: width - 100 - 58, height: 16)
        slider.autoresizingMask = [.width]

        sensitivityValue.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        sensitivityValue.textColor = .secondaryLabelColor
        sensitivityValue.alignment = .right
        sensitivityValue.frame = NSRect(x: width - 54, y: 5, width: 40, height: 16)
        sensitivityValue.autoresizingMask = [.minXMargin]

        container.addSubview(label)
        container.addSubview(slider)
        container.addSubview(sensitivityValue)
        let item = NSMenuItem()
        item.view = container
        updateSensitivityLabel()
        return item
    }

    private func updateSensitivityLabel() {
        sensitivityValue.stringValue = String(format: "%.2f×", remote.sensitivity)
    }

    /// Judul baris info: penanda berwarna + teks biasa (bukan abu-abu walau item non-aktif).
    private func infoTitle(_ text: String, mark: String, color: NSColor) -> NSAttributedString {
        let title = NSMutableAttributedString(string: mark + "  ", attributes: [
            .font: NSFont.menuFont(ofSize: 0), .foregroundColor: color,
        ])
        title.append(NSAttributedString(string: text, attributes: [
            .font: NSFont.menuFont(ofSize: 0), .foregroundColor: NSColor.labelColor,
        ]))
        return title
    }

    private func render() {
        let snapshot = lastSnapshot
        var connected = false
        let status: String
        var dot: NSColor = .tertiaryLabelColor
        switch snapshot.state {
        case .searching:
            status = L("Searching for your device…", "Mencari HP…")
        case .connecting(let name):
            status = L("Connecting to \(name)…", "Menghubungkan ke \(name)…")
            dot = .systemOrange
        case .awaitingPin(let name):
            status = L("Waiting for PIN · \(name)", "Menunggu PIN · \(name)")
            dot = .systemOrange
        case .connected(let name):
            connected = true
            dot = .systemGreen
            status = [name, snapshot.transport?.label, snapshot.rttMs.map { "\($0) ms" }]
                .compactMap { $0 }.joined(separator: " · ")
        case .paused(let reason):
            status = reason
        }
        statusLine.attributedTitle = infoTitle(status, mark: "●", color: dot)

        let tapReady = remote.capture.isRunning
        permissionItem.isHidden = tapReady

        var alert: String?
        if connected, !(snapshot.screen?.cursorReady ?? false) {
            alert = L("Turn on Cursoe Accessibility on your device", "Aktifkan Aksesibilitas Cursoe di HP")
        } else if connected, tapReady, !remote.isRemote, let refusal = remote.lastRefusal {
            alert = refusal.prefix(1).uppercased() + refusal.dropFirst()
        } else if connected, let screen = snapshot.screen, !screen.keyboardReady {
            alert = L("Turn on Cursoe Keyboard on your device", "Aktifkan Cursoe Keyboard di HP")
        }
        alertLine.attributedTitle = infoTitle(alert ?? "", mark: "⚠︎", color: .systemOrange)
        alertLine.isHidden = alert == nil

        clipboardItem.state = clipboard.enabled ? .on : .off
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        let mode = client.connectionMode
        modeAutoItem.state = mode == .auto ? .on : .off
        modeUsbItem.state = mode == .usb ? .on : .off
        modeWirelessItem.state = mode == .wireless ? .on : .off
        usbLine.title = L("USB cable: \(snapshot.usbStatus)", "Kabel USB: \(snapshot.usbStatus)")
        debugLogItem.state = Log.verbose ? .on : .off

        sendFilesItem.isEnabled = connected
        if case .connected(let name) = snapshot.state { remote.dropZone.deviceName = name }
        sideRightItem.state = remote.side == .right ? .on : .off
        sideLeftItem.state = remote.side == .left ? .on : .off
        sideItem.title = L("Device position: ", "Posisi HP: ") + (remote.side == .right ? L("right", "kanan") : L("left", "kiri"))

        if remote.isRemote {
            toggleItem.title = L("Return to Mac", "Kembali ke Mac")
            toggleItem.isEnabled = true
        } else {
            toggleItem.title = L("Control Android Device", "Kendalikan HP")
            toggleItem.isEnabled = connected && tapReady
        }

        statusItem.button?.appearsDisabled = !connected
        statusItem.button?.contentTintColor = remote.isRemote ? .controlAccentColor : nil
        statusItem.button?.toolTip = "Cursoe — \(status)"
    }

    // MARK: Aksi menu

    @objc private func toggleRemote() {
        if remote.isRemote {
            remote.exitRemote(reason: "menu")
        } else {
            remote.enterRemote()
        }
    }

    // MARK: Submenu

    private func sideMenuItem() -> NSMenuItem {
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        sideRightItem = item(L("Right", "Kanan"), #selector(chooseSideRight))
        sideLeftItem = item(L("Left", "Kiri"), #selector(chooseSideLeft))
        submenu.addItem(sideRightItem)
        submenu.addItem(sideLeftItem)
        sideItem = NSMenuItem(title: L("Device Position", "Posisi HP"), action: nil, keyEquivalent: "")
        sideItem.submenu = submenu
        return sideItem
    }

    private func connectionMenuItem() -> NSMenuItem {
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        modeAutoItem = item(L("Automatic", "Otomatis"), #selector(chooseModeAuto))
        modeUsbItem = item(L("USB Cable", "Kabel USB"), #selector(chooseModeUsb))
        modeWirelessItem = item(L("Wi-Fi / Hotspot", "Wi-Fi / hotspot"), #selector(chooseModeWireless))
        submenu.addItem(modeAutoItem)
        submenu.addItem(modeUsbItem)
        submenu.addItem(modeWirelessItem)
        submenu.addItem(.separator())
        submenu.addItem(item(L("Reconnect", "Hubungkan ulang"), #selector(reconnect)))
        submenu.addItem(item(L("Connect by IP Address…", "Hubungkan lewat IP…"), #selector(manualConnect)))
        submenu.addItem(.separator())
        usbLine.isEnabled = false
        submenu.addItem(usbLine)
        let parent = NSMenuItem(title: L("Connection", "Koneksi"), action: nil, keyEquivalent: "")
        parent.submenu = submenu
        return parent
    }

    /// Port forwarding: daftar port (tiap port punya submenu "Hapus") + "Tambah Port…".
    private func forwardMenuItem() -> NSMenuItem {
        forwardMenu.autoenablesItems = false
        rebuildForwardMenu()
        let parent = NSMenuItem(title: L("Port Forwarding", "Teruskan Port"), action: nil, keyEquivalent: "")
        parent.submenu = forwardMenu
        return parent
    }

    private func rebuildForwardMenu() {
        forwardMenu.removeAllItems()
        let caption = NSMenuItem(title: L("localhost on your device → this Mac", "localhost di HP → Mac ini"), action: nil, keyEquivalent: "")
        caption.isEnabled = false
        forwardMenu.addItem(caption)
        let ports = forwarder.ports
        if ports.isEmpty {
            let none = NSMenuItem(title: L("No ports yet", "Belum ada port"), action: nil, keyEquivalent: "")
            none.isEnabled = false
            forwardMenu.addItem(none)
        }
        for port in ports {
            let remove = item(L("Remove", "Hapus"), #selector(removeForwardPort(_:)))
            remove.tag = port
            let actions = NSMenu()
            actions.addItem(remove)
            let row = NSMenuItem(title: "localhost:\(port)", action: nil, keyEquivalent: "")
            row.submenu = actions
            forwardMenu.addItem(row)
        }
        forwardMenu.addItem(.separator())
        forwardMenu.addItem(item(L("Add Port…", "Tambah Port…"), #selector(addForwardPort)))
    }

    @objc private func addForwardPort() {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = L("Forward a Port", "Teruskan Port")
        alert.informativeText = L(
            "Apps on your device can open http://localhost:PORT to reach the same port on this Mac, for example a " +
                "local dev server. Use a port from 1024 to 65535. Any app on the device can use a forwarded port.",
            "Aplikasi di HP bisa membuka http://localhost:PORT untuk mengakses port yang sama di Mac ini, mis. server " +
                "dev lokal. Gunakan port 1024–65535. Semua aplikasi di HP bisa memakai port yang diteruskan."
        )
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 140, height: 24))
        field.placeholderString = "5173"
        alert.accessoryView = field
        alert.addButton(withTitle: L("Forward", "Teruskan"))
        alert.addButton(withTitle: L("Cancel", "Batal"))
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let text = field.stringValue.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "localhost:", with: "")
        guard let port = Int(text), PortForwarder.allowedPorts.contains(port) else {
            let error = NSAlert()
            error.messageText = L("Invalid port", "Port tidak valid")
            error.informativeText = L("Enter a number from 1024 to 65535.", "Masukkan angka 1024 sampai 65535.")
            error.runModal()
            return
        }
        forwarder.add(port)
        rebuildForwardMenu()
    }

    @objc private func removeForwardPort(_ sender: NSMenuItem) {
        forwarder.remove(sender.tag)
        rebuildForwardMenu()
    }

    private func settingsMenuItem() -> NSMenuItem {
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        loginItem = item(L("Open at Login", "Buka saat login"), #selector(toggleLaunchAtLogin))
        submenu.addItem(loginItem)
        submenu.addItem(.separator())
        debugLogItem = item(L("Debug Log", "Log debug"), #selector(toggleDebugLog))
        submenu.addItem(debugLogItem)
        submenu.addItem(item(L("Open Log File", "Buka file log"), #selector(openLogFile)))
        submenu.addItem(.separator())
        submenu.addItem(item(L("Forget All Pairings", "Lupakan semua pairing"), #selector(forgetPairings)))
        submenu.addItem(.separator())
        let version = NSMenuItem(title: "Cursoe \(appVersion)", action: nil, keyEquivalent: "")
        version.isEnabled = false
        submenu.addItem(version)
        let parent = NSMenuItem(title: L("Settings", "Pengaturan"), action: nil, keyEquivalent: "")
        parent.submenu = submenu
        return parent
    }


    @objc private func chooseModeAuto() { client.setConnectionMode(.auto); render() }
    @objc private func chooseModeUsb() { client.setConnectionMode(.usb); render() }
    @objc private func chooseModeWireless() { client.setConnectionMode(.wireless); render() }

    // MARK: Login & log

    @objc private func toggleLaunchAtLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            Log.info("Buka saat login gagal diubah: \(error.localizedDescription)")
        }
        if service.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
        render()
    }

    @objc private func toggleDebugLog() {
        Log.verbose.toggle()
        render()
    }

    @objc private func openLogFile() {
        if !FileManager.default.fileExists(atPath: Log.fileURL.path) {
            Log.verbose = true // buat file log agar ada yang dibuka
            render()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            NSWorkspace.shared.open(Log.fileURL) // dibuka di Console.app
        }
    }

    @objc private func chooseFilesToSend() {
        NSApp.activate()
        let panel = NSOpenPanel()
        panel.title = L("Send Files to Your Device", "Kirim file ke HP")
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        if panel.runModal() == .OK { sendToPhone(panel.urls) }
    }

    @objc private func toggleClipboard() {
        clipboard.enabled.toggle()
        render()
    }

    @objc private func chooseSideRight() {
        remote.side = .right
        render()
    }

    @objc private func chooseSideLeft() {
        remote.side = .left
        render()
    }

    @objc private func openAccessibilitySettings() {
        InputCapture.requestAccessibility()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func sensitivityChanged(_ sender: NSSlider) {
        remote.sensitivity = (sender.doubleValue * 20).rounded() / 20  // langkah 0,05
        updateSensitivityLabel()
    }

    @objc private func reconnect() {
        client.reconnect(reason: L("requested by user", "diminta pengguna"))
    }

    @objc private func manualConnect() {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = L("Connect by IP Address", "Hubungkan lewat alamat IP")
        alert.informativeText = L(
            "A fallback when your device is not found automatically (for example on office or campus Wi-Fi that " +
                "blocks Bonjour). The address and port are shown in the Cursoe app on your device. Leave empty to turn it off.",
            "Cadangan bila HP tidak ditemukan otomatis (mis. Wi-Fi kampus/kantor yang memblokir Bonjour). " +
                "Alamat & port tampil di aplikasi Cursoe di HP. Kosongkan untuk mematikan."
        )
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = "192.168.1.20:\(BridgeClient.defaultPort)"
        field.stringValue = client.manualHost ?? ""
        alert.accessoryView = field
        alert.addButton(withTitle: L("Save & Connect", "Simpan & hubungkan"))
        alert.addButton(withTitle: L("Cancel", "Batal"))
        alert.window.initialFirstResponder = field
        if alert.runModal() == .alertFirstButtonReturn {
            client.setManualHost(field.stringValue)
        }
    }

    @objc private func forgetPairings() {
        client.forgetPairings()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
