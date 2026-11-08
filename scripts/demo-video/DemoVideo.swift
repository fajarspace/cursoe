// Video demo Cursoe: 1080×1080, 60 fps, H.264 — tanpa dependency (CoreGraphics + AVFoundation).
//
//   ./scripts/demo-video/render.sh                 → web/public/media/cursoe-demo.mp4 (+ .jpg)
//   DemoVideo --stills 0.5,3.4,6.6 <folder>        → PNG per waktu (cek cepat tanpa encode)
//   DemoVideo --poster 0 <file.jpg>                → gambar poster untuk website
//   DemoVideo --step 2 <file.mp4>                  → klip langkah "Cara kerja" 1200×900 (1 Pasang, 2 Pairing, 3 Pakai)
//   Tambahkan --light untuk versi terang.
//
// Alur: kursor di Mac (zoom in) → kamera mundur → kursor didorong ke tepi dan muncul di HP →
// zoom in ke HP → buka foto, pinch zoom, Esc, scroll dua jari → kursor kembali ke Mac → kartu penutup.
// Setiap frame = rata-rata beberapa sub-frame (motion blur, shutter 180°).

import AppKit
import AVFoundation
import CoreVideo

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

// MARK: - Konfigurasi

/// `--step 1|2|3`: klip pendek untuk bagian "Cara kerja" (1200×900, 6 detik, berulang; adegan dirancang di 800×600).
let STEP: Int? = {
    let a = CommandLine.arguments
    guard let i = a.firstIndex(of: "--step"), i + 1 < a.count else { return nil }
    return Int(a[i + 1])
}()
let W = STEP == nil ? 1080 : 1200
let H = STEP == nil ? 1080 : 900
let FPS = 60
let DURATION = STEP == nil ? 14.0 : 6.0
let SUBFRAMES = 4
let SHUTTER = 0.5 // fraksi interval frame yang "terekam"
let BITRATE = STEP == nil ? 6_000_000 : 4_000_000
let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

// MARK: - Warna (hitam · putih · blue-800), datar tanpa bayangan/gradien

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: srgb, components: [
        CGFloat((hex >> 16) & 0xFF) / 255, CGFloat((hex >> 8) & 0xFF) / 255, CGFloat(hex & 0xFF) / 255, a,
    ])!
}

func nsrgb(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor { NSColor(cgColor: rgb(hex, a))! }

/// `--light`: versi terang (latar putih, perangkat silver, layar terang, teks gelap).
let LIGHT = CommandLine.arguments.contains("--light")

let BLUE: UInt32 = 0x1E40AF      // blue-800 (warna merek)
let BLUE_800: UInt32 = BLUE
let BLUE_950: UInt32 = 0x172554
let BG: UInt32 = LIGHT ? 0xFFFFFF : 0x09090B          // latar & layar HP
let SURFACE: UInt32 = LIGHT ? 0xF4F4F5 : 0x18181B     // teks penjelas, chip
let WINDOW: UInt32 = LIGHT ? 0xFFFFFF : 0x18181B      // jendela di Mac
let DEVICE: UInt32 = LIGHT ? 0xE4E4E7 : 0x27272A      // bodi Mac & HP
let DEVICE_EDGE: UInt32 = LIGHT ? 0xD4D4D8 : 0x3F3F46
let MUTED: UInt32 = LIGHT ? 0x71717A : 0xA1A1AA
let INK: UInt32 = LIGHT ? 0x18181B : 0xFFFFFF         // teks utama
let LINE: UInt32 = LIGHT ? 0x000000 : 0xFFFFFF        // garis & titik (dengan alpha)
let ACCENT: UInt32 = LIGHT ? BLUE : 0xFFFFFF          // tepi menyala & riak di layar terang/gelap

let tileColors: [UInt32] = LIGHT
    ? [BLUE, 0xD4D4D8, BLUE_800, 0x71717A, 0xE4E4E7, BLUE_950, 0xA1A1AA, 0x52525B, BLUE]
    : [BLUE, 0xE4E4E7, BLUE_800, 0x3F3F46, 0xFAFAFA, BLUE_950, 0xD4D4D8, 0x52525B, BLUE]

// MARK: - Easing & interpolasi

func clamp(_ x: Double, _ a: Double = 0, _ b: Double = 1) -> Double { min(max(x, a), b) }
func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }
func lerp(_ a: CGPoint, _ b: CGPoint, _ t: Double) -> CGPoint {
    CGPoint(x: lerp(a.x, b.x, t), y: lerp(a.y, b.y, t))
}
func lerp(_ a: CGRect, _ b: CGRect, _ t: Double) -> CGRect {
    CGRect(x: lerp(a.minX, b.minX, t), y: lerp(a.minY, b.minY, t),
           width: lerp(a.width, b.width, t), height: lerp(a.height, b.height, t))
}
func easeInOut(_ t: Double) -> Double { t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2 }
func easeOut(_ t: Double) -> Double { 1 - pow(1 - t, 3) }
func easeIn(_ t: Double) -> Double { t * t }
func easeOutBack(_ t: Double) -> Double {
    let c1 = 1.70158, c3 = c1 + 1
    return 1 + c3 * pow(t - 1, 3) + c1 * pow(t - 1, 2)
}
/// Progres 0…1 di dalam jendela waktu [a, b].
func span(_ t: Double, _ a: Double, _ b: Double) -> Double { clamp((t - a) / (b - a)) }
/// Naik di [a, b], tahan, turun di [c, d].
func envelope(_ t: Double, _ a: Double, _ b: Double, _ c: Double, _ d: Double) -> Double {
    if t < a || t > d { return 0 }
    if t < b { return easeOut(span(t, a, b)) }
    if t > c { return 1 - easeIn(span(t, c, d)) }
    return 1
}
func quad(_ p0: CGPoint, _ c: CGPoint, _ p1: CGPoint, _ t: Double) -> CGPoint {
    let u = 1 - t
    return CGPoint(x: u * u * p0.x + 2 * u * t * c.x + t * t * p1.x,
                   y: u * u * p0.y + 2 * u * t * c.y + t * t * p1.y)
}

// MARK: - Geometri dunia (satuan = piksel saat zoom 1×)

let macScreen = CGRect(x: 70, y: 330, width: 620, height: 388)
let macBezel: CGFloat = 11
let macWindow = CGRect(x: macScreen.minX + 56, y: macScreen.minY + 52, width: 372, height: 246)
let phoneBody = CGRect(x: 790, y: 312, width: 204, height: 424)
let phoneScreen = phoneBody.insetBy(dx: 8, dy: 8)

// Galeri HP: 3 kolom, petak persegi.
let galleryTop = phoneScreen.minY + 84
let galleryPad: CGFloat = 12
let galleryGap: CGFloat = 7
let galleryTile = (phoneScreen.width - galleryPad * 2 - galleryGap * 2) / 3
let selectedTile = 4 // baris 2, kolom 2

func galleryRect(_ index: Int, scroll: CGFloat) -> CGRect {
    let col = CGFloat(index % 3), row = CGFloat(index / 3)
    return CGRect(x: phoneScreen.minX + galleryPad + col * (galleryTile + galleryGap),
                  y: galleryTop + row * (galleryTile + galleryGap) + scroll,
                  width: galleryTile, height: galleryTile)
}

let clickPoint = CGPoint(x: galleryRect(selectedTile, scroll: 0).midX, y: galleryRect(selectedTile, scroll: 0).midY)

/// Tinggi relatif yang sama di kedua layar saat kursor menyeberang.
func macToPhoneY(_ y: CGFloat) -> CGFloat { phoneScreen.minY + (y - macScreen.minY) / macScreen.height * phoneScreen.height }
func phoneToMacY(_ y: CGFloat) -> CGFloat { macScreen.minY + (y - phoneScreen.minY) / phoneScreen.height * macScreen.height }

// MARK: - Lintasan kursor

struct Segment {
    let t0: Double, t1: Double
    let from: CGPoint, control: CGPoint, to: CGPoint
    let ease: (Double) -> Double
}

