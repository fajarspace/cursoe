// Membuat ikon Mac dari logo Cursoe — tanpa dependency.
//   swift mac/make-icon.swift   (atau lewat ./mac/make-icon.sh)
//
//   Resources/AppIcon.icns   ikon aplikasi: kotak membulat blue-800 polos, simbol putih.
//   Resources/DiskIcon.icns  ikon disk DMG (volume & file .dmg): drive datar abu-abu muda dengan logo di depannya.
// Datar: tanpa gradasi, tanpa bayangan.
// Geometri: salinan BrandGeometry (dibuat scripts/brand/make-logo.py) — sama dengan app, website & Android.
import AppKit

// BEGIN GEOMETRY (make-logo.py)
/// Geometri logo Cursoe (kotak 64×64, sumbu y ke bawah): "C" + kursor yang menyatu di tengahnya.
/// Sama persis dengan website (logoGeometry.ts) dan ikon Android.
enum BrandGeometry {
    static let blue = (red: 0x1E, green: 0x40, blue: 0xAF)
    static let stroke: CGFloat = 5.4
    static let headRound: CGFloat = 1.2
    /// Pusat & jari-jari "C"; busur dari `startDegrees` memutar `sweepDegrees` berlawanan arah jarum jam
    /// (lewat atas & kiri) sampai ujung bawah.
    static let center = CGPoint(x: 33.93, y: 32.0)
    static let radius: CGFloat = 16.5
    static let startDegrees: CGFloat = -40.0
    static let sweepDegrees: CGFloat = 258.0
    static let stem = [CGPoint(x: 37.06, y: 36.11), CGPoint(x: 41.68, y: 46.57)]
    static let head = [CGPoint(x: 30.57, y: 21.94), CGPoint(x: 30.57, y: 43.7), CGPoint(x: 39.71, y: 35.42), CGPoint(x: 34.58, y: 37.17), CGPoint(x: 46.45, y: 37.17)]
    /// Batas bentuk (untuk memusatkan di ikon kecil): minX, minY, maxX, maxY.
    static let bounds = CGRect(x: 14.73, y: 12.8, width: 34.54, height: 38.4)

    static func ringPath() -> CGPath {
        let path = CGMutablePath()
        let steps = 180
        for i in 0...steps {
            let degrees = startDegrees - sweepDegrees * CGFloat(i) / CGFloat(steps)
            let a = degrees * .pi / 180
            let p = CGPoint(x: center.x + radius * cos(a), y: center.y + radius * sin(a))
            if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
        }
        return path
    }

    static func stemPath() -> CGPath {
        let path = CGMutablePath()
        path.addLines(between: stem)
        return path
    }

    static func headPath() -> CGPath {
        let path = CGMutablePath()
        path.addLines(between: head)
        path.closeSubpath()
        return path
    }

    /// Gambar simbol (tanpa latar) ke `ctx` berkoordinat 64×64, y ke bawah.
    static func draw(in ctx: CGContext, color: CGColor, weight: CGFloat = 1) {
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.setStrokeColor(color)
        ctx.setLineWidth(stroke * weight)
        ctx.addPath(ringPath())
        ctx.strokePath()
        ctx.addPath(stemPath())
        ctx.strokePath()
        ctx.setFillColor(color)
        ctx.addPath(headPath())
        ctx.fillPath()
        ctx.setLineWidth(headRound)
        ctx.addPath(headPath())
        ctx.strokePath()
    }
}
// END GEOMETRY

let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
let blue = CGColor(colorSpace: srgb, components: [CGFloat(BrandGeometry.blue.red) / 255, CGFloat(BrandGeometry.blue.green) / 255,
                                                  CGFloat(BrandGeometry.blue.blue) / 255, 1])!
let white = CGColor(colorSpace: srgb, components: [1, 1, 1, 1])!

/// Kanvas 1024×1024 (sumbu y ke bawah) diskalakan ke `px`.
func canvas(_ px: Int) -> CGContext {
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: srgb,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let s = CGFloat(px) / 1024
    ctx.translateBy(x: 0, y: CGFloat(px))
    ctx.scaleBy(x: s, y: -s)
    return ctx
}

