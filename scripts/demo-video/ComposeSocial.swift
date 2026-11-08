// Video demo untuk media sosial (Threads/Instagram): 4:5 1080×1350, 60 fps, dari rekaman NYATA Mac + tablet.
//
//   ComposeSocial [--size 1080x1350] [--og og-image.png] [--poster detik] <folder rekaman> <out.mp4|out.jpg>
//
// Alur: kartu pembuka biru (teks besar) → demo nyata dengan kamera zoom in/out per adegan dan judul besar di
// atas → kartu penutup (logo, alamat website). Waktu adegan diambil dari events.txt (dicatat DemoDriver), jadi video
// otomatis pas dengan rekaman terbaru dari record-real.sh.
// Privasi: foto profil Google di Chrome ditutup, dan animasi buka/tutup Chrome (jendela bergerak, penutup
// tidak mengenai) diganti crossfade — sama dengan ComposeReal.
import AppKit
import AVFoundation
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers
import VideoToolbox

// MARK: - Argumen

var args = Array(CommandLine.arguments.dropFirst())
func take(_ flag: String) -> String? {
    guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
    let value = args[i + 1]
    args.removeSubrange(i...(i + 1))
    return value
}
let posterAt = take("--poster").flatMap(Double.init)
let ogPath = take("--og")
let sizeParts = (take("--size") ?? "1080x1350").split(separator: "x").compactMap { Int($0) }
guard args.count == 2, sizeParts.count == 2 else {
    FileHandle.standardError.write("Pakai: ComposeSocial [--size WxH] [--og og.png] [--poster dtk] <folder rekaman> <out>\n".data(using: .utf8)!)
    exit(2)
}
let rawDir = URL(fileURLWithPath: args[0])
let outPath = args[1]
let W = sizeParts[0], H = sizeParts[1], FPS = 60
let BITRATE = 12_000_000 // diunggah lalu dikompres ulang oleh platform: kirim sumber yang tajam
let CW = CGFloat(W), CH = CGFloat(H)

// MARK: - Data rekaman

func readText(_ name: String) -> String {
    guard let text = try? String(contentsOf: rawDir.appendingPathComponent(name), encoding: .utf8) else {
        fatalError("Tidak ada \(name) di \(rawDir.path) — jalankan record-real.sh dulu")
    }
    return text.trimmingCharacters(in: .whitespacesAndNewlines)
}
let macStart = Double(readText("mac.start"))! / 1000
let phoneStart = Double(readText("phone.start"))! / 1000
let driverStart = Double(readText("driver.start"))! / 1000
/// Waktu sumber 0 = saat kedua perekam sudah berjalan.
let commonStart = max(macStart, phoneStart)
let macOffset = commonStart - macStart
let phoneOffset = commonStart - phoneStart

/// Kejadian (detik waktu sumber). "back" muncul dua kali: back1 (sesudah Chrome) & back2 (sesudah Sheets).
var events: [String: Double] = [:]
for line in readText("events.txt").split(separator: "\n") {
    let p = line.split(separator: " ")
    guard p.count == 3, p[0] == "EVENT", let v = Double(p[2]) else { continue }
    var name = String(p[1])
    if name == "back" { name = events["back1"] == nil ? "back1" : "back2" }
    events[name] = v + driverStart - commonStart
}
func ev(_ name: String) -> Double {
    guard let v = events[name] else { fatalError("Kejadian '\(name)' tidak ada di events.txt") }
    return v
}
let target = (try? JSONSerialization.jsonObject(with: Data(readText("target.json").utf8))) as? [String: Any] ?? [:]
func targetPoint(_ key: String) -> CGPoint? {
    guard let v = target[key] as? [Double], v.count == 2 else { return nil }
    return CGPoint(x: v[0], y: v[1])
}
/// Foto profil Google di toolbar Chrome (px layar tablet), bila tercatat.
let avatar: CGRect? = {
    let v = readText("avatar.txt").split(separator: ",").compactMap { Double($0) }
    return v.count == 4 ? CGRect(x: v[0], y: v[1], width: v[2] - v[0], height: v[3] - v[1]) : nil
}()