let crossOut = 3.4  // Mac → HP
let crossBack = 11.0 // HP → Mac
let macExitY: CGFloat = 500
let phoneExitY: CGFloat = 455

let cursorPath: [Segment] = [
    Segment(t0: 0.2, t1: 1.5, from: CGPoint(x: 232, y: 612), control: CGPoint(x: 250, y: 470),
            to: CGPoint(x: 396, y: 456), ease: easeInOut),
    Segment(t0: 2.0, t1: crossOut, from: CGPoint(x: 396, y: 456), control: CGPoint(x: 560, y: 528),
            to: CGPoint(x: macScreen.maxX - 0.5, y: macExitY), ease: easeIn),
    Segment(t0: crossOut, t1: 3.8, from: CGPoint(x: phoneScreen.minX + 1, y: macToPhoneY(macExitY)),
            control: CGPoint(x: 826, y: macToPhoneY(macExitY) + 4), to: CGPoint(x: 844, y: 506), ease: easeOut),
    Segment(t0: 3.8, t1: 4.75, from: CGPoint(x: 844, y: 506), control: CGPoint(x: 872, y: 522),
            to: clickPoint, ease: easeInOut),
    Segment(t0: 9.7, t1: crossBack, from: clickPoint, control: CGPoint(x: 862, y: 430),
            to: CGPoint(x: phoneScreen.minX + 0.5, y: phoneExitY), ease: easeIn),
    Segment(t0: crossBack, t1: 11.55, from: CGPoint(x: macScreen.maxX - 1, y: phoneToMacY(phoneExitY)),
            control: CGPoint(x: 640, y: phoneToMacY(phoneExitY) + 6), to: CGPoint(x: 596, y: 474), ease: easeOut),
]

func cursorPosition(_ t: Double) -> CGPoint {
    var last = cursorPath[0].from
    for s in cursorPath {
        if t < s.t0 { return last }
        if t <= s.t1 { return quad(s.from, s.control, s.to, s.ease(span(t, s.t0, s.t1))) }
        last = s.to
    }
    return last
}

// MARK: - Kamera

struct Cam { let t: Double; let x: CGFloat; let y: CGFloat; let s: CGFloat }

let camKeys: [Cam] = [
    Cam(t: 0.0, x: 372, y: 476, s: 1.95),
    Cam(t: 1.7, x: 396, y: 480, s: 1.82),
    Cam(t: 3.15, x: 535, y: 528, s: 1.0),
    Cam(t: 3.95, x: 535, y: 528, s: 1.0),
    Cam(t: 4.95, x: 892, y: 524, s: 2.0),
    Cam(t: 5.7, x: 892, y: 518, s: 2.0),
    Cam(t: 6.6, x: 892, y: 500, s: 2.3),
    Cam(t: 7.5, x: 892, y: 518, s: 2.0),
    Cam(t: 9.65, x: 892, y: 524, s: 2.0),
    Cam(t: 10.6, x: 535, y: 528, s: 1.0),
    Cam(t: 11.6, x: 535, y: 528, s: 1.0),
    Cam(t: 14.0, x: 535, y: 528, s: 1.07),
]

func camera(_ t: Double) -> Cam {
    guard let i = camKeys.lastIndex(where: { $0.t <= t }) else { return camKeys[0] }
    if i == camKeys.count - 1 { return camKeys[i] }
    let a = camKeys[i], b = camKeys[i + 1]
    let p = easeInOut(span(t, a.t, b.t))
    // Skala diinterpolasi secara logaritmik supaya zoom terasa rata.
    let s = CGFloat(exp(lerp(Double(log(a.s)), Double(log(b.s)), p)))
    return Cam(t: t, x: lerp(a.x, b.x, p), y: lerp(a.y, b.y, p), s: s)
}

// MARK: - Gambar dasar

func rounded(_ r: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: r, cornerWidth: min(radius, r.width / 2), cornerHeight: min(radius, r.height / 2), transform: nil)
}

func fill(_ ctx: CGContext, _ path: CGPath, _ color: CGColor) {
    ctx.addPath(path)
    ctx.setFillColor(color)
    ctx.fillPath()
}

func gradient(_ ctx: CGContext, _ path: CGPath, _ colors: [CGColor], from: CGPoint, to: CGPoint,
              locations: [CGFloat]? = nil) {
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    let g = CGGradient(colorsSpace: srgb, colors: colors as CFArray, locations: locations)!
    ctx.drawLinearGradient(g, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    ctx.restoreGState()
}

func glow(_ ctx: CGContext, at c: CGPoint, radius: CGFloat, _ color: CGColor) {
    let clear = color.copy(alpha: 0)!
    let g = CGGradient(colorsSpace: srgb, colors: [color, clear] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(g, startCenter: c, startRadius: 0, endCenter: c, endRadius: radius, options: [])
}

enum Align { case left, center }

func text(_ s: String, _ p: CGPoint, size: CGFloat, weight: NSFont.Weight = .regular,
          color: NSColor = nsrgb(INK), align: Align = .left, alpha: CGFloat = 1, kern: CGFloat = 0) {
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: size, weight: weight),
        .foregroundColor: color.withAlphaComponent(color.alphaComponent * alpha),
        .kern: kern,
    ]
    let str = NSAttributedString(string: s, attributes: attrs)
    let w = str.size().width
    str.draw(at: CGPoint(x: align == .center ? p.x - w / 2 : p.x, y: p.y))
}

func textWidth(_ s: String, size: CGFloat, weight: NSFont.Weight) -> CGFloat {
    NSAttributedString(string: s, attributes: [.font: NSFont.systemFont(ofSize: size, weight: weight)]).size().width
}

/// Panah kursor macOS, ujung di `p`.
func drawCursor(_ ctx: CGContext, at p: CGPoint, scale s: CGFloat, alpha: CGFloat = 1) {
    let pts: [(CGFloat, CGFloat)] = [(0, 0), (0, 21), (5.2, 16.2), (8.6, 24.2), (12.0, 22.8), (8.7, 15.0), (15.4, 15.0)]
    let path = CGMutablePath()
    path.move(to: CGPoint(x: p.x + pts[0].0 * s, y: p.y + pts[0].1 * s))
    for pt in pts.dropFirst() { path.addLine(to: CGPoint(x: p.x + pt.0 * s, y: p.y + pt.1 * s)) }
    path.closeSubpath()
    ctx.saveGState()
    ctx.setAlpha(alpha)
    fill(ctx, path, rgb(0xFFFFFF))
    ctx.restoreGState()
    ctx.saveGState()
    ctx.setAlpha(alpha)
    ctx.addPath(path)
    ctx.setStrokeColor(rgb(0x0B0812))
    ctx.setLineWidth(1.3 * s)
    ctx.setLineJoin(.round)
    ctx.strokePath()
    ctx.restoreGState()
}

/// "Foto" abstrak datar: langit biru, matahari putih, pegunungan.
func drawPhoto(_ ctx: CGContext, _ r: CGRect) {
    ctx.saveGState()
    ctx.addRect(r)
    ctx.clip()
    fill(ctx, CGPath(rect: r, transform: nil), rgb(BLUE))
    let sun = CGPoint(x: r.minX + r.width * 0.66, y: r.minY + r.height * 0.4)
    fill(ctx, CGPath(ellipseIn: CGRect(x: sun.x - r.width * 0.09, y: sun.y - r.width * 0.09,
                                      width: r.width * 0.18, height: r.width * 0.18), transform: nil), rgb(0xFAFAFA))
    func mountain(_ peaks: [(CGFloat, CGFloat)], _ color: CGColor) {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: r.minX, y: r.maxY))
        for (fx, fy) in peaks { path.addLine(to: CGPoint(x: r.minX + fx * r.width, y: r.minY + fy * r.height)) }
        path.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
        path.closeSubpath()
        fill(ctx, path, color)
    }
    mountain([(0, 0.62), (0.22, 0.48), (0.4, 0.6), (0.58, 0.5), (0.8, 0.62), (1, 0.55)], rgb(BLUE_800))
    mountain([(0, 0.75), (0.18, 0.62), (0.36, 0.72), (0.62, 0.6), (0.85, 0.74), (1, 0.68)], rgb(BLUE_950))
    mountain([(0, 0.86), (0.3, 0.8), (0.55, 0.88), (0.8, 0.82), (1, 0.87)], rgb(0x09090B))
    ctx.restoreGState()
}

