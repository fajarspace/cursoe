#!/usr/bin/env bash
# Build lalu pasang Cursoe.app ke /Applications (atau ~/Applications bila tidak bisa ditulis),
# kemudian jalankan. Izin Accessibility tetap berlaku bila ditandatangani "cursoe-dev".
set -euo pipefail
cd "$(dirname "$0")"

./build-app.sh

TARGET_DIR="/Applications"
[ -w "$TARGET_DIR" ] || TARGET_DIR="$HOME/Applications"
mkdir -p "$TARGET_DIR"

echo "==> Menghentikan Cursoe yang sedang berjalan (bila ada)"
pkill -f '\.app/Contents/MacOS/cursoe' 2>/dev/null || true
sleep 0.5

echo "==> Memasang ke $TARGET_DIR/Cursoe.app"
rm -rf "$TARGET_DIR/Cursoe.app"
cp -R build/Cursoe.app "$TARGET_DIR/"

open "$TARGET_DIR/Cursoe.app"
echo "Selesai. Nyalakan \"Buka saat login\" dari menu Cursoe agar otomatis berjalan."
