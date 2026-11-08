import AppKit
import QuickLookThumbnailing

/// HP → Mac: panel pilihan setelah file tersimpan di Downloads (desain sama dengan panel di HP).
///   Simpan · aplikasi Mac yang cocok · Finder.  × = jangan simpan (pindah ke Tempat Sampah).
///   Klik di luar panel / Esc / Return = simpan.
final class ReceivedPanel: NSObject, NSWindowDelegate {
    static let shared = ReceivedPanel()

    private var panel: KeyPanel?
    private var urls: [URL] = []
    private var finished = true

    enum Action {
        case save, finder, discard
        case open(URL)
        case more([URL], NSView)
    }

    func show(for urls: [URL]) {
        guard !urls.isEmpty else { return }
        close(keep: true, animated: false) // panel sebelumnya: dianggap disimpan
        self.urls = urls
        finished = false

        let view = ReceivedView(urls: urls, apps: OpenWithMenu.applications(for: urls)) { [weak self] action in
            self?.handle(action)
        }
        let size = view.frame.size
        let panel = KeyPanel(contentRect: NSRect(origin: .zero, size: size),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = view
        panel.delegate = self
        panel.onKey = { [weak self] code in
            if code == 53 || code == 36 || code == 76 { self?.close(keep: true) } // Esc / Return / Enter
        }

        let target = Self.frameNearCursor(size: size)
        panel.setFrame(target.offsetBy(dx: 0, dy: -10), display: false)
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
            panel.animator().setFrame(target, display: true)
        }
        view.animateIn()
    }

    func windowDidResignKey(_ notification: Notification) {
        close(keep: true) // klik di luar panel = simpan
    }

    private func handle(_ action: Action) {
        switch action {
        case .save:
            close(keep: true)
        case .finder:
            NSWorkspace.shared.activateFileViewerSelecting(urls)
            close(keep: true)
        case .open(let app):
            NSWorkspace.shared.open(urls, withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
            close(keep: true)
        case .discard:
            close(keep: false)
        case .more(let apps, let anchor):
            let menu = NSMenu()
            for app in apps {
                let item = ClosureMenuItem(Self.appName(app)) { [weak self] in self?.handle(.open(app)) }
                let icon = NSWorkspace.shared.icon(forFile: app.path)
                icon.size = NSSize(width: 16, height: 16)
                item.image = icon
                menu.addItem(item)
            }
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: anchor.bounds.height + 4), in: anchor)
        }
    }

    private func close(keep: Bool, animated: Bool = true) {
        guard !finished else { return }
        finished = true
        let files = urls
        if !keep {
            for url in files {
                do {
                    try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                } catch {
                    Log.info("Gagal membuang \(url.lastPathComponent): \(error.localizedDescription)")
                }
            }
            Log.info("File dari HP tidak disimpan (dipindah ke Tempat Sampah): \(files.count) file")
        }
        guard let panel else { return }
        self.panel = nil
        panel.delegate = nil
        guard animated else { return panel.orderOut(nil) }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.15
            panel.animator().alphaValue = 0
            panel.animator().setFrame(panel.frame.offsetBy(dx: 0, dy: -6), display: true)
        }, completionHandler: { panel.orderOut(nil) })
    }

    /// Dekat kursor (di bawahnya bila muat), selalu di dalam layar.
    private static func frameNearCursor(size: NSSize) -> NSRect {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        let visible = (screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)).insetBy(dx: 12, dy: 12)
        var origin = NSPoint(x: mouse.x - size.width / 2, y: mouse.y - size.height - 18)
        if origin.y < visible.minY { origin.y = mouse.y + 18 }
        origin.x = min(max(origin.x, visible.minX), visible.maxX - size.width)
        origin.y = min(max(origin.y, visible.minY), visible.maxY - size.height)
        return NSRect(origin: origin, size: size)
    }

    static func appName(_ app: URL) -> String {
        FileManager.default.displayName(atPath: app.path).replacingOccurrences(of: ".app", with: "")
    }
}

/// Panel yang bisa menjadi key tanpa mengaktifkan aplikasi (untuk Esc & deteksi klik di luar).
final class KeyPanel: NSPanel {
    var onKey: ((UInt16) -> Void)?
    override var canBecomeKey: Bool { true }
    override func keyDown(with event: NSEvent) { onKey?(event.keyCode) }
}

// MARK: - Warna (monokrom: hitam di mode terang, putih di mode gelap; latar kaca buram)

