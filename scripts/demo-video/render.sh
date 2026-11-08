#!/usr/bin/env bash
# Render klip animasi "Cara kerja" untuk website, versi gelap & terang:
#   web/public/media/step-{1,2,3}[-light].mp4     (+ .jpg poster)  — 1200×900, 6 detik
# (DemoVideo tanpa --step merender animasi demo lama 1080×1080; tidak dipakai website lagi.)
#   web/src/media.json                             — versi media (penanda cache untuk website)
#
#   ./scripts/demo-video/render.sh
#   ./scripts/demo-video/render.sh --stills 0.5,3.4,6.6 /tmp/stills [--light]   # cek beberapa frame saja
set -euo pipefail
cd "$(dirname "$0")/../.."
[[ -d web/public ]] || { echo "Butuh repo website di web/ (hasil video ditulis ke web/public/media/)." >&2; exit 1; }

BIN="$(mktemp -d)/DemoVideo"
swiftc -O -swift-version 5 scripts/demo-video/DemoVideo.swift -o "$BIN"

if [[ "${1:-}" == "--stills" ]]; then
    "$BIN" "$@"
else
    OUT=web/public/media
    mkdir -p "$OUT"
    for n in 1 2 3; do
        "$BIN" --step "$n" "$OUT/step-$n.mp4"
        "$BIN" --step "$n" --poster 2 "$OUT/step-$n.jpg"
        "$BIN" --step "$n" --light "$OUT/step-$n-light.mp4"
        "$BIN" --step "$n" --light --poster 2 "$OUT/step-$n-light.jpg"
    done
    # Versi media untuk website (?v=…): browser tidak memutar video lama dari cache.
    echo "{ \"version\": \"$(date +%s)\" }" > web/src/media.json
fi
