// Latar Mac untuk rekaman demo (ditutup oleh skrip perekam sesudah selesai; tidak menyentuh aplikasi lain).
//
//   DemoBackdrop <url>                              halaman web polos (tanpa bilah tab/alamat) selayar
//   DemoBackdrop --desktop <target.json> <file>…   "desktop" (wallpaper asli) + file yang bisa diseret
//
// Mode desktop: file ditampilkan seperti ikon di desktop Finder (foto: thumbnail; lainnya: ikon sistem),
// tersusun dari atas ke bawah. Foto .jpg dibuat (pemandangan sederhana) bila belum ada. Posisi tiap
// file (koordinat layar, origin kiri-atas) ditulis ke target.json ("files": [[x, y], …]) untuk DemoDriver.
import AppKit
import WebKit

let arguments = Array(CommandLine.arguments.dropFirst())
let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let screen = NSScreen.main!
let menuBar = screen.frame.maxY - screen.visibleFrame.maxY
let frame = NSRect(x: screen.frame.minX, y: screen.frame.minY, width: screen.frame.width,
                   height: screen.frame.height - menuBar)
let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
window.level = .floating // di atas jendela lain (yang tetap utuh), di bawah menu bar & panel Cursoe
// Tampil juga di Space aplikasi layar penuh (mis. browser full screen) dan di semua desktop.
window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
window.isReleasedWhenClosed = false
window.backgroundColor = .black

// MARK: - Mode web

/// Situs React: anchor (#fitur) baru ada sesudah render, jadi gulir ke sana lewat JavaScript.
final class Scroller: NSObject, WKNavigationDelegate {
    let anchor: String?
    init(anchor: String?) { self.anchor = anchor }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let anchor, !anchor.isEmpty else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
            webView.evaluateJavaScript("document.getElementById('\(anchor)')?.scrollIntoView({behavior:'instant'})")
        }
    }
}

// MARK: - Mode desktop

/// Latar "desktop": wallpaper desktop Mac yang sedang dipakai (isi layar penuh, seperti desktop asli).
/// Bila tidak bisa dibaca: hitam kebiruan dengan cahaya biru buram (selaras dengan website).
final class Wallpaper: NSView {
    let image: NSImage? = NSWorkspace.shared.desktopImageURL(for: NSScreen.main!).flatMap { NSImage(contentsOf: $0) }

    override func draw(_ dirtyRect: NSRect) {
        if let image, image.size.width > 0 {
            // aspect-fill, berpusat (sama dengan "Fill Screen" di macOS)
            let scale = max(bounds.width / image.size.width, bounds.height / image.size.height)
            let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
            let screenH = NSScreen.main!.frame.height
            // Jendela mulai di bawah menu bar: geser agar wallpaper sejajar dengan layar penuh.
            let rect = NSRect(x: (bounds.width - size.width) / 2, y: (screenH - size.height) / 2, width: size.width, height: size.height)
            image.draw(in: rect)
            return
        }
        NSColor(srgbRed: 0x05 / 255, green: 0x06 / 255, blue: 0x09 / 255, alpha: 1).setFill()
        bounds.fill()
        let ctx = NSGraphicsContext.current!.cgContext
        let v = max(bounds.width, bounds.height) / 100
        let glows: [(CGFloat, CGFloat, CGFloat, NSColor)] = [
            (8 * v, bounds.height, 30 * v, NSColor(srgbRed: 0x1D / 255, green: 0x4E / 255, blue: 0xD8 / 255, alpha: 0.5)),
            (bounds.width, bounds.height - 18 * v, 30 * v, NSColor(srgbRed: 0x1E / 255, green: 0x40 / 255, blue: 0xAF / 255, alpha: 0.5)),
        ]
        for (x, y, r, color) in glows {
            let colors = [color.cgColor, color.withAlphaComponent(0).cgColor] as CFArray
            let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 1])!
            ctx.drawRadialGradient(gradient, startCenter: CGPoint(x: x, y: y), startRadius: 0,
                                   endCenter: CGPoint(x: x, y: y), endRadius: r * 1.6, options: [])
        }
    }
}

/// Ikon file seperti di desktop Finder: thumbnail + nama. Bisa diseret (drag-and-drop asli macOS).
final class FileTile: NSView, NSDraggingSource {
    let url: URL
    let image: NSImage
    let isPhoto: Bool
    private var downAt: NSPoint?
    static let size = NSSize(width: 170, height: 150)

    init(url: URL) {
        self.url = url
        isPhoto = ["jpg", "jpeg", "png", "heic"].contains(url.pathExtension.lowercased())
        image = isPhoto ? NSImage(contentsOf: url) ?? NSImage() : NSWorkspace.shared.icon(forFile: url.path)
        super.init(frame: NSRect(origin: .zero, size: Self.size))
    }

    required init?(coder: NSCoder) { fatalError() }

    var imageRect: NSRect { NSRect(x: 35, y: 44, width: 100, height: 100) }

