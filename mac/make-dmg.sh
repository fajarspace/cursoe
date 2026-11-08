#!/usr/bin/env bash
# Bungkus Cursoe.app jadi DMG dengan ikon disk Cursoe (mac/Resources/DiskIcon.icns, dibuat make-icon.swift).
#   mac/make-dmg.sh <Cursoe.app> <keluaran.dmg>
#
# Ikon dipasang di dua tempat:
#   1. Volume (.VolumeIcon.icns + flag "custom icon" di akar volume) → tampil saat DMG dibuka:
#      di desktop, sidebar Finder, dan jendela DMG. Ikut di dalam isi DMG, jadi tetap ada setelah diunduh.
#   2. File .dmg itu sendiri (ikon kustom Finder). Catatan: ikon ini disimpan di atribut tambahan file,
#      yang TIDAK ikut terkirim lewat unduhan browser; file hasil unduhan tampil dengan ikon DMG bawaan macOS.
set -euo pipefail

APP="$1"
OUT="$2"
ICON="$(cd "$(dirname "$0")" && pwd)/Resources/DiskIcon.icns"
[[ -f "$ICON" ]] || { echo "Tidak ada $ICON — jalankan: swift mac/make-icon.swift" >&2; exit 1; }

WORK="$(mktemp -d)"
cleanup() {
    [[ -n "${MOUNT:-}" ]] && hdiutil detach -quiet "$MOUNT" 2>/dev/null || true
    rm -rf "$WORK"
}
trap cleanup EXIT

# Isi DMG: aplikasi, pintasan ke /Applications, dan ikon volume
mkdir "$WORK/stage"
cp -R "$APP" "$WORK/stage/"
ln -s /Applications "$WORK/stage/Applications"
cp "$ICON" "$WORK/stage/.VolumeIcon.icns"

# DMG sementara yang bisa ditulisi → pasang di folder sementara (tidak muncul di desktop) → set flag ikon
hdiutil create -quiet -volname "Cursoe" -srcfolder "$WORK/stage" -ov -format UDRW "$WORK/rw.dmg"
MOUNT="$WORK/mnt"
mkdir "$MOUNT"
hdiutil attach -quiet -readwrite -noverify -noautoopen -nobrowse -mountpoint "$MOUNT" "$WORK/rw.dmg"
# FinderInfo 32 byte; byte 8–9 = Finder flags, 0x0400 = kHasCustomIcon
xattr -wx com.apple.FinderInfo "0000000000000000040000000000000000000000000000000000000000000000" "$MOUNT"
hdiutil detach -quiet "$MOUNT"
MOUNT=""

# Kompres jadi DMG final (read-only)
rm -f "$OUT"
hdiutil convert -quiet "$WORK/rw.dmg" -format UDZO -imagekey zlib-level=9 -o "$OUT"

# Ikon kustom untuk file .dmg (lihat catatan di atas)
osascript -l JavaScript - "$ICON" "$OUT" >/dev/null <<'JXA'
function run(argv) {
  ObjC.import('AppKit')
  const image = $.NSImage.alloc.initWithContentsOfFile(argv[0])
  return $.NSWorkspace.sharedWorkspace.setIconForFileOptions(image, argv[1], 0)
}
JXA