enum Palette {
    static let ink = NSColor(srgbRed: 0x09 / 255, green: 0x09 / 255, blue: 0x0B / 255, alpha: 1)
    /// Warna utama: hitam (terang) / putih (gelap).
    static let primary = dynamic(light: ink, dark: .white)
    static let onPrimary = dynamic(light: .white, dark: ink)
    /// Lapisan tipis di atas blur agar kaca terasa "susu" seperti Luma.
    static let glassTint = dynamic(light: NSColor.white.withAlphaComponent(0.45), dark: NSColor.black.withAlphaComponent(0.28))
    static let chip = dynamic(light: NSColor.black.withAlphaComponent(0.06), dark: NSColor.white.withAlphaComponent(0.1))
    static let border = dynamic(light: NSColor.black.withAlphaComponent(0.08), dark: NSColor.white.withAlphaComponent(0.13))
    static let hover = dynamic(light: NSColor.black.withAlphaComponent(0.05), dark: NSColor.white.withAlphaComponent(0.08))

    static func dynamic(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light }
    }
}

extension NSImage {
    /// Masker sudut bulat yang bisa direntangkan (untuk NSVisualEffectView.maskImage).
    static func roundedMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.set()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}

extension NSView {
    /// Warna dinamis → CGColor sesuai tampilan view ini.
    func cg(_ color: NSColor) -> CGColor {
        var result = color.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance { result = color.cgColor }
        return result
    }
}

// MARK: - Isi panel

private final class ReceivedView: NSView {
    private let urls: [URL]
    private let onAction: (ReceivedPanel.Action) -> Void
    private var cells: [GridCell] = []
    private let thumbnail = NSImageView()
    private let closeButton = HoverButton()
    private let tint = NSView()

    private static let radius: CGFloat = 22
    private static let padding: CGFloat = 16
    private static let columns = 6
    private static let cellSize = NSSize(width: 66, height: 80)
    private static let headerHeight: CGFloat = 48
    private static let maxApps = 2 * columns - 2 // 2 baris: Simpan + aplikasi + Finder

    override var isFlipped: Bool { true }

