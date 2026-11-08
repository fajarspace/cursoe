#!/usr/bin/env bash
# RILIS: build file .dmg dan .apk untuk GitHub Release.
#   ./release.sh
#
# Hasil (tidak di-commit; diunggah sebagai aset GitHub Release):
#   dist/release/Cursoe-<versi>.dmg   (Mac: seret ke Applications)
#   dist/release/Cursoe-<versi>.apk   (HP: buka & pasang)
# Bila repo website di-checkout ke web/, file juga disalin ke web/public/downloads/ dan
# web/src/release.json (versi, ukuran & SHA-256) ditulis untuk ditampilkan di website.
#
# Catatan: aplikasi Mac ditandatangani "cursoe-dev" (bila ada) tetapi TIDAK dinotarisasi Apple,
# dan APK ditandatangani kunci debug. Keduanya bisa dipasang, tetapi sistem akan meminta konfirmasi sekali.
set -euo pipefail
cd "$(dirname "$0")"
source scripts/common.sh

VERSION="$(sed -n 's/^VERSION="\(.*\)"$/\1/p' mac/build-app.sh)"
ANDROID_VERSION="$(sed -n 's/.*versionName = "\(.*\)".*/\1/p' android/app/build.gradle.kts)"
if [[ "$VERSION" != "$ANDROID_VERSION" ]]; then
    echo "⚠︎  Versi beda: Mac $VERSION, Android $ANDROID_VERSION. Samakan dulu sebelum rilis." >&2
    exit 1
fi

OUT="dist/release"
DMG="Cursoe-$VERSION.dmg"
APK="Cursoe-$VERSION.apk"
mkdir -p "$OUT"
rm -f "$OUT"/Cursoe-*.dmg "$OUT"/Cursoe-*.apk

echo "==> HP: build APK release"
(cd android && ./gradlew -q assembleRelease)
cp android/app/build/outputs/apk/release/app-release.apk "$OUT/$APK"

echo "==> Mac: build aplikasi"
quiet mac/build-app.sh

echo "==> Mac: bungkus jadi DMG (dengan ikon disk Cursoe)"
mac/make-dmg.sh mac/build/Cursoe.app "$OUT/$DMG"

sha() { shasum -a 256 "$1" | cut -d' ' -f1; }
size() { stat -f%z "$1"; }

if [[ -d web/src ]]; then
    mkdir -p web/public/downloads
    rm -f web/public/downloads/Cursoe-*.dmg web/public/downloads/Cursoe-*.apk
    cp "$OUT/$DMG" "$OUT/$APK" web/public/downloads/
    cat > web/src/release.json <<JSON
{
  "version": "$VERSION",
  "mac": { "file": "$DMG", "size": $(size "$OUT/$DMG"), "sha256": "$(sha "$OUT/$DMG")" },
  "android": { "file": "$APK", "size": $(size "$OUT/$APK"), "sha256": "$(sha "$OUT/$APK")" }
}
JSON
fi

cat <<EOF

✓ Rilis $VERSION siap:
  $(du -h "$OUT/$DMG" | cut -f1)	$OUT/$DMG
  $(du -h "$OUT/$APK" | cut -f1)	$OUT/$APK
  Terbitkan di GitHub:  gh release create v$VERSION "$OUT/$DMG" "$OUT/$APK"
  Website (bila ada di web/): commit web/src/release.json lalu deploy; tombol unduh menunjuk ke release v$VERSION.
EOF