/// Logo Cursoe: kotak blue-800, simbol putih ("C" + kursor di tengahnya, sama dengan website/aplikasi).
/// Skala dari kotak 64×64 (konteks berkoordinat y ke bawah).
func drawLogo(_ ctx: CGContext, _ r: CGRect) {
    fill(ctx, rounded(r, r.width * 15 / 64), rgb(BLUE))
    ctx.saveGState()
    ctx.translateBy(x: r.minX, y: r.minY)
    ctx.scaleBy(x: r.width / 64, y: r.height / 64)
    BrandGeometry.draw(in: ctx, color: rgb(0xFFFFFF))
    ctx.restoreGState()
}

// MARK: - Mac

func drawMac(_ ctx: CGContext, t: Double, cursorOnMac: Bool, cursor: CGPoint) {
    let body = macScreen.insetBy(dx: -macBezel, dy: -macBezel)
    fill(ctx, rounded(body, 22), rgb(DEVICE))
    ctx.addPath(rounded(body, 22))
    ctx.setStrokeColor(rgb(DEVICE_EDGE))
    ctx.setLineWidth(1.2)
    ctx.strokePath()

    // Alas
    let base = CGMutablePath()
    let baseTop = body.maxY - 2
    base.move(to: CGPoint(x: body.minX - 30, y: baseTop))
    base.addLine(to: CGPoint(x: body.maxX + 30, y: baseTop))
    base.addLine(to: CGPoint(x: body.maxX + 22, y: baseTop + 15))
    base.addQuadCurve(to: CGPoint(x: body.maxX + 14, y: baseTop + 18), control: CGPoint(x: body.maxX + 20, y: baseTop + 18))
    base.addLine(to: CGPoint(x: body.minX - 14, y: baseTop + 18))
    base.addQuadCurve(to: CGPoint(x: body.minX - 22, y: baseTop + 15), control: CGPoint(x: body.minX - 20, y: baseTop + 18))
    base.closeSubpath()
    fill(ctx, base, rgb(DEVICE_EDGE))
    fill(ctx, rounded(CGRect(x: body.midX - 40, y: baseTop, width: 80, height: 6), 3), rgb(DEVICE))

    // Layar
    ctx.saveGState()
    ctx.addPath(rounded(macScreen, 9))
    ctx.clip()
    fill(ctx, CGPath(rect: macScreen, transform: nil), rgb(BLUE))

    // Bar menu
    fill(ctx, CGPath(rect: CGRect(x: macScreen.minX, y: macScreen.minY, width: macScreen.width, height: 18), transform: nil),
         rgb(0x000000, 0.28))
    for (i, w) in [CGFloat(26), 18, 22].enumerated() {
        let x = macScreen.minX + 12 + CGFloat(i) * 34
        fill(ctx, rounded(CGRect(x: x, y: macScreen.minY + 6, width: w, height: 6), 3), rgb(0xFFFFFF, i == 0 ? 0.8 : 0.5))
    }
    fill(ctx, rounded(CGRect(x: macScreen.maxX - 66, y: macScreen.minY + 4, width: 10, height: 10), 3), rgb(0xFFFFFF))
    fill(ctx, rounded(CGRect(x: macScreen.maxX - 48, y: macScreen.minY + 6, width: 34, height: 6), 3), rgb(0xFFFFFF, 0.7))

    // Jendela "Proyek"
    fill(ctx, rounded(macWindow, 12), rgb(WINDOW))
    ctx.saveGState()
    ctx.addPath(rounded(macWindow, 12))
    ctx.clip()
    fill(ctx, CGPath(rect: CGRect(x: macWindow.minX, y: macWindow.minY + 30, width: 92, height: macWindow.height),
                     transform: nil), rgb(LINE, 0.035))
    ctx.restoreGState()
    for (i, c) in [UInt32(0xFF5F57), 0xFEBC2E, 0x28C840].enumerated() {
        fill(ctx, CGPath(ellipseIn: CGRect(x: macWindow.minX + 13 + CGFloat(i) * 14, y: macWindow.minY + 10,
                                          width: 9, height: 9), transform: nil), rgb(c))
    }
    text("Proyek", CGPoint(x: macWindow.minX + 62, y: macWindow.minY + 6), size: 12, weight: .medium,
         color: nsrgb(MUTED))
    fill(ctx, CGPath(rect: CGRect(x: macWindow.minX, y: macWindow.minY + 30, width: macWindow.width, height: 0.8),
                     transform: nil), rgb(LINE, 0.08))
    for (i, w) in [CGFloat(58), 44, 52, 40].enumerated() {
        fill(ctx, rounded(CGRect(x: macWindow.minX + 14, y: macWindow.minY + 48 + CGFloat(i) * 16, width: w, height: 6), 3),
             rgb(LINE, 0.16))
    }
    let gridX = macWindow.minX + 108, gridY = macWindow.minY + 46
    let tw: CGFloat = 76, th: CGFloat = 84, gap: CGFloat = 12
    for i in 0..<6 {
        let r = CGRect(x: gridX + CGFloat(i % 3) * (tw + gap), y: gridY + CGFloat(i / 3) * (th + gap), width: tw, height: th)
        let hover = cursorOnMac && r.insetBy(dx: -4, dy: -4).contains(cursor)
        fill(ctx, rounded(r, 8), rgb(tileColors[(i * 2) % tileColors.count]))
        if hover {
            ctx.addPath(rounded(r.insetBy(dx: -2, dy: -2), 9))
            ctx.setStrokeColor(LIGHT ? rgb(BLUE) : rgb(0xFFFFFF, 0.85))
            ctx.setLineWidth(2)
            ctx.strokePath()
        }
    }

    // Dock
    let dock = CGRect(x: macScreen.midX - 118, y: macScreen.maxY - 46, width: 236, height: 38)
    fill(ctx, rounded(dock, 12), rgb(0xFFFFFF, 0.14))
    for i in 0..<6 {
        let r = CGRect(x: dock.minX + 12 + CGFloat(i) * 37, y: dock.minY + 7, width: 25, height: 25)
        fill(ctx, rounded(r, 7), rgb(tileColors[(i * 3 + 1) % tileColors.count]))
    }

    // Tepi kanan menyala saat kursor menyeberang
    let edge = max(envelope(t, 3.2, crossOut, crossOut + 0.1, 3.9), envelope(t, crossBack - 0.05, crossBack, crossBack + 0.1, 11.6))
    if edge > 0 {
        let r = CGRect(x: macScreen.maxX - 4, y: macScreen.minY + 20, width: 4, height: macScreen.height - 40)
        fill(ctx, CGPath(rect: r, transform: nil), rgb(0xFFFFFF, 0.9 * edge))
    }
    ctx.restoreGState()
}

// MARK: - HP