    init(urls: [URL], apps: [URL], onAction: @escaping (ReceivedPanel.Action) -> Void) {
        self.urls = urls
        self.onAction = onAction
        let shown = apps.count > Self.maxApps ? Array(apps.prefix(Self.maxApps - 1)) : apps
        let rest = apps.count > Self.maxApps ? Array(apps.dropFirst(Self.maxApps - 1)) : []
        let count = 1 + shown.count + (rest.isEmpty ? 0 : 1) + 1
        let rows = (count + Self.columns - 1) / Self.columns
        let width = Self.padding * 2 + CGFloat(Self.columns) * Self.cellSize.width
        let height = Self.padding * 2 + Self.headerHeight + 10 + CGFloat(rows) * Self.cellSize.height
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: height))
        wantsLayer = true
        layer?.cornerRadius = Self.radius
        layer?.borderWidth = 0.5

        // Kaca buram: blur isi layar di belakang panel + lapisan tipis.
        let blur = NSVisualEffectView(frame: bounds)
        blur.material = .popover
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.maskImage = .roundedMask(radius: Self.radius)
        blur.autoresizingMask = [.width, .height]
        addSubview(blur)
        tint.frame = bounds
        tint.wantsLayer = true
        tint.layer?.cornerRadius = Self.radius
        tint.autoresizingMask = [.width, .height]
        addSubview(tint)

        buildHeader(width: width)

        var items: [GridCell] = []
        items.append(GridCell(image: GridCell.circle(symbol: "arrow.down.to.line", fill: Palette.primary, tint: Palette.onPrimary),
                              title: "Simpan", toolTip: "Simpan di Downloads") { onAction(.save) })
        for app in shown {
            let icon = Self.loadedIcon(app)
            items.append(GridCell(image: icon, title: ReceivedPanel.appName(app), toolTip: "Buka dengan \(ReceivedPanel.appName(app))") {
                onAction(.open(app))
            })
        }
        if !rest.isEmpty {
            var cell: GridCell!
            cell = GridCell(image: GridCell.circle(symbol: "ellipsis", fill: Palette.chip, tint: .labelColor),
                            title: "Lainnya…", toolTip: "Aplikasi lain") { onAction(.more(rest, cell)) }
            items.append(cell)
        }
        let finder = Self.loadedIcon(URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app"))
        items.append(GridCell(image: finder, title: "Finder", toolTip: "Tampilkan di Finder") { onAction(.finder) })

        for (i, cell) in items.enumerated() {
            let col = CGFloat(i % Self.columns), row = CGFloat(i / Self.columns)
            cell.frame = NSRect(x: Self.padding + col * Self.cellSize.width,
                                y: Self.padding + Self.headerHeight + 10 + row * Self.cellSize.height,
                                width: Self.cellSize.width, height: Self.cellSize.height)
            addSubview(cell)
        }
        cells = items
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) tidak dipakai") }

    /// Ikon aplikasi dari macOS dimuat malas (sempat tampil sebagai kotak putus-putus);
    /// rasterkan sekarang agar langsung tampil utuh.
    private static func loadedIcon(_ app: URL) -> NSImage {
        rasterized(NSWorkspace.shared.icon(forFile: app.path))
    }

    private static func rasterized(_ icon: NSImage) -> NSImage {
        var rect = NSRect(x: 0, y: 0, width: 84, height: 84)
        guard let cg = icon.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return icon }
        return NSImage(cgImage: cg, size: NSSize(width: 42, height: 42))
    }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.borderColor = cg(Palette.border)
        tint.layer?.backgroundColor = cg(Palette.glassTint)
        thumbnail.layer?.backgroundColor = cg(Palette.chip)
    }

    override var wantsUpdateLayer: Bool { true }

    private func buildHeader(width: CGFloat) {
        let p = Self.padding
        thumbnail.frame = NSRect(x: p, y: p + 2, width: 44, height: 44)
        thumbnail.wantsLayer = true
        thumbnail.layer?.cornerRadius = 12
        thumbnail.layer?.masksToBounds = true
        thumbnail.imageScaling = .scaleProportionallyUpOrDown
        let fileIcon = urls.count == 1 ? nil : NSWorkspace.shared.icon(forFiles: urls.map(\.path))
        thumbnail.image = Self.rasterized(fileIcon ?? NSWorkspace.shared.icon(forFile: urls[0].path))
        addSubview(thumbnail)
        loadThumbnail()

        let title = NSTextField(labelWithString: urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) file dari HP")
        title.font = .systemFont(ofSize: 13.5, weight: .semibold)
        title.lineBreakMode = .byTruncatingMiddle
        title.frame = NSRect(x: p + 56, y: p + 5, width: width - p * 2 - 56 - 40, height: 18)
        addSubview(title)

        let bytes = urls.reduce(Int64(0)) { sum, url in
            sum + Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        let subtitle = NSTextField(labelWithString: "Downloads · " + ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
        subtitle.font = .systemFont(ofSize: 11.5)
        subtitle.textColor = .secondaryLabelColor
        subtitle.frame = NSRect(x: p + 56, y: p + 25, width: width - p * 2 - 56 - 40, height: 16)
        addSubview(subtitle)

        closeButton.frame = NSRect(x: width - p - 28, y: p + 10, width: 28, height: 28)
        closeButton.restingFill = Palette.chip
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Jangan simpan")?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .semibold))
        closeButton.toolTip = "Jangan simpan (pindah ke Tempat Sampah)"
        closeButton.onClick = { [weak self] in self?.onAction(.discard) }
        addSubview(closeButton)
    }

    /// Pratinjau Quick Look (foto, video, PDF, …) untuk satu file; selain itu ikon file.
    private func loadThumbnail() {
        guard urls.count == 1 else { return }
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let request = QLThumbnailGenerator.Request(fileAt: urls[0], size: CGSize(width: 88, height: 88),
                                                   scale: scale, representationTypes: .thumbnail)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] rep, _ in
            guard let image = rep?.nsImage else { return }
            DispatchQueue.main.async {
                guard let self else { return }
                self.thumbnail.imageScaling = .scaleAxesIndependently
                self.thumbnail.image = image
                self.thumbnail.alphaValue = 0
                NSAnimationContext.runAnimationGroup { $0.duration = 0.18; self.thumbnail.animator().alphaValue = 1 }
            }
        }
    }

    /// Ikon muncul berurutan.
    func animateIn() {
        let now = CACurrentMediaTime()
        for (i, cell) in cells.enumerated() {
            guard let layer = cell.layer else { continue }
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0
            fade.toValue = 1
            let rise = CABasicAnimation(keyPath: "transform.translation.y")
            rise.fromValue = -8 // view terbalik (flipped): nilai negatif = dari bawah
            rise.toValue = 0
            let group = CAAnimationGroup()
            group.animations = [fade, rise]
            group.beginTime = now + 0.05 + Double(i) * 0.025
            group.duration = 0.24
            group.timingFunction = CAMediaTimingFunction(name: .easeOut)
            group.fillMode = .backwards
            layer.add(group, forKey: "in")
        }
    }
}