/// Logo Cursoe (kotak blue-800 + simbol putih) di `rect` persegi.
func drawLogo(_ ctx: CGContext, in rect: CGRect) {
    ctx.saveGState()
    ctx.addPath(CGPath(roundedRect: rect, cornerWidth: rect.width * 15 / 64, cornerHeight: rect.width * 15 / 64, transform: nil))
    ctx.setFillColor(blue)
    ctx.fillPath()
    ctx.translateBy(x: rect.minX, y: rect.minY)
    ctx.scaleBy(x: rect.width / 64, y: rect.height / 64)
    BrandGeometry.draw(in: ctx, color: white)
    ctx.restoreGState()
}

func gray(_ hex: UInt32) -> CGColor {
    CGColor(colorSpace: srgb, components: [CGFloat(hex >> 16 & 0xFF) / 255, CGFloat(hex >> 8 & 0xFF) / 255, CGFloat(hex & 0xFF) / 255, 1])!
}

/// Ikon aplikasi. Kisi ikon macOS: badan 824 px di kanvas 1024, sudut ±185 px.
func renderApp(_ px: Int) -> CGImage {
    let ctx = canvas(px)
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    ctx.addPath(CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil))
    ctx.setFillColor(blue)
    ctx.fillPath()
    ctx.translateBy(x: body.minX, y: body.minY)
    ctx.scaleBy(x: body.width / 64, y: body.height / 64)
    BrandGeometry.draw(in: ctx, color: white)
    return ctx.makeImage()!
}

/// Ikon disk: drive tampak depan (zinc-100, tepi zinc-300), alas zinc-200 dengan lampu biru,
/// logo Cursoe di tengah bidang atas.
func renderDisk(_ px: Int) -> CGImage {
    let ctx = canvas(px)
    let body = CGRect(x: 132, y: 196, width: 760, height: 632)
    let shape = CGPath(roundedRect: body, cornerWidth: 104, cornerHeight: 104, transform: nil)
    ctx.addPath(shape)
    ctx.setFillColor(gray(0xF4F4F5))
    ctx.fillPath()
    // Alas drive (bagian bawah), dipotong mengikuti sudut badan
    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    ctx.setFillColor(gray(0xE4E4E7))
    ctx.fill(CGRect(x: body.minX, y: 700, width: body.width, height: body.maxY - 700))
    ctx.setFillColor(gray(0xD4D4D8))
    ctx.fill(CGRect(x: body.minX, y: 696, width: body.width, height: 8))
    ctx.restoreGState()
    // Tepi badan
    ctx.addPath(CGPath(roundedRect: body.insetBy(dx: 5, dy: 5), cornerWidth: 99, cornerHeight: 99, transform: nil))
    ctx.setStrokeColor(gray(0xD4D4D8))
    ctx.setLineWidth(10)
    ctx.strokePath()
    // Lampu
    ctx.setFillColor(blue)
    ctx.fillEllipse(in: CGRect(x: 790 - 17, y: 764 - 17, width: 34, height: 34))
    // Logo
    drawLogo(ctx, in: CGRect(x: 512 - 170, y: 446 - 170, width: 340, height: 340))
    return ctx.makeImage()!
}

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()

func writeIcns(_ name: String, _ render: (Int) -> CGImage) throws {
    let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("\(name).iconset")
    try? FileManager.default.removeItem(at: iconset)
    try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
    for (points, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
        let file = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
        let url = iconset.appendingPathComponent(file)
        let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, render(points * scale), nil)
        CGImageDestinationFinalize(dest)
    }
    let out = root.appendingPathComponent("Resources/\(name).icns")
    try FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    task.arguments = ["-c", "icns", iconset.path, "-o", out.path]
    try task.run()
    task.waitUntilExit()
    print(task.terminationStatus == 0 ? "✓ \(out.path)" : "iconutil gagal: \(name)")
}

try writeIcns("AppIcon", renderApp)
try writeIcns("DiskIcon", renderDisk)

// Pratinjau (opsional): swift mac/make-icon.swift --preview <folder> → disk-1024.png
if let i = CommandLine.arguments.firstIndex(of: "--preview"), i + 1 < CommandLine.arguments.count {
    let url = URL(fileURLWithPath: CommandLine.arguments[i + 1]).appendingPathComponent("disk-1024.png")
    let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, renderDisk(1024), nil)
    CGImageDestinationFinalize(dest)
    print("pratinjau: \(url.path)")
}