func drawPhone(_ ctx: CGContext, t: Double) {
    fill(ctx, rounded(phoneBody, 32), rgb(DEVICE))
    ctx.addPath(rounded(phoneBody, 32))
    ctx.setStrokeColor(rgb(DEVICE_EDGE))
    ctx.setLineWidth(1.2)
    ctx.strokePath()
    fill(ctx, rounded(CGRect(x: phoneBody.maxX, y: phoneBody.minY + 90, width: 3, height: 44), 1.5), rgb(DEVICE_EDGE))
    fill(ctx, rounded(CGRect(x: phoneBody.maxX, y: phoneBody.minY + 146, width: 3, height: 26), 1.5), rgb(DEVICE_EDGE))

    ctx.saveGState()
    ctx.addPath(rounded(phoneScreen, 25))
    ctx.clip()
    fill(ctx, CGPath(rect: phoneScreen, transform: nil), rgb(BG))

    // Status bar, kamera, judul
    text("9:41", CGPoint(x: phoneScreen.minX + 20, y: phoneScreen.minY + 10), size: 11, weight: .semibold)
    fill(ctx, CGPath(ellipseIn: CGRect(x: phoneScreen.midX - 4, y: phoneScreen.minY + 12, width: 8, height: 8),
                     transform: nil), rgb(0x000000))
    fill(ctx, rounded(CGRect(x: phoneScreen.maxX - 44, y: phoneScreen.minY + 15, width: 14, height: 6), 3), rgb(INK, 0.6))
    fill(ctx, rounded(CGRect(x: phoneScreen.maxX - 27, y: phoneScreen.minY + 15, width: 14, height: 6), 3), rgb(INK, 0.85))
    text("Galeri", CGPoint(x: phoneScreen.minX + 14, y: phoneScreen.minY + 40), size: 22, weight: .bold)

    // Galeri (bisa di-scroll)
    let scroll = -CGFloat(easeOut(span(t, 8.5, 9.6))) * (galleryTile + galleryGap) * 2
    let press = envelope(t, 4.96, 5.02, 5.06, 5.16)
    ctx.saveGState()
    ctx.addRect(CGRect(x: phoneScreen.minX, y: galleryTop - 4, width: phoneScreen.width, height: phoneScreen.maxY - galleryTop + 4))
    ctx.clip()
    for i in 0..<21 {
        var r = galleryRect(i, scroll: scroll)
        if r.maxY < galleryTop - 10 || r.minY > phoneScreen.maxY { continue }
        if i == selectedTile {
            r = r.insetBy(dx: r.width * 0.04 * press, dy: r.height * 0.04 * press)
            ctx.saveGState()
            ctx.addPath(rounded(r, 7))
            ctx.clip()
            drawPhoto(ctx, r)
            ctx.restoreGState()
        } else {
            fill(ctx, rounded(r, 7), rgb(tileColors[(i * 5 + 2) % tileColors.count]))
        }
    }
    ctx.restoreGState()

    // Foto dibuka (5,10–5,55) lalu ditutup dengan Esc (7,85–8,25), pinch zoom di antaranya.
    let open = t < 7.85 ? easeOut(span(t, 5.1, 5.55)) : 1 - easeInOut(span(t, 7.85, 8.25))
    if open > 0 {
        let from = galleryRect(selectedTile, scroll: 0)
        let viewer = CGRect(x: phoneScreen.minX, y: phoneScreen.midY - phoneScreen.width * 0.62,
                            width: phoneScreen.width, height: phoneScreen.width * 1.24)
        fill(ctx, CGPath(rect: phoneScreen, transform: nil), rgb(BG, 0.94 * open))
        let r = lerp(from, viewer, open)
        let zoom = 1 + 1.2 * (t < 6.95 ? easeInOut(span(t, 5.9, 6.6)) : 1 - easeInOut(span(t, 6.95, 7.55)))
        ctx.saveGState()
        ctx.addPath(rounded(r, 7 * (1 - open)))
        ctx.clip()
        ctx.translateBy(x: clickPoint.x, y: clickPoint.y)
        ctx.scaleBy(x: zoom, y: zoom)
        ctx.translateBy(x: -clickPoint.x, y: -clickPoint.y)
        drawPhoto(ctx, r)
        ctx.restoreGState()
    }

    // Tepi kiri menyala saat kursor masuk/keluar
    let edge = max(envelope(t, crossOut - 0.05, crossOut, crossOut + 0.1, 3.95), envelope(t, 10.8, crossBack, crossBack + 0.05, 11.4))
    if edge > 0 {
        let r = CGRect(x: phoneScreen.minX, y: phoneScreen.minY + 30, width: 4, height: phoneScreen.height - 60)
        fill(ctx, CGPath(rect: r, transform: nil), rgb(ACCENT, 0.9 * edge))
    }
    ctx.restoreGState()
}

// MARK: - Overlay dunia: chip latensi, riak klik, titik jari

func drawWorldOverlays(_ ctx: CGContext, t: Double) {
    // Chip latensi di atas celah Mac–HP
    let chip = envelope(t, 3.45, 3.75, 4.6, 4.9)
    if chip > 0 {
        let s = CGFloat(easeOutBack(span(t, 3.45, 3.8)))
        let label = "7 ms · kabel USB"
        let w = textWidth(label, size: 15, weight: .semibold) + 46
        let c = CGPoint(x: 740, y: 284)
        ctx.saveGState()
        ctx.setAlpha(chip)
        ctx.translateBy(x: c.x, y: c.y)
        ctx.scaleBy(x: max(s, 0.01), y: max(s, 0.01))
        let r = CGRect(x: -w / 2, y: -17, width: w, height: 34)
        fill(ctx, rounded(r, 17), rgb(SURFACE))
        ctx.addPath(rounded(r, 17))
        ctx.setStrokeColor(rgb(LINE, 0.12))
        ctx.setLineWidth(1)
        ctx.strokePath()
        fill(ctx, CGPath(ellipseIn: CGRect(x: r.minX + 15, y: -4, width: 8, height: 8), transform: nil), rgb(ACCENT))
        text(label, CGPoint(x: r.minX + 30, y: -10), size: 15, weight: .semibold)
        ctx.restoreGState()
    }

    // Riak saat klik
    let ripple = span(t, 5.0, 5.4)
    if ripple > 0 && ripple < 1 {
        let rad = CGFloat(6 + 26 * easeOut(ripple))
        ctx.addPath(CGPath(ellipseIn: CGRect(x: clickPoint.x - rad, y: clickPoint.y - rad, width: rad * 2, height: rad * 2), transform: nil))
        ctx.setStrokeColor(rgb(ACCENT, CGFloat(0.85 * (1 - ripple))))
        ctx.setLineWidth(2.2)
        ctx.strokePath()
    }

    // Dua jari: pinch (menjauh lalu mendekat) dan scroll (naik bersama)
    let pinchAlpha = envelope(t, 5.8, 5.95, 7.5, 7.7)
    if pinchAlpha > 0 {
        let spread = 12 + 22 * (t < 6.95 ? easeInOut(span(t, 5.9, 6.6)) : 1 - easeInOut(span(t, 6.95, 7.55)))
        for sign in [-1.0, 1.0] {
            let p = CGPoint(x: clickPoint.x + sign * spread, y: clickPoint.y + 36 + sign * spread * 0.55)
            fill(ctx, CGPath(ellipseIn: CGRect(x: p.x - 9, y: p.y - 9, width: 18, height: 18), transform: nil),
                 rgb(LINE, (LIGHT ? 0.28 : 0.42) * pinchAlpha))
        }
    }
    let scrollAlpha = envelope(t, 8.4, 8.55, 9.15, 9.35)
    if scrollAlpha > 0 {
        let dy = -70 * easeOut(span(t, 8.5, 9.2))
        for dx in [-11.0, 11.0] {
            let p = CGPoint(x: clickPoint.x + dx, y: clickPoint.y + 60 + dy)
            fill(ctx, CGPath(ellipseIn: CGRect(x: p.x - 9, y: p.y - 9, width: 18, height: 18), transform: nil),
                 rgb(LINE, (LIGHT ? 0.28 : 0.42) * scrollAlpha))
        }
    }
}

// MARK: - Overlay layar: merek, teks penjelas, kartu penutup

struct Caption { let t0: Double; let t1: Double; let text: String }

let captions: [Caption] = [
    Caption(t0: 0.35, t1: 2.0, text: "Kursor Mac, seperti biasa"),
    Caption(t0: 2.15, t1: 3.55, text: "Dorong ke tepi layar…"),
    Caption(t0: 3.65, t1: 5.75, text: "…langsung lanjut di HP"),
    Caption(t0: 5.85, t1: 7.7, text: "Pinch untuk zoom"),
    Caption(t0: 7.8, t1: 8.4, text: "Esc = Back"),
    Caption(t0: 8.45, t1: 9.65, text: "Scroll dua jari"),
    Caption(t0: 9.75, t1: 11.55, text: "Dorong balik ke Mac"),
]

