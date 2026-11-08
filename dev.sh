#!/usr/bin/env bash
# MODE DEV: build debug HP + aplikasi Mac dari mac/build/, lalu jalankan.
#   ./dev.sh            # keduanya
#   ./dev.sh mac        # hanya Mac
#   ./dev.sh android    # hanya HP
set -euo pipefail
cd "$(dirname "$0")"
source scripts/common.sh
TARGET="${1:-all}"

if [[ $TARGET == all || $TARGET == android ]]; then
    echo "==> HP: build debug"
    (cd android && ./gradlew -q assembleDebug)
    install_apk android/app/build/outputs/apk/debug/app-debug.apk
fi

if [[ $TARGET == all || $TARGET == mac ]]; then
    echo "==> Mac: build & jalankan dari mac/build/"
    quiet mac/build-app.sh
    stop_mac_app
    open mac/build/Cursoe.app
fi

cat <<'EOF'

✓ Mode dev berjalan. Lihat log:
  Mac : log stream --info --predicate 'subsystem == "dev.cursoe.mac"'
  HP  : adb logcat -s Cursoe CursoeDbg
EOF
