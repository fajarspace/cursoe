import AppKit

/// Logo Cursoe di app Mac. Geometri di BrandGeometry.swift (dibuat scripts/brand/make-logo.py) —
/// sama persis dengan website & Android.
enum BrandIcon {
    /// Gambar simbol (tanpa latar) ke `ctx` berkoordinat 64×64, y ke bawah.
    static func drawMark(in ctx: CGContext, color: CGColor, weight: CGFloat = 1) {
        BrandGeometry.draw(in: ctx, color: color, weight: weight)
    }

    /// Ikon menu bar (template: otomatis putih/hitam mengikuti menu bar). Simbol diskalakan & dipusatkan
    /// berdasarkan batas bentuknya.
    static func menuBarImage(size: CGFloat = 18) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: true) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            let b = BrandGeometry.bounds.insetBy(dx: -0.4, dy: -0.4)
            let content = max(b.width, b.height)
            ctx.scaleBy(x: rect.width / content, y: rect.height / content)
            ctx.translateBy(x: -b.minX + (content - b.width) / 2, y: -b.minY + (content - b.height) / 2)
            drawMark(in: ctx, color: NSColor.black.cgColor, weight: 1.08)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Cursoe"
        return image
    }
}