func drawScreenOverlays(_ ctx: CGContext, t: Double) {
    // Merek di kiri atas
    let brand = envelope(t, 0.1, 0.6, 11.3, 11.7)
    if brand > 0 {
        ctx.saveGState()
        ctx.setAlpha(brand)
        drawLogo(ctx, CGRect(x: 48, y: 44, width: 46, height: 46))
        text("Cursoe", CGPoint(x: 108, y: 51), size: 27, weight: .semibold)
        ctx.restoreGState()
    }

    // Teks penjelas di bawah tengah
    for c in captions {
        let a = envelope(t, c.t0, c.t0 + 0.22, c.t1 - 0.2, c.t1)
        if a <= 0 { continue }
        let rise = CGFloat(14 * (1 - easeOut(span(t, c.t0, c.t0 + 0.3))))
        let size: CGFloat = 32
        let w = textWidth(c.text, size: size, weight: .semibold) + 64
        let r = CGRect(x: CGFloat(W) / 2 - w / 2, y: 984 + rise, width: w, height: 62)
        ctx.saveGState()
        ctx.setAlpha(a)
        fill(ctx, rounded(r, 31), rgb(SURFACE))
        ctx.addPath(rounded(r, 31))
        ctx.setStrokeColor(rgb(LINE, 0.12))
        ctx.setLineWidth(1)
        ctx.strokePath()
        text(c.text, CGPoint(x: r.midX, y: r.minY + 11), size: size, weight: .semibold, align: .center)
        ctx.restoreGState()
    }

    // Kartu penutup
    let dim = easeInOut(span(t, 11.7, 12.3))
    if dim > 0 {
        fill(ctx, CGPath(rect: CGRect(x: 0, y: 0, width: W, height: H), transform: nil), rgb(BG, 0.92 * dim))

        let logo = span(t, 11.9, 12.45)
        if logo > 0 {
            let s = CGFloat(easeOutBack(logo))
            let size: CGFloat = 132 * s
            ctx.saveGState()
            ctx.setAlpha(CGFloat(min(1, logo * 2)))
            drawLogo(ctx, CGRect(x: 540 - size / 2, y: 372 - size / 2, width: size, height: size))
            ctx.restoreGState()
        }
        func line(_ s: String, y: CGFloat, size: CGFloat, weight: NSFont.Weight, color: NSColor, start: Double) {
            let p = easeOut(span(t, start, start + 0.5))
            if p <= 0 { return }
            text(s, CGPoint(x: 540, y: y + CGFloat(18 * (1 - p))), size: size, weight: weight, color: color,
                 align: .center, alpha: CGFloat(p), kern: -0.5)
        }
        line("Cursoe", y: 476, size: 78, weight: .bold, color: nsrgb(INK), start: 12.1)
        line("Satu kursor. Dua layar.", y: 578, size: 40, weight: .semibold, color: nsrgb(LIGHT ? 0x3F3F46 : 0xD4D4D8), start: 12.3)
        line("Mac ⇄ HP & tablet Android · Gratis", y: 650, size: 26, weight: .regular, color: nsrgb(0x71717A), start: 12.5)
    }
}

// MARK: - Satu adegan pada waktu t

func renderScene(_ ctx: CGContext, t: Double) {
    // Latar (ruang layar)
    fill(ctx, CGPath(rect: CGRect(x: 0, y: 0, width: W, height: H), transform: nil), rgb(BG))

    let cam = camera(t)
    ctx.saveGState()
    ctx.translateBy(x: CGFloat(W) / 2, y: CGFloat(H) / 2)
    ctx.scaleBy(x: cam.s, y: cam.s)
    ctx.translateBy(x: -cam.x, y: -cam.y)

    let cursor = cursorPosition(t)
    let onMac = t < crossOut || t >= crossBack
    drawMac(ctx, t: t, cursorOnMac: onMac, cursor: cursor)
    drawPhone(ctx, t: t)
    drawWorldOverlays(ctx, t: t)

    // Kursor (diklip ke layar tempat ia berada)
    let fade = 1 - easeInOut(span(t, 12.0, 12.4))
    if fade > 0 {
        ctx.saveGState()
        ctx.addPath(rounded(onMac ? macScreen : phoneScreen, onMac ? 9 : 25))
        ctx.clip()
        drawCursor(ctx, at: cursor, scale: 1.15, alpha: CGFloat(fade))
        ctx.restoreGState()
    }
    ctx.restoreGState()

    drawScreenOverlays(ctx, t: t)
}

// MARK: - Klip langkah "Cara kerja" (800×600)

func strokePath(_ ctx: CGContext, _ path: CGPath, _ color: CGColor, width: CGFloat) {
    ctx.addPath(path)
    ctx.setStrokeColor(color)
    ctx.setLineWidth(width)
    ctx.strokePath()
}

/// Jendela macOS datar. @return area isi di bawah bar judul.
func drawWindow(_ ctx: CGContext, _ r: CGRect, title: String) -> CGRect {
    fill(ctx, rounded(r, 14), rgb(WINDOW))
    strokePath(ctx, rounded(r, 14), rgb(LINE, 0.14), width: 1.5)
    for (i, c) in [UInt32(0xFF5F57), 0xFEBC2E, 0x28C840].enumerated() {
        fill(ctx, CGPath(ellipseIn: CGRect(x: r.minX + 16 + CGFloat(i) * 18, y: r.minY + 15, width: 11, height: 11),
                         transform: nil), rgb(c))
    }
    text(title, CGPoint(x: r.midX, y: r.minY + 11), size: 14, weight: .semibold, color: nsrgb(MUTED), align: .center)
    fill(ctx, CGPath(rect: CGRect(x: r.minX, y: r.minY + 40, width: r.width, height: 1), transform: nil), rgb(LINE, 0.1))
    return CGRect(x: r.minX, y: r.minY + 41, width: r.width, height: r.height - 41)
}

/// Bodi HP datar. @return area layar.
func drawPhoneFrame(_ ctx: CGContext, _ body: CGRect) -> CGRect {
    fill(ctx, rounded(body, 30), rgb(DEVICE))
    strokePath(ctx, rounded(body, 30), rgb(DEVICE_EDGE), width: 1.5)
    let screen = body.insetBy(dx: 8, dy: 8)
    fill(ctx, rounded(screen, 23), rgb(BG))
    fill(ctx, CGPath(ellipseIn: CGRect(x: screen.midX - 4, y: screen.minY + 10, width: 8, height: 8), transform: nil),
         rgb(LIGHT ? 0x18181B : 0x3F3F46))
    return screen
}

func drawCheck(_ ctx: CGContext, center c: CGPoint, radius r: CGFloat, progress p: Double) {
    guard p > 0 else { return }
    let s = r * CGFloat(easeOutBack(min(1, p)))
    fill(ctx, CGPath(ellipseIn: CGRect(x: c.x - s, y: c.y - s, width: 2 * s, height: 2 * s), transform: nil), rgb(BLUE))
    let path = CGMutablePath()
    path.move(to: CGPoint(x: c.x - s * 0.42, y: c.y + s * 0.02))
    path.addLine(to: CGPoint(x: c.x - s * 0.1, y: c.y + s * 0.34))
    path.addLine(to: CGPoint(x: c.x + s * 0.45, y: c.y - s * 0.3))
    ctx.saveGState()
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    strokePath(ctx, path, rgb(0xFFFFFF), width: s * 0.2)
    ctx.restoreGState()
}

func drawFolder(_ ctx: CGContext, _ r: CGRect, highlight: Double) {
    fill(ctx, rounded(CGRect(x: r.minX, y: r.minY, width: r.width * 0.42, height: r.height * 0.3), 6), rgb(BLUE))
    fill(ctx, rounded(CGRect(x: r.minX, y: r.minY + r.height * 0.14, width: r.width, height: r.height * 0.86), 9), rgb(BLUE_800))
    if highlight > 0 {
        strokePath(ctx, rounded(r.insetBy(dx: -8, dy: -8), 14), rgb(ACCENT, 0.8 * highlight), width: 2.5)
    }
}

