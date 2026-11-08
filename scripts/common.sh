# Dipakai dev.sh & prod.sh. Mengatur toolchain dan fungsi bantu.

# Toolchain default (Homebrew); dipakai bila belum diatur di shell.
export JAVA_HOME="${JAVA_HOME:-/opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home}"
export ANDROID_HOME="${ANDROID_HOME:-/opt/homebrew/share/android-commandlinetools}"
export PATH="$JAVA_HOME/bin:$PATH"

# Pasang APK ke HP yang tersambung lewat adb (USB/wireless). Dilewati bila tidak ada HP.
install_apk() {
    local apk="$1"
    if ! adb get-state >/dev/null 2>&1; then
        echo "⚠︎  HP tidak terdeteksi adb. Sambungkan HP (USB debugging) lalu jalankan:"
        echo "    adb install -r $apk"
        return 0
    fi
    echo "==> Memasang ke HP: $(basename "$apk")"
    adb install -r "$apk" | tail -1
    echo "    (layanan Cursoe di HP menyala sendiri bila Aksesibilitasnya aktif)"
}

stop_mac_app() {
    pkill -f '\.app/Contents/MacOS/cursoe' 2>/dev/null || true
    sleep 0.5
}

# Jalankan perintah tanpa output; tampilkan output hanya bila gagal.
quiet() {
    local log
    log="$(mktemp)"
    if ! "$@" >"$log" 2>&1; then
        cat "$log"
        rm -f "$log"
        return 1
    fi
    rm -f "$log"
}
