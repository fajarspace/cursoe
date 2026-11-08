#!/usr/bin/env python3
"""File Excel contoh untuk video demo: "Laporan Penjualan.xlsx" (tanpa dependency, hanya zipfile).

    python3 scripts/demo-video/make-xlsx.py <keluaran.xlsx>

Satu sheet "Penjualan": header tebal berlatar biru, enam bulan data, baris total dengan rumus SUM.
"""
import sys
import zipfile
from xml.sax.saxutils import escape

ROWS = [
    ("Januari", "Cursoe Pro", 128, 38_400_000),
    ("Februari", "Cursoe Pro", 152, 45_600_000),
    ("Maret", "Cursoe Pro", 175, 52_500_000),
    ("April", "Cursoe Pro", 198, 59_400_000),
    ("Mei", "Cursoe Pro", 231, 69_300_000),
    ("Juni", "Cursoe Pro", 264, 79_200_000),
]
HEADER = ("Bulan", "Produk", "Unit", "Pendapatan (Rp)")


def cell_text(ref, text, style=0):
    return f'<c r="{ref}" t="inlineStr" s="{style}"><is><t>{escape(text)}</t></is></c>'


def cell_num(ref, value, style=0):
    return f'<c r="{ref}" s="{style}"><v>{value}</v></c>'


def sheet_xml():
    rows = ['<row r="1">' + "".join(cell_text(f"{c}1", h, 1) for c, h in zip("ABCD", HEADER)) + "</row>"]
    for i, (month, product, units, revenue) in enumerate(ROWS, start=2):
        rows.append(
            f'<row r="{i}">{cell_text(f"A{i}", month)}{cell_text(f"B{i}", product)}'
            f'{cell_num(f"C{i}", units, 2)}{cell_num(f"D{i}", revenue, 2)}</row>'
        )
    last = len(ROWS) + 1
    total = last + 1
    rows.append(
        f'<row r="{total}">{cell_text(f"A{total}", "Total", 3)}{cell_text(f"B{total}", "", 3)}'
        f'<c r="C{total}" s="4"><f>SUM(C2:C{last})</f><v>{sum(r[2] for r in ROWS)}</v></c>'
        f'<c r="D{total}" s="4"><f>SUM(D2:D{last})</f><v>{sum(r[3] for r in ROWS)}</v></c></row>'
    )
    return (
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">'
        '<cols><col min="1" max="1" width="14" customWidth="1"/><col min="2" max="2" width="16" customWidth="1"/>'
        '<col min="3" max="3" width="10" customWidth="1"/><col min="4" max="4" width="20" customWidth="1"/></cols>'
        f'<sheetData>{"".join(rows)}</sheetData></worksheet>'
    )


STYLES = (
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
    '<styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">'
    '<numFmts count="1"><numFmt numFmtId="164" formatCode="#,##0"/></numFmts>'
    '<fonts count="3"><font><sz val="11"/><name val="Calibri"/></font>'
    '<font><b/><sz val="11"/><color rgb="FFFFFFFF"/><name val="Calibri"/></font>'
    '<font><b/><sz val="11"/><name val="Calibri"/></font></fonts>'
    '<fills count="3"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill>'
    '<fill><patternFill patternType="solid"><fgColor rgb="FF1E40AF"/><bgColor indexed="64"/></patternFill></fill></fills>'
    '<borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders>'
    '<cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>'
    '<cellXfs count="5">'
    '<xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/>'
    '<xf numFmtId="0" fontId="1" fillId="2" borderId="0" xfId="0" applyFont="1" applyFill="1"/>'
    '<xf numFmtId="164" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/>'
    '<xf numFmtId="0" fontId="2" fillId="0" borderId="0" xfId="0" applyFont="1"/>'
    '<xf numFmtId="164" fontId="2" fillId="0" borderId="0" xfId="0" applyFont="1" applyNumberFormat="1"/>'
    "</cellXfs></styleSheet>"
)

FILES = {
    "[Content_Types].xml": (
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
        '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
        '<Default Extension="xml" ContentType="application/xml"/>'
        '<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>'
        '<Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>'
        '<Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>'
        "</Types>"
    ),
    "_rels/.rels": (
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
        '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>'
        "</Relationships>"
    ),
    "xl/workbook.xml": (
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" '
        'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">'
        '<sheets><sheet name="Penjualan" sheetId="1" r:id="rId1"/></sheets></workbook>'
    ),
    "xl/_rels/workbook.xml.rels": (
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
        '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>'
        '<Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>'
        "</Relationships>"
    ),
    "xl/styles.xml": STYLES,
}

if __name__ == "__main__":
    out = sys.argv[1] if len(sys.argv) > 1 else "Laporan Penjualan.xlsx"
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
        for name, data in FILES.items():
            z.writestr(name, data)
        z.writestr("xl/worksheets/sheet1.xml", sheet_xml())
    print(out)