// MARK: - Sumber video

/// Membaca frame berurutan (resolusi penuh agar tetap tajam saat zoom) dan memberi frame terakhir ≤ waktu t.
final class FrameSource {
    let duration: Double
    let size: CGSize
    private let reader: AVAssetReader
    private let output: AVAssetReaderTrackOutput
    private let transform: CGAffineTransform
    private var pending: CMSampleBuffer?
    private(set) var image: CGImage?

    init(path: String, maxWidth: CGFloat) {
        let asset = AVURLAsset(url: URL(fileURLWithPath: path))
        guard let track = asset.tracks(withMediaType: .video).first else { fatalError("Tidak ada trek video di \(path)") }
        duration = CMTimeGetSeconds(asset.duration)
        transform = track.preferredTransform
        let natural = track.naturalSize
        let shown = natural.applying(transform)
        size = CGSize(width: abs(shown.width), height: abs(shown.height))
        let scale = min(1, maxWidth / max(natural.width, natural.height))
        reader = try! AVAssetReader(asset: asset)
        output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int((natural.width * scale / 2).rounded()) * 2,
            kCVPixelBufferHeightKey as String: Int((natural.height * scale / 2).rounded()) * 2,
        ])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        reader.startReading()
        pending = output.copyNextSampleBuffer()
    }

    func frame(at t: Double) -> CGImage? {
        while let buffer = pending, CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(buffer)) <= t {
            if let pixels = CMSampleBufferGetImageBuffer(buffer) {
                var cg: CGImage?
                VTCreateCGImageFromCVPixelBuffer(pixels, options: nil, imageOut: &cg)
                if let cg { image = rotated(cg) }
            }
            pending = output.copyNextSampleBuffer()
        }
        return image
    }

    private func rotated(_ image: CGImage) -> CGImage {
        guard !transform.isIdentity else { return image }
        let w = CGFloat(image.width), h = CGFloat(image.height)
        let bounds = CGRect(x: 0, y: 0, width: w, height: h).applying(transform)
        let ctx = CGContext(data: nil, width: Int(abs(bounds.width)), height: Int(abs(bounds.height)), bitsPerComponent: 8,
                            bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        ctx.concatenate(CGAffineTransform(translationX: -bounds.minX, y: -bounds.minY))
        ctx.concatenate(transform)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage() ?? image
    }
}

let mac = FrameSource(path: rawDir.appendingPathComponent("mac.mov").path, maxWidth: 4000)
let phone = FrameSource(path: rawDir.appendingPathComponent("phone.mp4").path, maxWidth: 2400)

// MARK: - Warna & tipografi

let space = CGColorSpace(name: CGColorSpace.sRGB)!
func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}
let BG = rgb(0xF5F6FB)       // latar halaman website (terang)
let INK = rgb(0x0D1020)      // teks utama
let BRAND = rgb(0x1E40AF)    // blue-800
let WHITE = rgb(0xFFFFFF)
let BEZEL = rgb(0x0D1020)
let RIM = rgb(0xFFFFFF, 0.8)
let BASE = rgb(0xCDD0DA)
let BASE_EDGE = rgb(0xA9ADBB)

/// SF Pro (font sistem): bersih & tegas untuk judul besar.
func font(_ size: CGFloat, _ weight: NSFont.Weight) -> CTFont { NSFont.systemFont(ofSize: size, weight: weight) as CTFont }

/// Satu baris teks; segmen bertanda `*…*` diwarnai `accent`.
func textLine(_ text: String, size: CGFloat, weight: NSFont.Weight, color: CGColor, accent: CGColor) -> CTLine {
    let result = NSMutableAttributedString()
    let ctFont = font(size, weight)
    for (i, part) in text.components(separatedBy: "*").enumerated() where !part.isEmpty {
        result.append(NSAttributedString(string: part, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): ctFont,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): i % 2 == 1 ? accent : color,
            .kern: -0.028 * size,
        ]))
    }
    return CTLineCreateWithAttributedString(result)
}