/// Sel ikon: hover menyorot, ditekan mengecil, dilepas memantul lalu menjalankan aksi.
private final class GridCell: NSView {
    private let action: () -> Void
    private let icon = NSImageView()
    private let label: NSTextField
    private var hovering = false { didSet { needsDisplay = true; updateLayer() } }

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    init(image: NSImage, title: String, toolTip: String, action: @escaping () -> Void) {
        self.action = action
        label = NSTextField(labelWithString: title)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 12
        self.toolTip = toolTip
        icon.image = image
        icon.imageScaling = .scaleProportionallyUpOrDown
        label.font = .systemFont(ofSize: 11)
        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail
        addSubview(icon)
        addSubview(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) tidak dipakai") }

    override func layout() {
        super.layout()
        icon.frame = NSRect(x: (bounds.width - 42) / 2, y: 8, width: 42, height: 42)
        label.frame = NSRect(x: 2, y: 54, width: bounds.width - 4, height: 16)
    }

    override func updateLayer() {
        layer?.backgroundColor = hovering ? cg(Palette.hover) : NSColor.clear.cgColor
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    override func mouseDown(with event: NSEvent) { scale(to: 0.92, duration: 0.08) }

    override func mouseUp(with event: NSEvent) {
        scale(to: 1, duration: 0.18, spring: true)
        if bounds.contains(convert(event.locationInWindow, from: nil)) { action() }
    }

    private func scale(to value: CGFloat, duration: CFTimeInterval, spring: Bool = false) {
        guard let layer else { return }
        // Skala dari tengah sel.
        layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        layer.position = CGPoint(x: frame.midX, y: frame.midY)
        let anim: CABasicAnimation = spring ? {
            let s = CASpringAnimation(keyPath: "transform.scale")
            s.damping = 12
            s.initialVelocity = 4
            return s
        }() : CABasicAnimation(keyPath: "transform.scale")
        anim.fromValue = layer.presentation()?.value(forKeyPath: "transform.scale") ?? 1
        anim.toValue = value
        anim.duration = spring ? 0.35 : duration
        layer.setValue(value, forKeyPath: "transform.scale")
        layer.add(anim, forKey: "scale")
    }

    /// Lingkaran berwarna dengan simbol di tengah (ikon "Simpan", "Lainnya").
    static func circle(symbol: String, fill: NSColor, tint: NSColor) -> NSImage {
        NSImage(size: NSSize(width: 42, height: 42), flipped: false) { rect in
            fill.setFill()
            NSBezierPath(ovalIn: rect).fill()
            if let glyph = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 16, weight: .semibold)) {
                let tinted = NSImage(size: glyph.size, flipped: false) { r in
                    glyph.draw(in: r)
                    tint.set()
                    r.fill(using: .sourceAtop)
                    return true
                }
                tinted.draw(in: NSRect(x: rect.midX - glyph.size.width / 2, y: rect.midY - glyph.size.height / 2,
                                       width: glyph.size.width, height: glyph.size.height))
            }
            return true
        }
    }
}

/// Tombol ikon kecil dengan sorotan bulat saat hover.
final class HoverButton: NSView {
    var onClick: (() -> Void)?
    var image: NSImage? { didSet { imageView.image = image } }
    /// Isi bulatan saat tidak di-hover (nil = transparan).
    var restingFill: NSColor? { didSet { updateLayer() } }
    private let imageView = NSImageView()
    private var hovering = false { didSet { updateLayer() } }

    override var wantsUpdateLayer: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        imageView.contentTintColor = .secondaryLabelColor
        addSubview(imageView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) tidak dipakai") }

    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.height / 2
        imageView.frame = bounds
    }

    override func updateLayer() {
        let rest = restingFill.map(cg) ?? NSColor.clear.cgColor
        layer?.backgroundColor = hovering ? cg(Palette.border) : rest
        imageView.contentTintColor = hovering ? .labelColor : .secondaryLabelColor
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }
}

#if PREVIEW
/// Uji tampilan (swiftc -D PREVIEW): render panel ke gambar tanpa menampilkannya di layar.
extension ReceivedPanel {
    static func previewImage(for urls: [URL], dark: Bool) -> NSBitmapImageRep? {
        let view = ReceivedView(urls: urls, apps: OpenWithMenu.applications(for: urls)) { _ in }
        return renderOffscreen(view, dark: dark)
    }
}

func renderOffscreen(_ view: NSView, dark: Bool) -> NSBitmapImageRep? {
    let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: view.frame.width + 40, height: view.frame.height + 40),
                          styleMask: [.borderless], backing: .buffered, defer: false)
    window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    window.backgroundColor = dark ? .black : NSColor(white: 0.93, alpha: 1)
    let container = NSView(frame: NSRect(origin: .zero, size: window.frame.size))
    container.wantsLayer = true
    container.layer?.backgroundColor = window.backgroundColor.cgColor
    view.frame.origin = NSPoint(x: 20, y: 20)
    container.addSubview(view)
    window.contentView = container
    window.displayIfNeeded()
    container.layoutSubtreeIfNeeded()
    view.subviews.forEach { $0.needsDisplay = true }
    window.display()
    guard let rep = container.bitmapImageRepForCachingDisplay(in: container.bounds) else { return nil }
    container.cacheDisplay(in: container.bounds, to: rep)
    return rep
}
#endif
