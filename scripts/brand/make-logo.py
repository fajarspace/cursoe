#!/usr/bin/env python3
"""Satu sumber geometri logo Cursoe → semua berkas logo (web, favicon, Android, Mac).

    python3 scripts/brand/make-logo.py

Logo: huruf "C" tebal (cincin dengan ujung bulat, celah di kanan) dan kursor klasik yang menyatu di
tengahnya. Dihitung, bukan dikira-kira:
  - tangkai kursor mengikuti sumbu tangkai kursor klasik (±66°), selebar "C", dan berakhir TEPAT di
    titik ujung bawah "C" → sambungan berupa lekukan bulat yang mulus;
  - lekukan kepala kursor = perpotongan sisi tangkai dengan sisi bawah kepala (kepala & tangkai menyatu);
  - ujung kursor diberi jarak aman dari tepi dalam "C";
  - seluruh bentuk dipusatkan di kotak 64×64 berdasarkan batas bentuknya.
Warna polos blue-800 (#1E40AF), tanpa gradasi.

Berkas yang ditulis:
  web/src/components/logoGeometry.ts      konstanta path untuk komponen Logo
  web/public/favicon.svg, web/public/brand/cursoe-mark.svg
  android/.../drawable/ic_launcher_foreground.xml, ic_stat_cursoe.xml
  mac/Sources/cursoe/BrandGeometry.swift  (dipakai BrandIcon.swift; salinannya disisipkan ke make-icon.swift & DemoVideo.swift)
"""
import math
import os

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
BLUE = "#1E40AF"

# Parameter desain (satuan kotak 64×64)
R = 16.5          # jari-jari tengah garis "C"
W = 5.4           # tebal garis "C" & tangkai kursor
TOP = -40.0       # sudut ujung atas "C" (derajat, sumbu y ke bawah)
END = 62.0        # sudut ujung bawah "C" (tempat tangkai menyatu)
HEAD_SCALE = 1.28 # skala kepala kursor klasik (tinggi ±21,8)
TIP_GAP = 3.2     # jarak ujung kursor ke tepi dalam "C"
HEAD_ROUND = 1.2  # pembulatan sudut kepala (lebar garis tepi)


def unit(v):
    length = math.hypot(*v)
    return (v[0] / length, v[1] / length)


def add(a, b, s=1.0):
    return (a[0] + s * b[0], a[1] + s * b[1])


def intersect(p, d, q, e):
    """Titik potong garis p + t·d dan q + u·e."""
    den = d[0] * e[1] - d[1] * e[0]
    t = ((q[0] - p[0]) * e[1] - (q[1] - p[1]) * e[0]) / den
    return add(p, d, t)


def polar(r, deg):
    a = math.radians(deg)
    return (r * math.cos(a), r * math.sin(a))


def build():
    # Kepala kursor klasik (tanpa tangkai) dan sumbu tangkainya, dalam satuan kursor 17 tinggi.
    BL, NL, NR, RC = (0, 17), (4.3, 13.1), (7.1, 11.9), (12.4, 11.9)
    notch_cursor = ((NL[0] + NR[0]) / 2, (NL[1] + NR[1]) / 2)
    axis = unit((3.0, 6.8))  # sumbu tangkai kursor klasik

    end = polar(R, END)  # ujung bawah "C" (pusat lingkaran di 0,0)
    inner = R - W / 2
    # Panjang tangkai dipilih agar ujung kursor berjarak TIP_GAP dari tepi dalam "C".
    best = None
    for i in range(2000):
        length = 2 + i * 0.01
        notch = add(end, axis, -length)
        tip = (notch[0] - HEAD_SCALE * notch_cursor[0], notch[1] - HEAD_SCALE * notch_cursor[1])
        margin = inner - math.hypot(*tip)
        if best is None or abs(margin - TIP_GAP) < abs(best[0] - TIP_GAP):
            best = (margin, notch, tip)
    _, notch, tip = best

    def P(p):
        return (tip[0] + HEAD_SCALE * p[0], tip[1] + HEAD_SCALE * p[1])

    bl, nl0, nr0, rc = P(BL), P(NL), P(NR), P(RC)
    normal = (-axis[1], axis[0])
    nl = intersect(add(notch, normal, -W / 2), axis, bl, (nl0[0] - bl[0], nl0[1] - bl[1]))
    nr = intersect(add(notch, normal, W / 2), axis, nr0, (rc[0] - nr0[0], rc[1] - nr0[1]))
    head = [P((0, 0)), bl, nl, nr, rc]
    stem_start = add(notch, axis, -2.0)  # sedikit di dalam kepala

    # Batas bentuk → geser agar berpusat di (32, 32).
    sweep = (TOP - END) % 360  # derajat, berlawanan arah jarum jam dari TOP
    pts = [polar(R + W / 2, TOP - s) for s in range(0, int(sweep) + 1)]
    for deg in (TOP, END):
        c = polar(R, deg)
        pts += [add(c, polar(W / 2, a)) for a in range(0, 360, 10)]
    pts += head
    xs, ys = [p[0] for p in pts], [p[1] for p in pts]
    off = (32 - (min(xs) + max(xs)) / 2, 32 - (min(ys) + max(ys)) / 2)

    def S(p):
        return (round(p[0] + off[0], 2), round(p[1] + off[1], 2))

    return {
        "center": S((0, 0)),
        "start": S(polar(R, TOP)),
        "end": S(end),
        "sweep": round(sweep, 4),  # sudut busur yang digambar dari TOP, lewat atas & kiri (258°)
        "stem": [S(stem_start), S(end)],
        "head": [S(p) for p in head],
        "bbox": [round(min(xs) + off[0], 2), round(min(ys) + off[1], 2),
                 round(max(xs) + off[0], 2), round(max(ys) + off[1], 2)],
    }