func clamp01(_ x: Double) -> Double { min(max(x, 0), 1) }
func easeOut(_ x: Double) -> Double { let t = clamp01(x); return 1 - pow(1 - t, 3) }
func easeIn(_ x: Double) -> Double { let t = clamp01(x); return t * t * t }
func easeInOut(_ x: Double) -> Double { let t = clamp01(x); return t * t * t * (t * (6 * t - 15) + 10) }

/// Teks muncul naik dari balik garis dasar (topeng), lalu keluar naik sambil memudar.
/// `enter`/`exit`: 0…1 kemajuan animasi masuk/keluar.
func drawRisingLine(_ ctx: CGContext, _ line: CTLine, x: CGFloat, baseline: CGFloat, size: CGFloat, enter: Double, exit: Double) {
    guard enter > 0, exit < 1 else { return }
    var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
    let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
    let rise = (1 - CGFloat(easeOut(enter))) * size * 1.05
    let lift = CGFloat(easeIn(exit)) * size * 0.4
    ctx.saveGState()
    ctx.clip(to: CGRect(x: x - 20, y: baseline - descent - 6, width: width + 40, height: ascent + descent + 12))
    ctx.setAlpha(CGFloat(easeOut(enter * 1.4) * (1 - easeIn(exit))))
    ctx.textPosition = CGPoint(x: x, y: baseline - rise + lift)
    CTLineDraw(line, ctx)
    ctx.restoreGState()
}

// MARK: - Tata letak: judul di atas, panggung perangkat di bawah

let MARGIN: CGFloat = 72
let captionSize = (CW * 0.089).rounded()           // ±96 px pada lebar 1080
let captionLead = captionSize * 1.06
let captionTop = CH - CH * 0.055                    // batas atas area judul
let stageTop = CH - CH * 0.245                      // perangkat tidak pernah naik melewati garis ini
let stageCenter = CGPoint(x: CW / 2, y: stageTop * 0.54)

let macAspect = mac.size.width / mac.size.height
let phoneAspect = phone.size.width / phone.size.height
let gap: CGFloat = 26
// Ukuran fisik: tinggi layar Mac ≈ 1,47× tinggi layar dalam Fold. Keduanya muat utuh dalam lebar kanvas.
let phoneH = (CW - 2 * 44 - gap) / (1.47 * macAspect + phoneAspect)
let phoneW = phoneH * phoneAspect
let macH = phoneH * 1.47
let macW = macH * macAspect
let groupW = macW + gap + phoneW
let macRect = CGRect(x: (CW - groupW) / 2, y: stageCenter.y - macH / 2 + 10, width: macW, height: macH)
let phoneRect = CGRect(x: macRect.maxX + gap, y: stageCenter.y - phoneH / 2 + 10, width: phoneW, height: phoneH)
let seam = CGPoint(x: macRect.maxX + gap / 2, y: stageCenter.y)
let groupCenter = CGPoint(x: (macRect.minX + phoneRect.maxX) / 2, y: stageCenter.y)

/// Titik di layar tablet (px rekaman) → koordinat kanvas.
func onPhone(_ p: CGPoint) -> CGPoint {
    CGPoint(x: phoneRect.minX + p.x / phone.size.width * phoneRect.width,
            y: phoneRect.maxY - p.y / phone.size.height * phoneRect.height)
}

