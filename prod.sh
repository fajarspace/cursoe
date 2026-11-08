#!/usr/bin/env bash
# MODE PROD: build release HP (tanpa alat debug) + pasang aplikasi Mac ke /Applications.
#   ./prod.sh            # keduanya
#   ./prod.sh mac        # hanya Mac
#   ./prod.sh android    # hanya HP
set -euo pipefail
cd "$(dirname "$0")"
source scripts/common.sh
TARGET="${1:-all}"

if [[ $TARGET == all || $TARGET == android ]]; then
    echo "==> HP: build release"
    (cd android && ./gradlew -q assembleRelease)
    install_apk android/app/build/outputs/apk/release/app-release.apk
fi

if [[ $TARGET == all || $TARGET == mac ]]; then
    echo "==> Mac: build release & pasang ke Applications"
    quiet mac/install.sh
fi

cat <<'EOF'

✓ Mode prod terpasang.
  • Mac: nyalakan menu Cursoe › "Buka saat login" (sekali saja).
  • HP : boleh matikan USB debugging (beberapa aplikasi bank menolaknya); nyalakan lagi saat update.
EOF