func ripple(_ ctx: CGContext, at c: CGPoint, progress p: Double, color: UInt32 = ACCENT) {
    guard p > 0 && p < 1 else { return }
    let r = CGFloat(6 + 26 * easeOut(p))
    strokePath(ctx, CGPath(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r), transform: nil),
               rgb(color, CGFloat(0.85 * (1 - p))), width: 2.2)
}

func position(_ segs: [Segment], _ t: Double) -> CGPoint {
    var last = segs[0].from
    for s in segs {
        if t < s.t0 { return last }
        if t <= s.t1 { return quad(s.from, s.control, s.to, s.ease(span(t, s.t0, s.t1))) }
        last = s.to
    }
    return last
}

/// Langkah 1 — Pasang: seret app ke Applications di Mac, lalu pasang APK di HP.
func renderStepInstall(_ ctx: CGContext, t: Double) {
    let win = CGRect(x: 40, y: 150, width: 450, height: 300)
    let content = drawWindow(ctx, win, title: "Cursoe")
    let appC = CGPoint(x: content.minX + 115, y: content.midY - 16)
    let folderC = CGPoint(x: content.maxX - 115, y: content.midY - 16)
    text("→", CGPoint(x: content.midX, y: appC.y - 24), size: 38, weight: .light, color: nsrgb(MUTED), align: .center)

    let folderRect = CGRect(x: folderC.x - 48, y: folderC.y - 40, width: 96, height: 80)
    drawFolder(ctx, folderRect, highlight: envelope(t, 2.05, 2.25, 2.55, 2.85))
    text("Applications", CGPoint(x: folderC.x, y: folderC.y + 56), size: 14, weight: .medium, align: .center)

    let grab = CGPoint(x: 10, y: 8) // ujung kursor relatif terhadap pusat ikon
    let segs = [
        Segment(t0: 0.35, t1: 1.15, from: CGPoint(x: 200, y: 540), control: CGPoint(x: 150, y: 420),
                to: CGPoint(x: appC.x + grab.x, y: appC.y + grab.y), ease: easeInOut),
        Segment(t0: 1.35, t1: 2.35, from: CGPoint(x: appC.x + grab.x, y: appC.y + grab.y),
                control: CGPoint(x: content.midX, y: appC.y - 70),
                to: CGPoint(x: folderC.x + grab.x, y: folderC.y + grab.y), ease: easeInOut),
        Segment(t0: 2.9, t1: 3.6, from: CGPoint(x: folderC.x + grab.x, y: folderC.y + grab.y),
                control: CGPoint(x: 470, y: 380), to: CGPoint(x: 520, y: 470), ease: easeInOut),
    ]
    let cursor = position(segs, t)
    let dragging = t >= 1.3 && t < 2.7
    let moved = t >= 1.3
    let press = 1 - 0.06 * CGFloat(envelope(t, 1.12, 1.22, 1.28, 1.36))
    let iconSize: CGFloat = 88 * press
    ctx.saveGState()
    ctx.setAlpha(moved ? 0.3 : 1)
    drawLogo(ctx, CGRect(x: appC.x - iconSize / 2, y: appC.y - iconSize / 2, width: iconSize, height: iconSize))
    ctx.restoreGState()
    text("Cursoe", CGPoint(x: appC.x, y: appC.y + 56), size: 14, weight: .medium, align: .center)

    if dragging {
        // Ikon ikut kursor, lalu mengecil masuk ke folder.
        let drop = easeIn(span(t, 2.35, 2.7))
        let center = lerp(CGPoint(x: cursor.x - grab.x, y: cursor.y - grab.y), folderC, drop)
        let size = 88 * CGFloat(1 - 0.75 * drop)
        ctx.saveGState()
        ctx.setAlpha(CGFloat(0.92 * (1 - drop * 0.6)))
        drawLogo(ctx, CGRect(x: center.x - size / 2, y: center.y - size / 2, width: size, height: size))
        ctx.restoreGState()
    }
    drawCheck(ctx, center: CGPoint(x: folderRect.maxX, y: folderRect.minY), radius: 15, progress: span(t, 2.7, 3.0))
    let cursorAlpha = CGFloat(1 - span(t, 3.45, 3.75))
    if cursorAlpha > 0 { drawCursor(ctx, at: cursor, scale: 1.25, alpha: cursorAlpha) }

    // HP: penginstal APK
    let screen = drawPhoneFrame(ctx, CGRect(x: 560, y: 100, width: 200, height: 400))
    drawLogo(ctx, CGRect(x: screen.midX - 32, y: screen.minY + 74, width: 64, height: 64))
    text("Cursoe", CGPoint(x: screen.midX, y: screen.minY + 150), size: 17, weight: .semibold, align: .center)
    text("APK · 713 KB", CGPoint(x: screen.midX, y: screen.minY + 174), size: 12, color: nsrgb(MUTED), align: .center)
    let button = CGRect(x: screen.minX + 20, y: screen.maxY - 92, width: screen.width - 40, height: 42)
    if t < 3.8 {
        let pressed = CGFloat(envelope(t, 3.55, 3.62, 3.68, 3.78))
        let r = button.insetBy(dx: button.width * 0.03 * pressed, dy: button.height * 0.05 * pressed)
        fill(ctx, rounded(r, 10), rgb(BLUE))
        text("Pasang", CGPoint(x: r.midX, y: r.midY - 10), size: 15, weight: .semibold, color: .white, align: .center)
        ripple(ctx, at: CGPoint(x: button.midX, y: button.midY), progress: span(t, 3.6, 3.95), color: LINE)
    } else if t < 4.85 {
        let p = CGFloat(easeInOut(span(t, 3.85, 4.8)))
        text("Memasang…", CGPoint(x: screen.midX, y: button.minY - 6), size: 13, color: nsrgb(MUTED), align: .center)
        let track = CGRect(x: button.minX, y: button.midY + 6, width: button.width, height: 8)
        fill(ctx, rounded(track, 4), rgb(LINE, 0.12))
        fill(ctx, rounded(CGRect(x: track.minX, y: track.minY, width: max(8, track.width * p), height: 8), 4), rgb(BLUE))
    } else {
        drawCheck(ctx, center: CGPoint(x: screen.midX, y: button.midY - 14), radius: 22, progress: span(t, 4.85, 5.15))
        let a = CGFloat(easeOut(span(t, 5.0, 5.3)))
        text("Terpasang", CGPoint(x: screen.midX, y: button.midY + 14), size: 14, weight: .semibold, align: .center, alpha: a)
    }
}