func roundedPath(_ rect: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

func drawScreen(_ ctx: CGContext, image: CGImage?, in rect: CGRect, bezel: CGFloat, radius: CGFloat) {
    let outer = rect.insetBy(dx: -bezel, dy: -bezel)
    ctx.addPath(roundedPath(outer, radius + bezel))
    ctx.setFillColor(BEZEL)
    ctx.fillPath()
    ctx.saveGState()
    ctx.addPath(roundedPath(rect, radius))
    ctx.clip()
    if let image {
        ctx.interpolationQuality = .high
        ctx.draw(image, in: rect)
    } else {
        ctx.setFillColor(rgb(0x000000))
        ctx.fill(rect)
    }
    ctx.restoreGState()
    ctx.addPath(roundedPath(outer, radius + bezel))
    ctx.setStrokeColor(RIM)
    ctx.setLineWidth(1)
    ctx.strokePath()
}

func drawLaptopBase(_ ctx: CGContext) {
    let bezel: CGFloat = 8
    let top = macRect.minY - bezel
    let height = max(10, macRect.height * 0.045)
    let overhang = macRect.width * 0.075
    let base = CGRect(x: macRect.minX - bezel - overhang, y: top - height, width: macRect.width + 2 * (bezel + overhang), height: height)
    let r = height * 0.85
    let path = CGMutablePath()
    path.move(to: CGPoint(x: base.minX, y: base.maxY))
    path.addLine(to: CGPoint(x: base.maxX, y: base.maxY))
    path.addLine(to: CGPoint(x: base.maxX, y: base.minY + r))
    path.addQuadCurve(to: CGPoint(x: base.maxX - r * 2.2, y: base.minY), control: CGPoint(x: base.maxX - r * 0.2, y: base.minY))
    path.addLine(to: CGPoint(x: base.minX + r * 2.2, y: base.minY))
    path.addQuadCurve(to: CGPoint(x: base.minX, y: base.minY + r), control: CGPoint(x: base.minX + r * 0.2, y: base.minY))
    path.closeSubpath()
    ctx.addPath(path)
    ctx.setFillColor(BASE)
    ctx.fillPath()
    ctx.setFillColor(BASE_EDGE)
    ctx.fill(CGRect(x: base.minX, y: base.maxY - 1.5, width: base.width, height: 1.5))
    let notch = CGRect(x: macRect.midX - macRect.width * 0.08, y: base.maxY - height * 0.42, width: macRect.width * 0.16, height: height * 0.42)
    ctx.addPath(CGPath(roundedRect: notch, cornerWidth: height * 0.3, cornerHeight: height * 0.3, transform: nil))
    ctx.fillPath()
}

// MARK: - Linimasa

/// Rentang rekaman yang dipakai (detik sumber).
let S0 = ev("cross") - 1.3
let S1 = min(ev("end") + 0.5, mac.duration - macOffset)
let INTRO: Double = 2.4                     // kartu pembuka; rekaman mulai berjalan saat kartu tersibak
let WIPE: Double = 0.6
let FOOT_START = INTRO - WIPE
let OUTRO_START = FOOT_START + (S1 - S0)
let OUTRO: Double = 3.4
let TOTAL = OUTRO_START + OUTRO

/// Waktu video → waktu sumber (rekaman ditahan sebelum mulai & sesudah selesai).
func sourceTime(_ t: Double) -> Double { S0 + min(max(t - FOOT_START, 0), S1 - S0) }

// MARK: - Kamera (zoom in/out antar-adegan)

struct Shot { let at: Double; let zoom: CGFloat; let focus: CGPoint; let move: Double }
let urlPoint = onPhone(targetPoint("url") ?? CGPoint(x: phone.size.width / 2, y: phone.size.height * 0.14))
let cellPoint = onPhone(targetPoint("cell") ?? CGPoint(x: phone.size.width / 2, y: phone.size.height / 2))
let phoneCenter = CGPoint(x: phoneRect.midX, y: phoneRect.midY)
/// `at` = saat shot sudah penuh; perpindahan dari shot sebelumnya berlangsung `move` detik sebelum itu.
let shots: [Shot] = [
    Shot(at: S0, zoom: 1.1, focus: groupCenter, move: 0.01),
    Shot(at: ev("cross") + 0.1, zoom: 1.7, focus: seam, move: 1.0),                // kursor menyeberang
    Shot(at: ev("chrome") + 0.5, zoom: 2.15, focus: phoneCenter, move: 0.8),        // tablet: Chrome terbuka
    Shot(at: ev("type") + 0.1, zoom: 2.9, focus: urlPoint, move: 0.7),              // ketik URL
    Shot(at: ev("enter") + 1.3, zoom: 2.15, focus: phoneCenter, move: 0.8),         // halaman termuat
    Shot(at: ev("back1") + 0.5, zoom: 1.1, focus: groupCenter, move: 0.9),         // kembali ke Mac: seret Excel
    Shot(at: ev("xlsx-drop") + 0.9, zoom: 2.15, focus: phoneCenter, move: 0.8),     // panel "Buka dengan" → Sheets
    Shot(at: ev("cell") + 0.1, zoom: 3.0, focus: cellPoint, move: 0.8),             // ketik 300, Total berubah
    Shot(at: ev("total") + 1.2, zoom: 2.15, focus: phoneCenter, move: 0.7),
    Shot(at: ev("back2") + 0.5, zoom: 1.1, focus: groupCenter, move: 0.9),         // seret foto dari Mac
    Shot(at: ev("photo-drop") + 1.0, zoom: 2.15, focus: phoneCenter, move: 0.8),    // panel "Buka dengan"
    Shot(at: S1 - 0.1, zoom: 1.1, focus: groupCenter, move: 1.0),
]

func camera(_ s: Double) -> (CGFloat, CGPoint) {
    var current = shots[0]
    for (i, shot) in shots.enumerated() where i > 0 {
        let start = shot.at - shot.move
        if s < start { break }
        let u = CGFloat(easeInOut((s - start) / shot.move))
        // Zoom diinterpolasi secara logaritmik (terasa rata), fokus secara linear.
        let zoom = exp(log(current.zoom) + (log(shot.zoom) - log(current.zoom)) * u)
        let focus = CGPoint(x: current.focus.x + (shot.focus.x - current.focus.x) * u,
                            y: current.focus.y + (shot.focus.y - current.focus.y) * u)
        current = Shot(at: shot.at, zoom: zoom, focus: focus, move: shot.move)
    }
    return (current.zoom, current.focus)
}

// MARK: - Judul per adegan (waktu sumber)

struct Caption { let from: Double; let to: Double; let lines: [String] }
let captions: [Caption] = [
    Caption(from: S0 + 0.2, to: ev("chrome") + 0.9, lines: ["Push the cursor", "*past the edge.*"]),
    Caption(from: ev("chrome") + 0.9, to: ev("back1") + 0.1, lines: ["Type with your", "*Mac keyboard.*"]),
    Caption(from: ev("back1") + 0.1, to: ev("xlsx-drop") + 1.4, lines: ["Drag files", "*across.*"]),
    Caption(from: ev("xlsx-drop") + 1.4, to: ev("back2") + 0.1, lines: ["Edit in", "*any app.*"]),
    Caption(from: ev("back2") + 0.1, to: S1 + 0.3, lines: ["Photos,", "*too.*"]),
]
let captionLines: [[CTLine]] = captions.map { c in
    c.lines.map { textLine($0, size: captionSize, weight: .heavy, color: INK, accent: BRAND) }
}

func drawCaptions(_ ctx: CGContext, _ s: Double, videoTime t: Double) {
    guard t >= FOOT_START else { return }
    for (i, caption) in captions.enumerated() where s >= caption.from - 0.05 && s <= caption.to + 0.05 {
        for (j, line) in captionLines[i].enumerated() {
            let enter = (s - caption.from - Double(j) * 0.09) / 0.55
            let exit = (s - (caption.to - 0.32)) / 0.32
            let baseline = captionTop - captionSize * 0.95 - CGFloat(j) * captionLead
            drawRisingLine(ctx, line, x: MARGIN, baseline: baseline, size: captionSize, enter: enter, exit: exit)
        }
    }
}

// MARK: - Kartu pembuka & penutup

let introSize = (CW * 0.13).rounded()               // ±140 px
let introLines = ["One cursor.", "Two screens."].map { textLine($0, size: introSize, weight: .heavy, color: WHITE, accent: WHITE) }

func drawIntro(_ ctx: CGContext, _ t: Double) {
    guard t < INTRO else { return }
    // Kartu biru tersibak ke atas.
    let lift = CGFloat(easeInOut((t - FOOT_START) / WIPE)) * CH
    ctx.saveGState()
    ctx.translateBy(x: 0, y: lift)
    ctx.setFillColor(BRAND)
    ctx.fill(CGRect(x: 0, y: 0, width: CW, height: CH))
    let blockH = introSize * 1.04 * CGFloat(introLines.count - 1)
    for (j, line) in introLines.enumerated() {
        let baseline = CH / 2 + blockH / 2 - CGFloat(j) * introSize * 1.04 - introSize * 0.32
        drawRisingLine(ctx, line, x: MARGIN, baseline: baseline, size: introSize, enter: (t - 0.15 - Double(j) * 0.45) / 0.6, exit: 0)
    }
    ctx.restoreGState()
}

let ogImage: CGImage? = ogPath.flatMap { path in
    CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
}
let outroURL = textLine("cursoe.app", size: (CW * 0.06).rounded(), weight: .bold, color: WHITE, accent: WHITE)
let outroMeta = textLine("macOS  ·  Android", size: (CW * 0.03).rounded(), weight: .semibold, color: rgb(0xFFFFFF, 0.72), accent: WHITE)
let fallbackName = textLine("Cursoe", size: (CW * 0.15).rounded(), weight: .heavy, color: WHITE, accent: WHITE)

func centeredX(_ line: CTLine) -> CGFloat { (CW - CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))) / 2 }