def svg_paths(g, sep=" ", comma=" "):
    a0, a1 = g["start"], g["end"]
    f = lambda p: f"{p[0]}{comma}{p[1]}"
    ring = f"M{f(a0)}{sep}A{R}{comma}{R} 0 1{comma}0 {f(a1)}"
    stem = f"M{f(g['stem'][0])}{sep}L{f(a1)}"
    head = "M" + sep.join(("" if i == 0 else "L") + f(p) for i, p in enumerate(g["head"])) + " Z"
    return ring, stem, head


def write(rel, text):
    path = os.path.join(ROOT, rel)
    # Website ada di repo terpisah (opsional, di-checkout ke web/): lewati bila tidak ada.
    if rel.startswith("web/") and not os.path.isdir(os.path.join(ROOT, "web")):
        print("– lewati", rel, "(web/ tidak ada)")
        return
    with open(path, "w") as fh:
        fh.write(text)
    print("✓", rel)


def main():
    g = build()
    ring, stem, head = svg_paths(g)

    write("web/src/components/logoGeometry.ts", f"""// Dibuat oleh scripts/brand/make-logo.py — jangan diedit manual.
/** Geometri logo Cursoe (kotak 64×64): "C" + kursor yang menyatu di tengahnya. */
export const LOGO_BLUE = '{BLUE.lower()}'
export const LOGO_STROKE = {W}
export const LOGO_HEAD_ROUND = {HEAD_ROUND}
export const LOGO_RING = '{ring}'
export const LOGO_STEM = '{stem}'
export const LOGO_HEAD = '{head}'
""")

    mark = f"""<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64">
  <rect width="64" height="64" rx="15" fill="{BLUE.lower()}"/>
  <path d="{ring}" fill="none" stroke="#fff" stroke-width="{W}" stroke-linecap="round"/>
  <path d="{stem}" fill="none" stroke="#fff" stroke-width="{W}" stroke-linecap="round"/>
  <path d="{head}" fill="#fff" stroke="#fff" stroke-width="{HEAD_ROUND}" stroke-linejoin="round"/>
</svg>
"""
    write("web/public/favicon.svg", mark)
    write("web/public/brand/cursoe-mark.svg", mark)

    aring, astem, ahead = svg_paths(g, sep=" ", comma=",")

    def vector_paths(color, weight=1.0):
        return f"""        <path
            android:fillColor="#00000000"
            android:pathData="{aring}"
            android:strokeColor="{color}"
            android:strokeLineCap="round"
            android:strokeWidth="{round(W * weight, 2)}" />
        <path
            android:fillColor="#00000000"
            android:pathData="{astem}"
            android:strokeColor="{color}"
            android:strokeLineCap="round"
            android:strokeWidth="{round(W * weight, 2)}" />
        <path
            android:fillColor="{color}"
            android:pathData="{ahead}"
            android:strokeColor="{color}"
            android:strokeLineJoin="round"
            android:strokeWidth="{HEAD_ROUND}" />"""

    bw, bh = g["bbox"][2] - g["bbox"][0], g["bbox"][3] - g["bbox"][1]
    launcher_scale = 1.15  # zona aman ikon adaptif 108dp
    write("android/app/src/main/res/drawable/ic_launcher_foreground.xml", f"""<?xml version="1.0" encoding="utf-8"?>
<!-- Dibuat oleh scripts/brand/make-logo.py. Ikon adaptif 108dp: simbol Cursoe di zona aman, berpusat. -->
<vector xmlns:android="http://schemas.android.com/apk/res/android"
    android:width="108dp"
    android:height="108dp"
    android:viewportWidth="108"
    android:viewportHeight="108">
    <group
        android:scaleX="{launcher_scale}"
        android:scaleY="{launcher_scale}"
        android:translateX="{round(54 - 32 * launcher_scale, 2)}"
        android:translateY="{round(54 - 32 * launcher_scale, 2)}">
{vector_paths("#FFFFFF")}
    </group>
</vector>
""")
    stat_scale = round(60 / max(bw, bh), 3)
    write("android/app/src/main/res/drawable/ic_stat_cursoe.xml", f"""<?xml version="1.0" encoding="utf-8"?>
<!-- Dibuat oleh scripts/brand/make-logo.py. Ikon notifikasi & tile (monokrom): simbol Cursoe, berpusat. -->
<vector xmlns:android="http://schemas.android.com/apk/res/android"
    android:width="24dp"
    android:height="24dp"
    android:viewportWidth="64"
    android:viewportHeight="64">
    <group
        android:scaleX="{stat_scale}"
        android:scaleY="{stat_scale}"
        android:translateX="{round(32 - 32 * stat_scale, 2)}"
        android:translateY="{round(32 - 32 * stat_scale, 2)}">
{vector_paths("#FFFFFFFF", 1.08)}
    </group>
</vector>
""")

    pts = lambda ps: ", ".join(f"CGPoint(x: {x}, y: {y})" for x, y in ps)
    write("mac/Sources/cursoe/BrandGeometry.swift", f"""// Dibuat oleh scripts/brand/make-logo.py — jangan diedit manual.
import CoreGraphics

/// Geometri logo Cursoe (kotak 64×64, sumbu y ke bawah): "C" + kursor yang menyatu di tengahnya.
/// Sama persis dengan website (logoGeometry.ts) dan ikon Android.
enum BrandGeometry {{
    static let blue = (red: 0x1E, green: 0x40, blue: 0xAF)
    static let stroke: CGFloat = {W}
    static let headRound: CGFloat = {HEAD_ROUND}
    /// Pusat & jari-jari "C"; busur dari `startDegrees` memutar `sweepDegrees` berlawanan arah jarum jam
    /// (lewat atas & kiri) sampai ujung bawah.
    static let center = CGPoint(x: {g['center'][0]}, y: {g['center'][1]})
    static let radius: CGFloat = {R}
    static let startDegrees: CGFloat = {TOP}
    static let sweepDegrees: CGFloat = {g['sweep']}
    static let stem = [{pts(g['stem'])}]
    static let head = [{pts(g['head'])}]
    /// Batas bentuk (untuk memusatkan di ikon kecil): minX, minY, maxX, maxY.
    static let bounds = CGRect(x: {g['bbox'][0]}, y: {g['bbox'][1]}, width: {round(bw, 2)}, height: {round(bh, 2)})

    static func ringPath() -> CGPath {{
        let path = CGMutablePath()
        let steps = 180
        for i in 0...steps {{
            let degrees = startDegrees - sweepDegrees * CGFloat(i) / CGFloat(steps)
            let a = degrees * .pi / 180
            let p = CGPoint(x: center.x + radius * cos(a), y: center.y + radius * sin(a))
            if i == 0 {{ path.move(to: p) }} else {{ path.addLine(to: p) }}
        }}
        return path
    }}

    static func stemPath() -> CGPath {{
        let path = CGMutablePath()
        path.addLines(between: stem)
        return path
    }}

    static func headPath() -> CGPath {{
        let path = CGMutablePath()
        path.addLines(between: head)
        path.closeSubpath()
        return path
    }}

    /// Gambar simbol (tanpa latar) ke `ctx` berkoordinat 64×64, y ke bawah.
    static func draw(in ctx: CGContext, color: CGColor, weight: CGFloat = 1) {{
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
    }}
}}
""")
    # Skrip Swift satu-file (make-icon.swift, DemoVideo.swift) tidak bisa mengimpor BrandGeometry.swift:
    # sisipkan salinan geometri di antara penanda BEGIN/END GEOMETRY.
    geometry = open(os.path.join(ROOT, "mac/Sources/cursoe/BrandGeometry.swift")).read().split("import CoreGraphics\n", 1)[1]
    begin, finish = "// BEGIN GEOMETRY (make-logo.py)\n", "// END GEOMETRY\n"
    for rel in ("mac/make-icon.swift", "scripts/demo-video/DemoVideo.swift"):
        path = os.path.join(ROOT, rel)
        text = open(path).read()
        head_part, rest = text.split(begin, 1)
        _, tail_part = rest.split(finish, 1)
        with open(path, "w") as fh:
            fh.write(head_part + begin + geometry.lstrip("\n") + finish + tail_part)
        print(f"✓ {rel} (geometri disisipkan)")
    print("batas bentuk:", g["bbox"])


if __name__ == "__main__":
    main()