/// Langkah 2 — Pairing: PIN tampil di HP, diketik di Mac, lalu tersambung.
func renderStepPair(_ ctx: CGContext, t: Double) {
    let pin = Array("482913")
    let typedAt = (0..<6).map { 1.0 + Double($0) * 0.36 }
    let done = 3.4, linked = 3.95

    // HP
    let body = CGRect(x: 560, y: 100, width: 200, height: 400)
    let screen = drawPhoneFrame(ctx, body)
    let pinAlpha = CGFloat(easeOut(span(t, 0.2, 0.6)) * (1 - easeIn(span(t, linked, linked + 0.3))))
    if pinAlpha > 0 {
        text("PIN pairing", CGPoint(x: screen.midX, y: screen.minY + 128), size: 13, weight: .semibold,
             color: nsrgb(MUTED), align: .center, alpha: pinAlpha)
        text("482 913", CGPoint(x: screen.midX, y: screen.minY + 152), size: 34, weight: .bold, align: .center,
             alpha: pinAlpha, kern: 1)
        text("Ketik di Mac", CGPoint(x: screen.midX, y: screen.minY + 204), size: 13, color: nsrgb(MUTED),
             align: .center, alpha: pinAlpha)
    }
    drawCheck(ctx, center: CGPoint(x: screen.midX, y: screen.minY + 170), radius: 30, progress: span(t, linked + 0.25, linked + 0.6))
    text("Terhubung", CGPoint(x: screen.midX, y: screen.minY + 214), size: 15, weight: .semibold, align: .center,
         alpha: CGFloat(easeOut(span(t, linked + 0.45, linked + 0.75))))

    // Mac: dialog PIN
    let win = CGRect(x: 40, y: 160, width: 450, height: 280)
    let content = drawWindow(ctx, win, title: "Pairing")
    text("Masukkan PIN dari HP", CGPoint(x: content.midX, y: content.minY + 26), size: 18, weight: .semibold, align: .center)
    let boxW: CGFloat = 46, boxH: CGFloat = 58, gap: CGFloat = 10
    let startX = content.midX - (6 * boxW + 5 * gap) / 2
    let typed = typedAt.filter { t >= $0 }.count
    for i in 0..<6 {
        let r = CGRect(x: startX + CGFloat(i) * (boxW + gap), y: content.minY + 74, width: boxW, height: boxH)
        fill(ctx, rounded(r, 10), rgb(LINE, 0.05))
        let active = (i == typed && t < done) || t >= done
        strokePath(ctx, rounded(r, 10), active ? rgb(LIGHT ? BLUE : 0x3B82F6) : rgb(LINE, 0.16), width: active ? 2 : 1.2)
        if i < typed {
            let pop = CGFloat(easeOutBack(span(t, typedAt[i], typedAt[i] + 0.2)))
            ctx.saveGState()
            ctx.translateBy(x: r.midX, y: r.midY)
            ctx.scaleBy(x: max(pop, 0.01), y: max(pop, 0.01))
            text(String(pin[i]), CGPoint(x: 0, y: -17), size: 28, weight: .semibold, align: .center)
            ctx.restoreGState()
        }
    }
    let status = CGFloat(easeOut(span(t, linked + 0.3, linked + 0.6)))
    if status > 0 {
        drawCheck(ctx, center: CGPoint(x: content.midX - 52, y: content.minY + 180), radius: 11, progress: span(t, linked + 0.3, linked + 0.55))
        text("Terhubung", CGPoint(x: content.midX - 34, y: content.minY + 170), size: 16, weight: .semibold, alpha: status)
    }

    // Garis koneksi Mac ↔ HP
    let grow = easeOut(span(t, done + 0.1, linked))
    if grow > 0 {
        let y: CGFloat = 300
        let x0 = win.maxX + 10, x1 = body.minX - 10
        ctx.saveGState()
        ctx.setLineCap(.round)
        ctx.setLineDash(phase: CGFloat(-t * 40), lengths: [8, 9])
        let path = CGMutablePath()
        path.move(to: CGPoint(x: x0, y: y))
        path.addLine(to: CGPoint(x: x0 + (x1 - x0) * CGFloat(grow), y: y))
        strokePath(ctx, path, rgb(LIGHT ? BLUE : 0xFFFFFF, 0.8), width: 3)
        ctx.restoreGState()
    }
}

/// Langkah 3 — Pakai: kursor ke tepi Mac, muncul di HP, ketuk foto, lalu kembali (berulang mulus).
func renderStepUse(_ ctx: CGContext, t: Double) {
    // Mac
    let screen = CGRect(x: 50, y: 150, width: 440, height: 276)
    let body = screen.insetBy(dx: -10, dy: -10)
    fill(ctx, rounded(body, 18), rgb(DEVICE))
    strokePath(ctx, rounded(body, 18), rgb(DEVICE_EDGE), width: 1.5)
    let base = CGMutablePath()
    base.move(to: CGPoint(x: body.minX - 24, y: body.maxY - 2))
    base.addLine(to: CGPoint(x: body.maxX + 24, y: body.maxY - 2))
    base.addLine(to: CGPoint(x: body.maxX + 14, y: body.maxY + 12))
    base.addLine(to: CGPoint(x: body.minX - 14, y: body.maxY + 12))
    base.closeSubpath()
    fill(ctx, base, rgb(DEVICE_EDGE))
    ctx.saveGState()
    ctx.addPath(rounded(screen, 8))
    ctx.clip()
    fill(ctx, CGPath(rect: screen, transform: nil), rgb(BLUE))
    fill(ctx, CGPath(rect: CGRect(x: screen.minX, y: screen.minY, width: screen.width, height: 14), transform: nil), rgb(0x000000, 0.28))
    let win = CGRect(x: screen.minX + 40, y: screen.minY + 42, width: 240, height: 168)
    fill(ctx, rounded(win, 10), rgb(WINDOW))
    for (i, c) in [UInt32(0xFF5F57), 0xFEBC2E, 0x28C840].enumerated() {
        fill(ctx, CGPath(ellipseIn: CGRect(x: win.minX + 10 + CGFloat(i) * 12, y: win.minY + 9, width: 7, height: 7), transform: nil), rgb(c))
    }
    for i in 0..<6 {
        let r = CGRect(x: win.minX + 74 + CGFloat(i % 3) * 52, y: win.minY + 34 + CGFloat(i / 3) * 62, width: 44, height: 54)
        fill(ctx, rounded(r, 6), rgb(tileColors[(i * 2) % tileColors.count]))
    }
    for i in 0..<4 {
        fill(ctx, rounded(CGRect(x: win.minX + 12, y: win.minY + 38 + CGFloat(i) * 12, width: CGFloat([40, 30, 36, 26][i]), height: 5), 2.5), rgb(LINE, 0.16))
    }
    ctx.restoreGState()

    // HP
    let phone = drawPhoneFrame(ctx, CGRect(x: 590, y: 130, width: 160, height: 316))
    text("Galeri", CGPoint(x: phone.minX + 12, y: phone.minY + 26), size: 17, weight: .bold)
    let tile: CGFloat = (phone.width - 24 - 8) / 2
    func phoneTile(_ i: Int) -> CGRect {
        CGRect(x: phone.minX + 12 + CGFloat(i % 2) * (tile + 8), y: phone.minY + 58 + CGFloat(i / 2) * (tile + 8), width: tile, height: tile)
    }
    let tapped = 2
    let press = CGFloat(envelope(t, 2.78, 2.84, 2.88, 2.98))
    ctx.saveGState()
    ctx.addPath(rounded(phone, 23))
    ctx.clip()
    for i in 0..<8 {
        var r = phoneTile(i)
        if i == tapped {
            r = r.insetBy(dx: r.width * 0.05 * press, dy: r.height * 0.05 * press)
            ctx.saveGState()
            ctx.addPath(rounded(r, 8))
            ctx.clip()
            drawPhoto(ctx, r)
            ctx.restoreGState()
        } else {
            fill(ctx, rounded(r, 8), rgb(tileColors[(i * 5 + 2) % tileColors.count]))
        }
    }
    ctx.restoreGState()

    // Kursor: Mac → HP → Mac, kembali ke titik awal pada t = 6 (berulang mulus).
    let start = CGPoint(x: 250, y: 330)
    let exitY: CGFloat = 300
    let phoneY = phone.minY + (exitY - screen.minY) / screen.height * phone.height
    let target = CGPoint(x: phoneTile(tapped).midX, y: phoneTile(tapped).midY)
    let backY = phone.minY + 0.3 * phone.height
    let macBackY = screen.minY + 0.3 * screen.height
    let crossOut = 1.6, crossBack = 4.4
    let segs = [
        Segment(t0: 0.0, t1: crossOut, from: start, control: CGPoint(x: 380, y: 350),
                to: CGPoint(x: screen.maxX - 0.5, y: exitY), ease: easeIn),
        Segment(t0: crossOut, t1: 2.6, from: CGPoint(x: phone.minX + 1, y: phoneY),
                control: CGPoint(x: phone.minX + 30, y: phoneY + 10), to: target, ease: easeOut),
        Segment(t0: 3.3, t1: crossBack, from: target, control: CGPoint(x: phone.minX + 30, y: backY - 20),
                to: CGPoint(x: phone.minX + 0.5, y: backY), ease: easeIn),
        Segment(t0: crossBack, t1: 6.0, from: CGPoint(x: screen.maxX - 1, y: macBackY),
                control: CGPoint(x: 360, y: macBackY + 10), to: start, ease: easeOut),
    ]
    let cursor = position(segs, t)
    let onMac = t < crossOut || t >= crossBack

    let macEdge = max(envelope(t, crossOut - 0.25, crossOut, crossOut + 0.05, crossOut + 0.45),
                      envelope(t, crossBack - 0.05, crossBack, crossBack + 0.05, crossBack + 0.5))
    if macEdge > 0 {
        fill(ctx, CGPath(rect: CGRect(x: screen.maxX - 4, y: screen.minY + 20, width: 4, height: screen.height - 40), transform: nil),
             rgb(0xFFFFFF, 0.9 * macEdge))
    }
    let phoneEdge = max(envelope(t, crossOut - 0.05, crossOut, crossOut + 0.05, crossOut + 0.5),
                        envelope(t, crossBack - 0.25, crossBack, crossBack + 0.05, crossBack + 0.4))
    if phoneEdge > 0 {
        fill(ctx, CGPath(rect: CGRect(x: phone.minX, y: phone.minY + 24, width: 4, height: phone.height - 48), transform: nil),
             rgb(ACCENT, 0.9 * phoneEdge))
    }
    ripple(ctx, at: target, progress: span(t, 2.8, 3.2))

    ctx.saveGState()
    ctx.addPath(onMac ? rounded(screen, 8) : rounded(phone, 23))
    ctx.clip()
    drawCursor(ctx, at: cursor, scale: 1.2)
    ctx.restoreGState()
}

