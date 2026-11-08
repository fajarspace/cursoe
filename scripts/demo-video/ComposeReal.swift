// Gabungkan rekaman layar NYATA (Mac + HP/tablet) menjadi video demo website: 1080×1080, 60 fps, H.264.
// Tanpa dependency: AVFoundation (baca & tulis video) + CoreGraphics (tata letak) + VideoToolbox.
//
//   ComposeReal --mac mac.mov --phone phone.mp4 [--mac-start ms --phone-start ms] [--nudge detik]
//               [--side right|left] [--light] [--plain] [--size 1920x1080] [--trim awal,akhir]
//               [--zoom a-b,c-d] [--poster detik] <out>
//
// Sinkron: skrip perekam mencatat waktu mulai (epoch ms) tiap perekam. (Waktu selesai tidak dipakai: adb
// bisa lambat kembali, dan rekaman Android hanya berisi frame saat layar berubah.) Bagian yang direkam
// bersamaan saja yang dipakai. --nudge menggeser video HP (+ = HP mulai lebih lambat).
// Tata letak: layar Mac besar (terpotong & memudar di sisi luar) bersebelahan dengan HP/tablet, karena
// yang ditonjolkan adalah tepi tempat kursor menyeberang. Kamera: napas zoom pelan ke sambungan;
// --zoom a-b memperbesar (×1,45) pada rentang detik itu.
import AVFoundation
import CoreGraphics
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
func flag(_ name: String) -> Bool {
    guard let i = args.firstIndex(of: name) else { return false }
    args.remove(at: i)
    return true
}

guard let macPath = take("--mac"), let phonePath = take("--phone") else {
    FileHandle.standardError.write("Pakai: ComposeReal --mac mac.mov --phone phone.mp4 [opsi] <out.mp4|out.jpg>\n".data(using: .utf8)!)
    exit(2)
}
let macStartMs = take("--mac-start").flatMap(Double.init) ?? 0
let phoneStartMs = take("--phone-start").flatMap(Double.init) ?? 0
let nudge = take("--nudge").flatMap(Double.init) ?? 0
let phoneOnLeft = take("--side") == "left"
let LIGHT = flag("--light")
let trim = take("--trim")?.split(separator: ",").compactMap { Double($0) }
/// --zoom a-b@fokus,…  fokus: seam (sambungan, bawaan), phone, phone-top, mac.
let zoomRanges: [(Double, Double, String)] = (take("--zoom") ?? "").split(separator: ",").compactMap { part in
    let pieces = part.split(separator: "@")
    let ab = pieces[0].split(separator: "-").compactMap { Double($0) }
    return ab.count == 2 ? (ab[0], ab[1], pieces.count > 1 ? String(pieces[1]) : "seam") : nil
}
let posterAt = take("--poster").flatMap(Double.init)
/// --mask x1,y1,x2,y2@a-b : tutup area (px layar HP) dengan lingkaran abu-abu netral pada rentang detik itu
/// (mis. foto profil akun Google di toolbar Chrome).
let maskSpec: (CGRect, Double, Double)? = take("--mask").flatMap { spec in
    let parts = spec.split(separator: "@")
    let r = parts[0].split(separator: ",").compactMap { Double($0) }
    let t = parts.count > 1 ? parts[1].split(separator: "-").compactMap { Double($0) } : [0, 1e9]
    guard r.count == 4, t.count == 2 else { return nil }
    return (CGRect(x: r[0], y: r[1], width: r[2] - r[0], height: r[3] - r[1]), t[0], t[1])
}
/// --xfade a-b[,c-d…] (detik sumber): selama rentang itu layar HP = crossfade dari frame a ke frame b; frame di
/// antaranya tidak ditampilkan. Dipakai untuk animasi buka/tutup Chrome: jendelanya bergerak sehingga penutup
/// --mask (posisi tetap) tidak mengenai foto profil.
let xfades: [(Double, Double)] = (take("--xfade") ?? "").split(separator: ",").compactMap { part in
    let ab = part.split(separator: "-").compactMap { Double($0) }
    return ab.count == 2 && ab[1] > ab[0] ? (ab[0], ab[1]) : nil
}
/// Frame awal & akhir tiap crossfade (pembaca video berurutan: frame akhir diambil dengan melompat ke depan).
var xfadeFrames: [Int: (CGImage?, CGImage?)] = [:]
/// --plain: latar polos warna halaman web (tanpa cahaya), agar video menyatu dengan halaman.
let PLAIN = flag("--plain")
let sizeParts = (take("--size") ?? "1080x1080").split(separator: "x").compactMap { Int($0) }
guard let outPath = args.last, sizeParts.count == 2 else { exit(2) }

