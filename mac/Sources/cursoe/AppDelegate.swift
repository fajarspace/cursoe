import AppKit
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let statusLine = NSMenuItem(title: "Mencari HP…", action: nil, keyEquivalent: "")
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
            self?.client.reconnect(reason: "Mac bangun dari sleep")
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
            self?.remote.exitRemote(reason: "layar Mac dikunci")
        }

        Notifier.shared.setup()
        client.fileHandler = files
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
        remote.exitRemote(reason: "aplikasi ditutup")
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
            remote.exitRemote(reason: "kursor keluar lewat tepi HP", notifyFold: false,
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
        permissionItem = item("⚠︎ Beri izin Aksesibilitas…", #selector(openAccessibilitySettings))
        menu.addItem(permissionItem)

        menu.addItem(.separator())
        toggleItem = item("Kendalikan HP", #selector(toggleRemote), key: "t")
        toggleItem.keyEquivalentModifierMask = [.command, .option] // hanya tampilan; ditangani event tap
        menu.addItem(toggleItem)
        menu.addItem(sensitivityItem())

        menu.addItem(.separator())
        clipboardItem = item("Sinkron clipboard", #selector(toggleClipboard))
        menu.addItem(clipboardItem)
        sendFilesItem = item("Kirim file…", #selector(chooseFilesToSend))
        menu.addItem(sendFilesItem)

        menu.addItem(.separator())
        menu.addItem(sideMenuItem())
        menu.addItem(connectionMenuItem())
        menu.addItem(settingsMenuItem())

        menu.addItem(.separator())
        menu.addItem(item("Keluar", #selector(quit), key: "q"))
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

        let label = NSTextField(labelWithString: "Kecepatan")
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
            status = "Mencari HP…"
        case .connecting(let name):
            status = "Menghubungkan ke \(name)…"
            dot = .systemOrange
        case .awaitingPin(let name):
            status = "Menunggu PIN · \(name)"
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
            alert = "Aktifkan Aksesibilitas Cursoe di HP"
        } else if connected, tapReady, !remote.isRemote, let refusal = remote.lastRefusal {
            alert = refusal.prefix(1).uppercased() + refusal.dropFirst()
        } else if connected, let screen = snapshot.screen, !screen.keyboardReady {
            alert = "Aktifkan Cursoe Keyboard di HP"
        }
        alertLine.attributedTitle = infoTitle(alert ?? "", mark: "⚠︎", color: .systemOrange)
        alertLine.isHidden = alert == nil

        clipboardItem.state = clipboard.enabled ? .on : .off
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        let mode = client.connectionMode
        modeAutoItem.state = mode == .auto ? .on : .off
        modeUsbItem.state = mode == .usb ? .on : .off
        modeWirelessItem.state = mode == .wireless ? .on : .off
        usbLine.title = "Kabel USB: \(snapshot.usbStatus)"
        debugLogItem.state = Log.verbose ? .on : .off

        sendFilesItem.isEnabled = connected
        if case .connected(let name) = snapshot.state { remote.dropZone.deviceName = name }
        sideRightItem.state = remote.side == .right ? .on : .off
        sideLeftItem.state = remote.side == .left ? .on : .off
        sideItem.title = "Posisi HP: " + (remote.side == .right ? "kanan" : "kiri")

        if remote.isRemote {
            toggleItem.title = "Kembali ke Mac"
            toggleItem.isEnabled = true
        } else {
            toggleItem.title = "Kendalikan HP"
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
        sideRightItem = item("Kanan", #selector(chooseSideRight))
        sideLeftItem = item("Kiri", #selector(chooseSideLeft))
        submenu.addItem(sideRightItem)
        submenu.addItem(sideLeftItem)
        sideItem = NSMenuItem(title: "Posisi HP", action: nil, keyEquivalent: "")
        sideItem.submenu = submenu
        return sideItem
    }

    private func connectionMenuItem() -> NSMenuItem {
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        modeAutoItem = item("Otomatis", #selector(chooseModeAuto))
        modeUsbItem = item("Kabel USB", #selector(chooseModeUsb))
        modeWirelessItem = item("Wi-Fi / hotspot", #selector(chooseModeWireless))
        submenu.addItem(modeAutoItem)
        submenu.addItem(modeUsbItem)
        submenu.addItem(modeWirelessItem)
        submenu.addItem(.separator())
        submenu.addItem(item("Hubungkan ulang", #selector(reconnect)))
        submenu.addItem(item("Hubungkan lewat IP…", #selector(manualConnect)))
        submenu.addItem(.separator())
        usbLine.isEnabled = false
        submenu.addItem(usbLine)
        let parent = NSMenuItem(title: "Koneksi", action: nil, keyEquivalent: "")
        parent.submenu = submenu
        return parent
    }

    private func settingsMenuItem() -> NSMenuItem {
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        loginItem = item("Buka saat login", #selector(toggleLaunchAtLogin))
        submenu.addItem(loginItem)
        submenu.addItem(.separator())
        debugLogItem = item("Log debug", #selector(toggleDebugLog))
        submenu.addItem(debugLogItem)
        submenu.addItem(item("Buka file log", #selector(openLogFile)))
        submenu.addItem(.separator())
        submenu.addItem(item("Lupakan semua pairing", #selector(forgetPairings)))
        submenu.addItem(.separator())
        let version = NSMenuItem(title: "Cursoe \(appVersion)", action: nil, keyEquivalent: "")
        version.isEnabled = false
        submenu.addItem(version)
        let parent = NSMenuItem(title: "Pengaturan", action: nil, keyEquivalent: "")
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
        panel.title = "Kirim file ke HP"
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
        client.reconnect(reason: "diminta pengguna")
    }

    @objc private func manualConnect() {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Hubungkan lewat alamat IP"
        alert.informativeText = """
            Cadangan bila HP tidak ditemukan otomatis (mis. Wi-Fi kampus/kantor yang memblokir Bonjour). \
            Alamat & port tampil di aplikasi Cursoe di HP. Kosongkan untuk mematikan.
            """
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = "192.168.1.20:\(BridgeClient.defaultPort)"
        field.stringValue = client.manualHost ?? ""
        alert.accessoryView = field
        alert.addButton(withTitle: "Simpan & hubungkan")
        alert.addButton(withTitle: "Batal")
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