func drawOutro(_ ctx: CGContext, _ t: Double) {
    let u = t - OUTRO_START
    guard u > 0 else { return }
    // Kartu biru naik dari bawah.
    let rise = (1 - CGFloat(easeInOut(u / WIPE))) * CH
    ctx.saveGState()
    ctx.translateBy(x: 0, y: -rise)
    ctx.setFillColor(BRAND)
    ctx.fill(CGRect(x: 0, y: 0, width: CW, height: CH))
    let v = u - WIPE * 0.6
    // Logo (gambar pratinjau website: latar biru yang sama, jadi menyatu) — sedikit membesar saat muncul.
    let logoCenterY = CH * 0.56
    if let ogImage {
        let w = CW, h = w * CGFloat(ogImage.height) / CGFloat(ogImage.width)
        let scale = 0.94 + 0.06 * CGFloat(easeOut(v / 0.8))
        ctx.saveGState()
        ctx.setAlpha(CGFloat(easeOut(v / 0.5)))
        ctx.translateBy(x: CW / 2, y: logoCenterY)
        ctx.scaleBy(x: scale, y: scale)
        ctx.interpolationQuality = .high
        ctx.draw(ogImage, in: CGRect(x: -w / 2, y: -h / 2, width: w, height: h))
        ctx.restoreGState()
    } else {
        drawRisingLine(ctx, fallbackName, x: centeredX(fallbackName), baseline: logoCenterY - CW * 0.05,
                       size: CW * 0.15, enter: v / 0.6, exit: 0)
    }
    drawRisingLine(ctx, outroURL, x: centeredX(outroURL), baseline: CH * 0.27, size: CW * 0.06, enter: (v - 0.35) / 0.6, exit: 0)
    drawRisingLine(ctx, outroMeta, x: centeredX(outroMeta), baseline: CH * 0.27 - CW * 0.075, size: CW * 0.03, enter: (v - 0.5) / 0.6, exit: 0)
    ctx.restoreGState()
}

