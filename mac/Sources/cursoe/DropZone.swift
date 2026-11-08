import AppKit

/// Area lepas di tepi layar (sisi HP): hanya blur lembut yang menempel di tepi dan memudar ke
/// tengah layar (tanpa kotak/kapsul). File diseret mendekat → blur melebar, muncul ikon HP +
/// nama perangkat. Dilepas → ✓ "Terkirim", lalu blur menyusut ke tepi dan hilang.
/// Drag-and-drop asli macOS: lepas file di sini → dikirim ke HP.
final class DropZone {
    var onDrop: (([URL]) -> Void)?
    var deviceName = L("Android", "HP") {
        didSet { view?.deviceName = deviceName }
    }

    private var panel: NSPanel?
    private var view: MistView?
    private var hideWork: DispatchWorkItem?
    fileprivate static let size = NSSize(width: 340, height: 660)

    var isVisible: Bool { panel?.isVisible ?? false }

    /// [display] dalam koordinat CoreGraphics (origin kiri-atas). Blur mengikuti tinggi kursor.
    func show(on display: CGRect, side: FoldSide) {
        hideWork?.cancel()
        hideWork = nil
        let panel = self.panel ?? makePanel()
        let target = frame(on: display, side: side)
        guard let view else { return }
        if !panel.isVisible || view.isDisappearing {
            panel.setFrame(target, display: false)
            view.side = side
            view.reset()
            panel.alphaValue = 1
            panel.orderFrontRegardless()
            view.appear()
        } else if !view.highlighted {
            panel.setFrame(target, display: true) // ikuti kursor selama file belum di atas area lepas
        }
    }

    /// Setelah tombol mouse dilepas (drop sudah diproses lebih dulu oleh sistem).
    func hideSoon(after delay: TimeInterval = 0.4) {
        guard isVisible else { return }
        // Mouse dilepas sesudah drop: biarkan "Terkirim ✓" terlihat dulu.
        let delay = view?.isSent == true ? max(delay, 0.9) : delay
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.hide() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func hide() {
        hideWork?.cancel()
        hideWork = nil
        guard let panel, panel.isVisible, let view else { return }
        view.disappear { [weak self] in
            guard self?.hideWork == nil, view.isDisappearing else { return }
            panel.orderOut(nil)
        }
    }

    private func frame(on display: CGRect, side: FoldSide) -> NSRect {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? display.height
        let cocoa = NSRect(x: display.minX, y: primaryHeight - display.maxY, width: display.width, height: display.height)
        let height = min(Self.size.height, cocoa.height)
        let mouseY = NSEvent.mouseLocation.y
        let y = min(max(mouseY - height / 2, cocoa.minY), cocoa.maxY - height)
        let x = side == .right ? cocoa.maxX - Self.size.width : cocoa.minX
        return NSRect(x: x, y: y, width: Self.size.width, height: height)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: Self.size), styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let view = MistView(frame: NSRect(origin: .zero, size: Self.size))
        view.autoresizingMask = [.width, .height]
        view.deviceName = deviceName
        view.onDrop = { [weak self] urls in
            self?.onDrop?(urls)
            self?.hideSoon(after: 0.9) // biarkan L("Sent ✓", "Terkirim ✓") terlihat
        }
        panel.contentView = view
        self.panel = panel
        self.view = view
        return panel
    }
}

/// Blur di tepi: dua NSVisualEffectView (blur isi layar di belakangnya) seukuran panel, masing-masing
/// dengan masker gradien elips yang menempel di tepi — "dekat" (sempit, saat diam) dan "lebar"
/// (saat file di atasnya). Pelebaran = transisi silang keduanya. Masker dibuat persis seukuran
/// panel (maskImage NSVisualEffectView tidak ikut meregang). + kilau tipis, ikon & teks.
private final class MistView: NSView {
    var onDrop: (([URL]) -> Void)?
    var side: FoldSide = .right {
        didSet { if side != oldValue { applyShape() } }
    }
    var deviceName = L("Android", "HP") { didSet { if !sent { title.stringValue = deviceName } } }
    private(set) var highlighted = false
    private(set) var isDisappearing = false
    private var sent = false
    var isSent: Bool { sent }