let W = sizeParts[0], H = sizeParts[1], FPS = 60
/// Lebar (16:9 dst.): Mac utuh di sebelah HP. Persegi: Mac besar terpotong di sisi luar.
let WIDE = Double(W) / Double(H) >= 1.4
let BITRATE = WIDE ? 6_000_000 : 5_000_000 // video web: UI yang sebagian besar diam tetap tajam, file ±20 MB

// MARK: - Sumber video

/// Membaca frame berurutan (diskalakan saat decode agar cepat) dan memberi frame terakhir ≤ waktu t.
final class FrameSource {
    let duration: Double
    let size: CGSize          // ukuran tampil (sesudah rotasi)
    private let reader: AVAssetReader
    private let output: AVAssetReaderTrackOutput
    private let transform: CGAffineTransform
    private var pending: CMSampleBuffer?
    private(set) var image: CGImage?

    init(path: String, maxWidth: CGFloat) {
        let asset = AVURLAsset(url: URL(fileURLWithPath: path))
        guard let track = asset.tracks(withMediaType: .video).first else {
            fatalError("Tidak ada trek video di \(path)")
        }
        duration = CMTimeGetSeconds(asset.duration)
        transform = track.preferredTransform
        let natural = track.naturalSize
        let shown = natural.applying(transform)
        size = CGSize(width: abs(shown.width), height: abs(shown.height))
        let scale = min(1, maxWidth / max(natural.width, natural.height))
        let decodeW = Int((natural.width * scale / 2).rounded()) * 2
        let decodeH = Int((natural.height * scale / 2).rounded()) * 2
        reader = try! AVAssetReader(asset: asset)
        output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: decodeW,
            kCVPixelBufferHeightKey as String: decodeH,
        ])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        reader.startReading()
        pending = output.copyNextSampleBuffer()
    }

    /// Frame untuk waktu sumber [t] (detik). Rotasi (preferredTransform) sudah diterapkan.
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
        ctx.concatenate(CGAffineTransform(translationX: -bounds.minX, y: -bounds.minY).concatenating(.identity))
        ctx.concatenate(transform)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage() ?? image
    }
}

// Resolusi penuh (tanpa diperkecil saat decode) agar tetap tajam ketika kamera zoom.
let mac = FrameSource(path: macPath, maxWidth: 4000)
let phone = FrameSource(path: phonePath, maxWidth: 2400)

// Sinkron: waktu mulai tiap perekam (+ geser manual untuk HP).
let macStart = macStartMs / 1000
let phoneStart = phoneStartMs / 1000 + nudge
let commonStart = max(macStart, phoneStart)
// Rekaman Android hanya berisi frame saat layar berubah: sesudah frame terakhirnya, layar tablet
// dianggap diam (frame terakhir ditahan), jadi akhir video mengikuti rekaman Mac.
let commonEnd = macStart + mac.duration
let macOffset = commonStart - macStart       // detik ke-0 video hasil = detik ini di rekaman Mac
let phoneOffset = commonStart - phoneStart
var startT = 0.0
var length = max(0.5, commonEnd - commonStart)
if let trim, trim.count == 2 { startT = trim[0]; length = max(0.5, min(trim[1], length) - trim[0]) }
print(String(format: "Sinkron: Mac +%.2f dtk, HP +%.2f dtk · panjang %.1f dtk", macOffset, phoneOffset, length))

// MARK: - Warna & latar (sama dengan website: kabut biru di atas, memudar)

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}
let BG = LIGHT ? rgb(0xF5F6FB) : rgb(0x050609)
let GLOWS: [UInt32] = LIGHT ? [0x2563EB, 0x60A5FA, 0x1E40AF] : [0x1D4ED8, 0x1E40AF, 0x172554]
let GLOW_ALPHA: CGFloat = LIGHT ? 0.32 : 0.55
let BEZEL = LIGHT ? rgb(0x0D1020) : rgb(0x16181F)
let RIM = LIGHT ? rgb(0xFFFFFF, 0.8) : rgb(0xFFFFFF, 0.1)
let BASE = LIGHT ? rgb(0xCDD0DA) : rgb(0x2B2E38)
let BASE_EDGE = LIGHT ? rgb(0xA9ADBB) : rgb(0x1C1E26)
let space = CGColorSpace(name: CGColorSpace.sRGB)!