// MARK: - Render satu frame

let maskRange = (ev("chrome"), events["sheets"] ?? 1e9)
/// Animasi Chrome membesar dari ikon & menyusut saat Sheets dibuka: tampilkan crossfade sebelum → sesudah.
var xfades: [(Double, Double)] = [(ev("chrome") - 0.35, ev("chrome") + 0.25)]
if let sheets = events["sheets"] { xfades.append((sheets - 0.05, sheets + 0.8)) }
var xfadeFrames: [Int: (CGImage?, CGImage?)] = [:]

func drawPhone(_ ctx: CGContext, _ image: CGImage?, at time: Double) {
    drawScreen(ctx, image: image, in: phoneRect, bezel: 6, radius: 10)
    guard let avatar, time >= maskRange.0, time <= maskRange.1 else { return }
    let sx = phoneRect.width / phone.size.width, sy = phoneRect.height / phone.size.height
    let side = min(avatar.width, avatar.height) * 0.62
    let center = CGPoint(x: phoneRect.minX + avatar.midX * sx, y: phoneRect.maxY - avatar.midY * sy)
    ctx.setFillColor(rgb(0x5F6368))
    ctx.fillEllipse(in: CGRect(x: center.x - side * sx / 2, y: center.y - side * sy / 2, width: side * sx, height: side * sy))
}

