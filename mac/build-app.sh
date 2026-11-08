#!/usr/bin/env bash
# Build binary dengan SwiftPM, bungkus jadi build/Cursoe.app (ikon: Resources/AppIcon.icns), lalu tanda tangani.
#
# Pemakaian:
#   ./build-app.sh            # build release
#   ./build-app.sh debug      # build debug
#
# Tanda tangan:
#   - Bila identitas "cursoe-dev" ada (dibuat oleh ./make-dev-cert.sh), itu yang dipakai,
#     sehingga izin Accessibility tidak hilang setiap rebuild.
#   - Selain itu: ad-hoc (codesign -s -).
#   - Bisa dipaksa: SIGN_IDENTITY="-" ./build-app.sh
set -euo pipefail

cd "$(dirname "$0")"

CONFIG="${1:-release}"
if [ -z "${SIGN_IDENTITY:-}" ]; then
    if security find-identity -v -p codesigning 2>/dev/null | grep -q '"cursoe-dev"'; then
        SIGN_IDENTITY="cursoe-dev"
    else
        SIGN_IDENTITY="-"
    fi
fi
BUNDLE_ID="dev.cursoe.mac"
APP_NAME="cursoe"   # nama executable (internal)
DISPLAY_NAME="Cursoe"
VERSION="1.0.0"
BUILD_NUMBER="2"

echo "==> swift build -c $CONFIG"
swift build -c "$CONFIG"
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"

APP="build/${DISPLAY_NAME}.app"
rm -rf "build/${APP_NAME}.app" # nama bundle lama (sebelum ganti nama ke Cursoe)
echo "==> Menyusun $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"
[ -f Resources/AppIcon.icns ] || swift make-icon.swift
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# Bahasa: English bawaan, Bahasa Indonesia (teks Info.plist yang diterjemahkan, mis. pesan izin Local Network).
cp -R Resources/en.lproj Resources/id.lproj "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleName</key>
    <string>${DISPLAY_NAME}</string>
    <key>CFBundleDisplayName</key>
    <string>${DISPLAY_NAME}</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleExecutable</key>
    <string>${APP_NAME}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${BUILD_NUMBER}</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSLocalNetworkUsageDescription</key>
    <string>Cursoe finds and connects to your Android device on the local network.</string>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleLocalizations</key>
    <array>
        <string>en</string>
        <string>id</string>
    </array>
    <key>NSBonjourServices</key>
    <array>
        <string>_cursoe._tcp</string>
    </array>
</dict>
</plist>
PLIST

echo "==> codesign (identity: $SIGN_IDENTITY)"
codesign --force --sign "$SIGN_IDENTITY" --identifier "$BUNDLE_ID" "$APP"
codesign --verify --verbose=1 "$APP"

echo "==> Selesai: $(pwd)/$APP"
echo "    Jalankan dengan: open $(pwd)/$APP"