func renderStep(_ ctx: CGContext, t: Double, step: Int) {
    // Adegan dirancang di kanvas 800×600, lalu diskalakan ke resolusi keluaran.
    ctx.saveGState()
    ctx.scaleBy(x: CGFloat(W) / 800, y: CGFloat(H) / 600)
    let canvas = CGRect(x: 0, y: 0, width: 800, height: 600)
    fill(ctx, CGPath(rect: canvas, transform: nil), rgb(BG))
    // Bingkai lebih rapat: perbesar 6% dari tengah supaya perangkat tampil lebih besar.
    ctx.translateBy(x: 400, y: 300)
    ctx.scaleBy(x: 1.06, y: 1.06)
    ctx.translateBy(x: -400, y: -300)
    switch step {
    case 1: renderStepInstall(ctx, t: t)
    case 2: renderStepPair(ctx, t: t)
    default: renderStepUse(ctx, t: t)
    }
    // Langkah 1 & 2 bukan putaran alami: pudar masuk/keluar agar pengulangan halus.
    if step != 3 {
        let fade = max(1 - easeOut(span(t, 0, 0.3)), easeIn(span(t, DURATION - 0.35, DURATION)))
        if fade > 0 {
            fill(ctx, CGPath(rect: canvas.insetBy(dx: -60, dy: -60), transform: nil), rgb(BG, CGFloat(fade)))
        }
    }
    ctx.restoreGState()
}

// MARK: - Render frame (dengan motion blur)

func makeContext(data: UnsafeMutableRawPointer? = nil, bytesPerRow: Int = 0) -> CGContext {
    CGContext(data: data, width: W, height: H, bitsPerComponent: 8, bytesPerRow: bytesPerRow, space: srgb,
              bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
}

func renderSubframe(_ t: Double) -> CGImage {
    let ctx = makeContext()
    ctx.translateBy(x: 0, y: CGFloat(H))
    ctx.scaleBy(x: 1, y: -1)
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
    ctx.interpolationQuality = .high
    if let step = STEP { renderStep(ctx, t: t, step: step) } else { renderScene(ctx, t: t) }
    NSGraphicsContext.current = nil
    return ctx.makeImage()!
}

/// Rata-rata berjalan beberapa sub-frame dalam rentang shutter.
func renderFrame(_ index: Int, into ctx: CGContext) {
    let t0 = Double(index) / Double(FPS)
    let rect = CGRect(x: 0, y: 0, width: W, height: H)
    for k in 0..<SUBFRAMES {
        let t = t0 + (Double(k) / Double(SUBFRAMES)) * SHUTTER / Double(FPS)
        let image = renderSubframe(t)
        ctx.setAlpha(1 / CGFloat(k + 1))
        ctx.draw(image, in: rect)
    }
    ctx.setAlpha(1)
}

// MARK: - Mode: still PNG

func writeStills(_ times: [Double], to folder: URL) throws {
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    for t in times {
        let ctx = makeContext()
        renderFrame(Int((t * Double(FPS)).rounded()), into: ctx)
        let url = folder.appendingPathComponent(String(format: "still-%05.2f.png", t))
        let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        CGImageDestinationFinalize(dest)
        print(url.path)
    }
}

// MARK: - Mode: poster JPEG (frame pertama video, untuk <video poster>)

func writePoster(_ t: Double, to url: URL) {
    let ctx = makeContext()
    renderFrame(Int((t * Double(FPS)).rounded()), into: ctx)
    let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, ctx.makeImage()!, [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
    CGImageDestinationFinalize(dest)
    print(url.path)
}

// MARK: - Mode: video

func writeVideo(to url: URL) throws {
    try? FileManager.default.removeItem(at: url)
    let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: W,
        AVVideoHeightKey: H,
        AVVideoColorPropertiesKey: [
            AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
            AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
            AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
        ],
        AVVideoCompressionPropertiesKey: [
            AVVideoAverageBitRateKey: BITRATE,
            AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            AVVideoMaxKeyFrameIntervalKey: FPS,
            AVVideoExpectedSourceFrameRateKey: FPS,
        ],
    ])
    input.expectsMediaDataInRealTime = false
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: W,
        kCVPixelBufferHeightKey as String: H,
        kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
        kCVPixelBufferCGImageCompatibilityKey as String: true,
    ])
    writer.add(input)
    guard writer.startWriting() else { throw writer.error ?? NSError(domain: "DemoVideo", code: 1) }
    writer.startSession(atSourceTime: .zero)

    let frames = Int(DURATION * Double(FPS))
    for i in 0..<frames {
        while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.002) }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
        guard let pb = buffer else { throw NSError(domain: "DemoVideo", code: 2) }
        CVPixelBufferLockBaseAddress(pb, [])
        let ctx = makeContext(data: CVPixelBufferGetBaseAddress(pb), bytesPerRow: CVPixelBufferGetBytesPerRow(pb))
        renderFrame(i, into: ctx)
        CVPixelBufferUnlockBaseAddress(pb, [])
        adaptor.append(pb, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: CMTimeScale(FPS)))
        if i % FPS == 0 { print("  \(i / FPS)s / \(Int(DURATION))s") }
    }
    input.markAsFinished()
    let done = DispatchSemaphore(value: 0)
    writer.finishWriting { done.signal() }
    done.wait()
    if writer.status != .completed { throw writer.error ?? NSError(domain: "DemoVideo", code: 3) }
}

// MARK: - Main

let args: [String] = {
    var a = CommandLine.arguments.filter { $0 != "--light" }
    if let i = a.firstIndex(of: "--step") { a.removeSubrange(i...min(i + 1, a.count - 1)) }
    return a
}()
do {
    if args.count >= 4, args[1] == "--poster" {
        writePoster(Double(args[2]) ?? 0, to: URL(fileURLWithPath: args[3]))
    } else if args.count >= 4, args[1] == "--stills" {
        try writeStills(args[2].split(separator: ",").compactMap { Double($0) }, to: URL(fileURLWithPath: args[3]))
    } else {
        let out = URL(fileURLWithPath: args.count >= 2 ? args[1] : "cursoe-demo.mp4")
        let start = Date()
        try writeVideo(to: out)
        print(String(format: "✓ %@ (%.0f detik render)", out.path, Date().timeIntervalSince(start)))
    }
} catch {
    FileHandle.standardError.write("Gagal: \(error)\n".data(using: .utf8)!)
    exit(1)
}