func render(_ t: Double, into ctx: CGContext) {
    ctx.setFillColor(BG)
    ctx.fill(CGRect(x: 0, y: 0, width: CW, height: CH))
    let s = sourceTime(t)

    // Panggung perangkat (di bawah area judul).
    let (zoom, focus) = camera(s)
    ctx.saveGState()
    ctx.clip(to: CGRect(x: 0, y: 0, width: CW, height: stageTop))
    ctx.translateBy(x: stageCenter.x, y: stageCenter.y)
    ctx.scaleBy(x: zoom, y: zoom)
    ctx.translateBy(x: -focus.x, y: -focus.y)
    drawLaptopBase(ctx)
    drawScreen(ctx, image: mac.frame(at: s + macOffset), in: macRect, bezel: 8, radius: 7)
    if let i = xfades.firstIndex(where: { s >= $0.0 && s < $0.1 }) {
        let (a, b) = xfades[i]
        if xfadeFrames[i] == nil {
            let first = phone.frame(at: s + phoneOffset)
            xfadeFrames[i] = (first, phone.frame(at: b + phoneOffset))
        }
        let (first, last) = xfadeFrames[i]!
        drawPhone(ctx, first, at: a)
        ctx.saveGState()
        ctx.setAlpha(CGFloat(easeInOut((s - a) / (b - a))))
        ctx.beginTransparencyLayer(auxiliaryInfo: nil) // gambar + penutup jadi satu lapisan (foto tidak tembus)
        drawPhone(ctx, last, at: b)
        ctx.endTransparencyLayer()
        ctx.restoreGState()
    } else {
        drawPhone(ctx, phone.frame(at: s + phoneOffset), at: s)
    }
    ctx.restoreGState()

    drawCaptions(ctx, s, videoTime: t)
    drawIntro(ctx, t)
    drawOutro(ctx, t)
}

// MARK: - Keluaran

func makeContext() -> CGContext {
    CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0, space: space,
              bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
}

print(String(format: "Linimasa: pembuka %.1f dtk · demo %.1f dtk · penutup %.1f dtk · total %.1f dtk",
             INTRO, S1 - S0, OUTRO, TOTAL))

if let posterAt {
    let ctx = makeContext()
    var t = 0.0
    while t < posterAt { let s = sourceTime(t); _ = mac.frame(at: s + macOffset); _ = phone.frame(at: s + phoneOffset); t += 0.25 }
    render(posterAt, into: ctx)
    let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: outPath) as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, ctx.makeImage()!, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
    CGImageDestinationFinalize(dest)
    print("Sampul: \(outPath)")
    exit(0)
}

let url = URL(fileURLWithPath: outPath)
try? FileManager.default.removeItem(at: url)
let writer = try! AVAssetWriter(outputURL: url, fileType: .mp4)
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
])
writer.add(input)
writer.startWriting()
writer.startSession(atSourceTime: .zero)

let frames = Int(TOTAL * Double(FPS))
for i in 0..<frames {
    while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.002) }
    var buffer: CVPixelBuffer?
    CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
    guard let pixels = buffer else { continue }
    CVPixelBufferLockBaseAddress(pixels, [])
    let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pixels), width: W, height: H, bitsPerComponent: 8,
                        bytesPerRow: CVPixelBufferGetBytesPerRow(pixels), space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
    render(Double(i) / Double(FPS), into: ctx)
    CVPixelBufferUnlockBaseAddress(pixels, [])
    adaptor.append(pixels, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: CMTimeScale(FPS)))
    if i % (FPS * 5) == 0 { print("  \(i / FPS)/\(Int(TOTAL)) dtk") }
}
input.markAsFinished()
let done = DispatchSemaphore(value: 0)
writer.finishWriting { done.signal() }
done.wait()
print(writer.status == .completed ? "Selesai: \(outPath)" : "Gagal: \(writer.error?.localizedDescription ?? "?")")