    override func draw(_ dirtyRect: NSRect) {
        if isPhoto {
            // Foto dengan bingkai putih tipis (gaya thumbnail Finder).
            let photo = imageRect
            NSColor.white.setFill()
            NSBezierPath(roundedRect: photo.insetBy(dx: -3, dy: -3), xRadius: 6, yRadius: 6).fill()
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(roundedRect: photo, xRadius: 4, yRadius: 4).addClip()
            image.draw(in: photo)
            NSGraphicsContext.restoreGraphicsState()
        } else {
            image.draw(in: imageRect) // ikon dokumen asli dari Finder (mis. Excel/Numbers)
        }
        let label = url.lastPathComponent as NSString
        let shadow = NSShadow()  // seperti label ikon di desktop Finder: terbaca di atas wallpaper terang
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.6)
        shadow.shadowBlurRadius = 2
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12.5, weight: .medium), .foregroundColor: NSColor.white, .shadow: shadow,
        ]
        let size = label.size(withAttributes: attributes)
        label.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: 14), withAttributes: attributes)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { downAt = event.locationInWindow }

    override func mouseDragged(with event: NSEvent) {
        guard let start = downAt else { return }
        let p = event.locationInWindow
        guard hypot(p.x - start.x, p.y - start.y) > 3 else { return }
        downAt = nil
        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        item.setDraggingFrame(imageRect, contents: image)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }
}

/// Foto contoh: pemandangan senja sederhana (gradien langit, matahari, tiga lapis gunung).
func makePhoto(at url: URL) {
    let w = 1600, h = 1200
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    func c(_ hex: UInt32) -> CGColor {
        CGColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
    let sky = CGGradient(colorsSpace: nil, colors: [c(0x1E40AF), c(0x7C3AED), c(0xF97316), c(0xFBBF24)] as CFArray,
                         locations: [0, 0.45, 0.82, 1])!
    ctx.drawLinearGradient(sky, start: CGPoint(x: 0, y: CGFloat(h)), end: CGPoint(x: 0, y: CGFloat(h) * 0.3), options: [.drawsAfterEndLocation])
    ctx.setFillColor(c(0xFDE68A))
    ctx.fillEllipse(in: CGRect(x: 980, y: 430, width: 260, height: 260))
    let layers: [(UInt32, CGFloat, CGFloat)] = [(0x4C1D95, 520, 0.0), (0x312E81, 420, 1.7), (0x0F172A, 300, 3.1)]
    for (color, base, phase) in layers {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 0, y: 0))
        for x in stride(from: 0, through: w, by: 20) {
            let t = CGFloat(x) / CGFloat(w)
            let y = base + 90 * sin(t * 7 + phase) + 50 * sin(t * 17 + phase * 2)
            path.addLine(to: CGPoint(x: CGFloat(x), y: y))
        }
        path.addLine(to: CGPoint(x: CGFloat(w), y: 0))
        path.closeSubpath()
        ctx.addPath(path)
        ctx.setFillColor(c(color))
        ctx.fillPath()
    }
    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    try? rep.representation(using: .jpeg, properties: [.compressionFactor: 0.88])?.write(to: url)
}

// MARK: - Jalankan

var keepAlive: AnyObject?
if arguments.first == "--desktop", arguments.count >= 3 {
    let files = arguments.dropFirst(2).map { URL(fileURLWithPath: $0) }
    for file in files where file.pathExtension.lowercased() == "jpg" && !FileManager.default.fileExists(atPath: file.path) {
        makePhoto(at: file)
    }
    let wallpaper = Wallpaper(frame: NSRect(origin: .zero, size: frame.size))
    let primaryHeight = NSScreen.screens.first!.frame.height
    var centers: [String] = []
    for (i, file) in files.enumerated() {
        let tile = FileTile(url: file)
        // Kiri desktop, tersusun ke bawah, jauh dari tepi sisi HP (kanan).
        tile.frame.origin = NSPoint(x: frame.width * 0.2 - FileTile.size.width / 2,
                                    y: frame.height * 0.66 - CGFloat(i) * 190 - FileTile.size.height / 2)
        wallpaper.addSubview(tile)
        // Pusat ikon dalam koordinat layar CoreGraphics (origin kiri-atas layar utama).
        let x = frame.minX + tile.frame.minX + tile.imageRect.midX
        let y = primaryHeight - (frame.minY + tile.frame.minY + tile.imageRect.midY)
        centers.append("[\(Int(x)), \(Int(y))]")
    }
    window.contentView = wallpaper
    try? "{\"files\": [\(centers.joined(separator: ", "))]}".write(toFile: arguments[1], atomically: true, encoding: .utf8)
} else {
    let url = URL(string: arguments.first ?? "http://localhost:5317/")!
    let scroller = Scroller(anchor: url.fragment)
    keepAlive = scroller
    let web = WKWebView(frame: NSRect(origin: .zero, size: frame.size))
    web.autoresizingMask = [.width, .height]
    web.navigationDelegate = scroller
    web.load(URLRequest(url: url))
    window.contentView = web
}
window.orderFrontRegardless()
app.activate(ignoringOtherApps: true)
app.run()