func makeContext() -> CGContext {
    CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0, space: space,
              bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
}

/// Latar statis (dibuat sekali): warna dasar + tiga cahaya buram + memudar ke bawah.
let background: CGImage = {
    let ctx = makeContext()
    ctx.setFillColor(BG)
    ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
    if PLAIN { return ctx.makeImage()! }
    let v = CGFloat(max(W, H)) / 100
    // (pusat x, pusat y dari atas, jari-jari) mengikuti .sky-blob web
    let blobs: [(CGFloat, CGFloat, CGFloat, CGFloat)] = [(8 * v, 0, 26 * v, 1), (CGFloat(W), 18 * v, 26 * v, 1),
                                                          (30 * v + 19 * v, 12 * v + 19 * v, 19 * v, 0.7)]
    for (i, b) in blobs.enumerated() {
        let r = b.2, sigma = r * 0.3, outer = r + 3 * sigma
        let stops: [CGFloat] = [0, (r - 2 * sigma) / outer, (r - sigma) / outer, r / outer, (r + sigma) / outer, (r + 2 * sigma) / outer, 1]
        let levels: [CGFloat] = [1, 0.977, 0.84, 0.5, 0.16, 0.023, 0]
        let colors = levels.map { rgb(GLOWS[i], GLOW_ALPHA * b.3 * $0) } as CFArray
        let gradient = CGGradient(colorsSpace: space, colors: colors, locations: stops)!
        let center = CGPoint(x: b.0, y: CGFloat(H) - b.1)
        ctx.drawRadialGradient(gradient, startCenter: center, startRadius: 0, endCenter: center, endRadius: outer, options: [])
    }
    let fade = CGGradient(colorsSpace: space, colors: [BG.copy(alpha: 0)!, BG] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(fade, start: CGPoint(x: 0, y: CGFloat(H) * 0.6), end: CGPoint(x: 0, y: 0), options: [.drawsAfterEndLocation])
    return ctx.makeImage()!
}()

// MARK: - Tata letak: layar Mac besar (terpotong di sisi luar) + HP/tablet di sisi tempat kursor menyeberang

let macAspect = mac.size.width / mac.size.height
let phoneAspect = phone.size.width / phone.size.height
let gap: CGFloat = 28
let margin: CGFloat = 34
let centerY = CGFloat(H) / 2 + 6
let phoneW: CGFloat
let phoneH: CGFloat
let macW: CGFloat
let macH: CGFloat
if WIDE {
    // Ukuran fisik: tinggi layar Mac ≈ 1,47× tinggi layar dalam Fold; keduanya muat utuh.
    let marginX = CGFloat(W) * 0.07, marginY = CGFloat(H) * 0.08
    let byWidth = (CGFloat(W) - 2 * marginX - gap) / (1.47 * macAspect + phoneAspect)
    let byHeight = (CGFloat(H) - 2 * marginY - 24) / 1.47
    phoneH = min(byWidth, byHeight)
    phoneW = phoneH * phoneAspect
    macH = phoneH * 1.47
    macW = macH * macAspect
} else {
    // HP/tablet: lebar ±40% kanvas (landscape) atau lebih ramping (portrait); Mac terpotong di sisi luar.
    phoneW = phoneAspect >= 1 ? 430 : 300
    phoneH = phoneW / phoneAspect
    macH = phoneH * 1.47
    macW = macH * macAspect
}
let groupW = macW + gap + phoneW
let phoneX = WIDE
    ? (phoneOnLeft ? (CGFloat(W) - groupW) / 2 : (CGFloat(W) + groupW) / 2 - phoneW)
    : (phoneOnLeft ? margin : CGFloat(W) - margin - phoneW)
let macX = phoneOnLeft ? phoneX + phoneW + gap : phoneX - gap - macW
let macRect = CGRect(x: macX, y: centerY - macH / 2, width: macW, height: macH)
let phoneRect = CGRect(x: phoneX, y: centerY - phoneH / 2, width: phoneW, height: phoneH)
/// Titik sambungan (tempat kursor berpindah) — fokus zoom.
let seam = CGPoint(x: phoneOnLeft ? phoneRect.maxX + gap / 2 : macRect.maxX + gap / 2, y: centerY)

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

/// Alas MacBook: lebih lebar dari layar, cukup tebal, sudut bawah membulat, ceruk jari di tengah atas.
func drawLaptopBase(_ ctx: CGContext) {
    let bezel: CGFloat = 12
    let top = macRect.minY - bezel                  // tepi bawah bingkai layar
    let height = max(14, macRect.height * 0.045)
    let overhang = macRect.width * 0.075
    let base = CGRect(x: macRect.minX - bezel - overhang, y: top - height,
                      width: macRect.width + 2 * (bezel + overhang), height: height)
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
    // Garis engsel tipis & ceruk jari.
    ctx.setFillColor(BASE_EDGE)
    ctx.fill(CGRect(x: base.minX, y: base.maxY - 2, width: base.width, height: 2))
    let notch = CGRect(x: macRect.midX - macRect.width * 0.08, y: base.maxY - height * 0.42,
                       width: macRect.width * 0.16, height: height * 0.42)
    ctx.addPath(CGPath(roundedRect: notch, cornerWidth: height * 0.3, cornerHeight: height * 0.3, transform: nil))
    ctx.fillPath()
}

func smooth(_ x: Double) -> Double { let t = min(max(x, 0), 1); return t * t * (3 - 2 * t) }

/// Titik fokus zoom di kanvas.
/// Titik fokus. "px:XxY" = titik di layar tablet dalam piksel (mis. sel yang sedang diketik).
func focusPoint(_ name: String) -> CGPoint {
    if name.hasPrefix("px:") {
        let v = name.dropFirst(3).split(separator: "x").compactMap { Double($0) }
        if v.count == 2 {
            return CGPoint(x: phoneRect.minX + CGFloat(v[0]) / phone.size.width * phoneRect.width,
                           y: phoneRect.maxY - CGFloat(v[1]) / phone.size.height * phoneRect.height)
        }
    }
    switch name {
    case "phone": return CGPoint(x: phoneRect.midX, y: phoneRect.midY)
    case "phone-top": return CGPoint(x: phoneRect.midX, y: phoneRect.maxY - phoneRect.height * 0.25)
    case "mac": return CGPoint(x: macRect.midX, y: macRect.midY)
    default: return seam
    }
}

/// Kamera: diam (skala 1) kecuali pada rentang --zoom: masuk/keluar halus 0,6 dtk ke titik fokusnya.
/// Fokus sambungan: kedua perangkat tetap utuh (zoom kecil). Fokus tablet/piksel: zoom lebih dekat,
/// tablet tetap utuh secara vertikal (layar Mac boleh keluar bingkai).
/// @return (skala, titik fokus, fokus-ke-tablet?)
func camera(_ t: Double) -> (CGFloat, CGPoint, Bool) {
    var best = 0.0
    var focus = seam
    var onTablet = false
    for (a, b, name) in zoomRanges {
        let w = smooth((t - (a - startT)) / 0.6) * (1 - smooth((t - (b - startT)) / 0.6))
        if w > best {
            best = w
            focus = focusPoint(name)
            onTablet = name.hasPrefix("phone") || name.hasPrefix("px:")
        }
    }
    let amount: CGFloat = onTablet
        ? min(name0Amount(focus), (CGFloat(H) - 24) / (phoneRect.height + 18))
        : min(1.35, max(1, (CGFloat(H) - 24) / groupHeight))
    return (1 + (amount - 1) * CGFloat(best), focus, onTablet)
}

/// Zoom ke tablet: lebih dekat untuk titik spesifik (sel/bilah alamat) daripada seluruh tablet.
func name0Amount(_ focus: CGPoint) -> CGFloat {
    focus == CGPoint(x: phoneRect.midX, y: phoneRect.midY) ? 1.45 : 1.8
}

/// Tinggi gabungan perangkat (layar Mac + alas, tablet) — dasar batas zoom & geser vertikal.
let groupTop = max(macRect.maxY + 12, phoneRect.maxY + 9)
let groupBottom = min(macRect.minY - 12 - max(14, macRect.height * 0.045), phoneRect.minY - 9)
let groupHeight = groupTop - groupBottom

func render(_ t: Double, into ctx: CGContext) {
    ctx.draw(background, in: CGRect(x: 0, y: 0, width: W, height: H))
    let (z, focus, onTablet) = camera(t)
    ctx.saveGState()
    // Fokus digeser ke tengah kanvas sebanding dengan zoom, agar objek yang di-zoom tidak keluar bingkai.
    let center = CGPoint(x: CGFloat(W) / 2, y: CGFloat(H) / 2)
    let pull = (z - 1) / max(z, 1)
    var shiftY = (center.y - focus.y) * pull
    // Jaga perangkat tetap di dalam bingkai secara vertikal.
    // Batas vertikal: kedua perangkat (fokus sambungan) atau tablet saja (fokus tablet).
    let keepTop = onTablet ? phoneRect.maxY + 9 : groupTop
    let keepBottom = onTablet ? phoneRect.minY - 9 : groupBottom
    let top = (keepTop - focus.y) * z + focus.y + shiftY
    let bottom = (keepBottom - focus.y) * z + focus.y + shiftY
    if top > CGFloat(H) - 12 { shiftY -= top - (CGFloat(H) - 12) }
    if bottom < 12 { shiftY += 12 - bottom }
    ctx.translateBy(x: (center.x - focus.x) * pull, y: shiftY)
    ctx.translateBy(x: focus.x, y: focus.y)
    ctx.scaleBy(x: z, y: z)
    ctx.translateBy(x: -focus.x, y: -focus.y)
    drawLaptopBase(ctx)
    let source = startT + t
    drawScreen(ctx, image: mac.frame(at: source + macOffset), in: macRect, bezel: 12, radius: 10)
    /// Layar HP + penutup (bila waktu `time` ada di rentang --mask).
    func drawPhone(_ image: CGImage?, at time: Double) {
        drawScreen(ctx, image: image, in: phoneRect, bezel: 9, radius: 16)
        guard let (area, a, b) = maskSpec, time >= a, time <= b else { return }
        let sx = phoneRect.width / phone.size.width, sy = phoneRect.height / phone.size.height
        let side = min(area.width, area.height) * 0.62
        let center = CGPoint(x: phoneRect.minX + area.midX * sx, y: phoneRect.maxY - area.midY * sy)
        let circle = CGRect(x: center.x - side * sx / 2, y: center.y - side * sy / 2, width: side * sx, height: side * sy)
        ctx.setFillColor(rgb(0x5F6368))
        ctx.fillEllipse(in: circle)
    }
    if let i = xfades.firstIndex(where: { source >= $0.0 && source < $0.1 }) {
        let (a, b) = xfades[i]
        if xfadeFrames[i] == nil {
            let first = phone.frame(at: source + phoneOffset)
            xfadeFrames[i] = (first, phone.frame(at: b + phoneOffset))
        }
        let (first, last) = xfadeFrames[i]!
        let u = (source - a) / (b - a)
        drawPhone(first, at: a)
        // Gambar + penutup jadi satu lapisan dulu, baru dibuat transparan: bila tidak, foto profil di bawah
        // penutup ikut tembus (penutup sendiri juga transparan).
        ctx.saveGState()
        ctx.setAlpha(CGFloat(u * u * (3 - 2 * u)))
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        drawPhone(last, at: b)
        ctx.endTransparencyLayer()
        ctx.restoreGState()
    } else {
        drawPhone(phone.frame(at: source + phoneOffset), at: source)
    }
    ctx.restoreGState()
    // Sisi luar Mac yang terpotong memudar ke latar (hanya tata letak persegi).
    guard !WIDE else { return }
    let fadeW: CGFloat = 150
    let outerX: CGFloat = phoneOnLeft ? CGFloat(W) : 0
    let fade = CGGradient(colorsSpace: space, colors: [BG, BG.copy(alpha: 0)!] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(fade, start: CGPoint(x: outerX, y: 0),
                           end: CGPoint(x: phoneOnLeft ? outerX - fadeW : fadeW, y: 0), options: [])
}

// MARK: - Keluaran

if let posterAt {
    // Lompat ke waktu poster (frame dibaca berurutan sampai sana).
    let ctx = makeContext()
    var t = 0.0
    while t < posterAt { _ = mac.frame(at: startT + t + macOffset); _ = phone.frame(at: startT + t + phoneOffset); t += 0.5 }
    render(posterAt, into: ctx)
    let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: outPath) as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, ctx.makeImage()!, [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
    CGImageDestinationFinalize(dest)
    print("Poster: \(outPath)")
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

let frames = Int(length * Double(FPS))
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
    if i % (FPS * 5) == 0 { print("  \(i / FPS)/\(Int(length)) dtk") }
}
input.markAsFinished()
let done = DispatchSemaphore(value: 0)
writer.finishWriting { done.signal() }
done.wait()
print(writer.status == .completed ? "Selesai: \(outPath)" : "Gagal: \(writer.error?.localizedDescription ?? "?")")