    private let near = NSVisualEffectView()
    private let wide = NSVisualEffectView()
    private let sheen = NSView()
    private let content = NSView()
    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let subtitle = NSTextField(labelWithString: L("Drop to send", "Lepas untuk mengirim"))
    private var shapedSize = NSSize.zero

    /// Jari-jari elips: horizontal (dari tepi layar) × vertikal.
    private static let nearRadii = NSSize(width: 120, height: 220)
    private static let wideRadii = NSSize(width: 335, height: 330)
    /// Jarak pusat ikon/teks dari tepi layar.
    private static let contentInset: CGFloat = 122
    private static let slide: CGFloat = 14

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        for blur in [near, wide] {
            blur.material = .popover
            blur.blendingMode = .behindWindow
            blur.state = .active
            blur.alphaValue = 0
            addSubview(blur)
        }
        sheen.wantsLayer = true
        sheen.layer?.contentsGravity = .resize
        sheen.alphaValue = 0
        addSubview(sheen)

        icon.imageScaling = .scaleProportionallyUpOrDown
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.alignment = .center
        title.lineBreakMode = .byTruncatingTail
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor
        subtitle.alignment = .center
        content.alphaValue = 0
        [icon, title, subtitle].forEach(content.addSubview)
        addSubview(content)

        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) tidak dipakai") }

    // MARK: Tata letak

    private var dark: Bool { effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyShape()
    }

    override func layout() {
        super.layout()
        for view in [near, wide, sheen] { view.frame = bounds }
        if bounds.size != shapedSize { applyShape() }
        content.frame = contentFrame(hidden: !highlighted && !sent)
        let width = content.bounds.width
        icon.frame = NSRect(x: (width - 34) / 2, y: 52, width: 34, height: 34)
        title.frame = NSRect(x: 0, y: 26, width: width, height: 18)
        subtitle.frame = NSRect(x: 0, y: 8, width: width, height: 15)
    }

    /// Masker & kilau persis seukuran view, sesuai sisi layar dan tema.
    private func applyShape() {
        let size = bounds.size
        guard size.width > 0, size.height > 0 else { return }
        shapedSize = size
        near.maskImage = Self.mistImage(size: size, radii: Self.nearRadii, side: side, white: 0, peak: 1)
        wide.maskImage = Self.mistImage(size: size, radii: Self.wideRadii, side: side, white: 0, peak: 1)
        // Kilau tipis: membuat blur terlihat "berembun" (lebih terasa di mode terang).
        let gloss = Self.mistImage(size: size, radii: Self.wideRadii, side: side, white: 1, peak: dark ? 0.07 : 0.35)
        var rect = NSRect(origin: .zero, size: size)
        sheen.layer?.contents = gloss.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }

    /// Posisi ikon & teks; [hidden] = sedikit bergeser ke arah tepi (posisi awal sebelum muncul).
    private func contentFrame(hidden: Bool) -> NSRect {
        let width: CGFloat = 200, height: CGFloat = 92
        let centerX = side == .right ? bounds.maxX - Self.contentInset : bounds.minX + Self.contentInset
        let shift = hidden ? (side == .right ? Self.slide : -Self.slide) : 0
        return NSRect(x: centerX - width / 2 + shift, y: bounds.midY - height / 2, width: width, height: height)
    }

    private func fade(_ duration: TimeInterval, curve: CAMediaTimingFunctionName = .easeOut,
                      _ changes: () -> Void, done: (() -> Void)? = nil) {
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: curve)
            changes()
        }, completionHandler: done)
    }

    // MARK: Keadaan

    func reset() {
        isDisappearing = false
        sent = false
        highlighted = false
        title.stringValue = deviceName
        subtitle.stringValue = L("Drop to send", "Lepas untuk mengirim")
        icon.image = Self.symbol("iphone")
        icon.contentTintColor = .labelColor
        [near, wide, sheen, content].forEach { $0.alphaValue = 0 }
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    /// Muncul: blur sempit memudar masuk di tepi.
    func appear() {
        fade(0.25) { near.animator().alphaValue = 1 }
    }

    private func setHighlighted(_ on: Bool) {
        guard on != highlighted, !sent else { return }
        highlighted = on
        fade(on ? 0.3 : 0.22) {
            wide.animator().alphaValue = on ? 1 : 0
            sheen.animator().alphaValue = on ? 1 : 0
            content.animator().alphaValue = on ? 1 : 0
            content.animator().frame = contentFrame(hidden: !on)
        }
    }

    /// Terkirim: ✓ + "Terkirim", kilau berkedip sekali.
    private func playSent() {
        sent = true
        icon.image = Self.symbol("checkmark.circle.fill")
        title.stringValue = L("Sent", "Terkirim")
        subtitle.stringValue = L("to \(deviceName)", "ke \(deviceName)")
        fade(0.12, { sheen.animator().alphaValue = 0.3 }, done: { [weak self] in
            guard let self, !self.isDisappearing else { return }
            self.fade(0.3) { self.sheen.animator().alphaValue = 1 }
        })
    }

    /// Hilang: semua lapisan memudar.
    func disappear(completion: @escaping () -> Void) {
        isDisappearing = true
        highlighted = false
        fade(0.24, curve: .easeIn, {
            [near, wide, sheen, content].forEach { $0.animator().alphaValue = 0 }
        }, done: completion)
    }

    // MARK: Drag & drop

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        setHighlighted(true)
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        setHighlighted(false)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] ?? []
        guard !urls.isEmpty else {
            setHighlighted(false)
            return false
        }
        playSent()
        onDrop?(urls)
        return true
    }

    // MARK: Gambar

    private static func symbol(_ name: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 26, weight: .regular))
    }

    /// Gradien elips berpusat di tengah tepi layar (pekat di tepi, memudar halus ke dalam & ke
    /// atas/bawah), digambar persis seukuran [size]. Untuk masker cukup alfanya; untuk kilau warnanya putih.
    private static func mistImage(size: NSSize, radii: NSSize, side: FoldSide, white: CGFloat, peak: CGFloat) -> NSImage {
        NSImage(size: size, flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            let space = CGColorSpace(name: CGColorSpace.sRGB)!
            let stops: [(CGFloat, CGFloat)] = [(0, 1), (0.35, 0.93), (0.62, 0.55), (0.84, 0.16), (1, 0)]
            let colors = stops.map { CGColor(srgbRed: white, green: white, blue: white, alpha: peak * $0.1) } as CFArray
            guard let gradient = CGGradient(colorsSpace: space, colors: colors, locations: stops.map(\.0)) else { return false }
            let ry = min(radii.height, rect.height / 2)
            let rx = min(radii.width, rect.width)
            ctx.translateBy(x: side == .right ? rect.maxX : rect.minX, y: rect.midY)
            ctx.scaleBy(x: rx / ry, y: 1) // lingkaran → elips
            ctx.drawRadialGradient(gradient, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: ry, options: [])
            return true
        }
    }

    #if PREVIEW
    func previewHover() { reset(); near.alphaValue = 1; setHighlighted(true) }
    func previewSent() { previewHover(); playSent() }
    #endif
}

#if PREVIEW
extension DropZone {
    /// Uji tampilan: blur diam, file di atasnya, dan sesudah dilepas.
    /// (Blur asli tidak ter-render offscreen; yang terlihat adalah kilau dengan bentuk yang sama.)
    static func previewImages(dark: Bool) -> [NSBitmapImageRep] {
        ["normal", "hover", "sent"].compactMap { state in
            let view = MistView(frame: NSRect(origin: .zero, size: size))
            view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            view.deviceName = "Galaxy Z Fold6"
            view.side = .right
            switch state {
            case "hover": view.previewHover()
            case "sent": view.previewSent()
            default: view.reset(); view.appear()
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.7)) // biarkan animasi selesai
            return renderOffscreen(view, dark: dark)
        }
    }
}
#endif
