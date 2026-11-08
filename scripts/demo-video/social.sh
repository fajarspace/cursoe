#!/usr/bin/env bash
# Video demo untuk media sosial (Threads/Instagram) dari rekaman nyata terakhir (record-real.sh):
#   ./scripts/demo-video/social.sh                    → dist/social/cursoe-social.mp4 + sampul .jpg (4:5, 1080×1350)
#   SIZE=1080x1920 ./scripts/demo-video/social.sh     → format 9:16
#   POSTER=12.5 ./scripts/demo-video/social.sh --stills   → hanya satu frame (cek tata letak)
set -euo pipefail
cd "$(dirname "$0")/../.."
RAW=scripts/demo-video/real
[[ -f $RAW/mac.mov && -f $RAW/events.txt ]] || { echo "Belum ada rekaman: jalankan record-real.sh dulu." >&2; exit 1; }

BIN="$(mktemp -d)"
swiftc -O -swift-version 5 scripts/demo-video/ComposeSocial.swift -o "$BIN/ComposeSocial"
OUT=dist/social
mkdir -p "$OUT"
ARGS=(--size "${SIZE:-1080x1350}")
# Logo penutup: gambar pratinjau website (latar biru yang sama). Tanpa repo website: nama "Cursoe" saja.
[[ -f web/public/og-image.png ]] && ARGS+=(--og web/public/og-image.png)

if [[ "${1:-}" == "--stills" ]]; then
    "$BIN/ComposeSocial" "${ARGS[@]}" --poster "${POSTER:-1}" "$RAW" "$OUT/still-${POSTER:-1}.jpg"
    exit 0
fi
"$BIN/ComposeSocial" "${ARGS[@]}" "$RAW" "$OUT/cursoe-social.mp4"
"$BIN/ComposeSocial" "${ARGS[@]}" --poster 1.2 "$RAW" "$OUT/cursoe-social.jpg"
