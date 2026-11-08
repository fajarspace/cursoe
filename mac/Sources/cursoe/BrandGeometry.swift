// Dibuat oleh scripts/brand/make-logo.py — jangan diedit manual.
import CoreGraphics

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
