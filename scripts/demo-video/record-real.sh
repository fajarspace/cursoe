#!/usr/bin/env bash
# Demo NYATA bertahap: rekam layar Mac + tablet bersamaan sementara DemoDriver memperagakan:
#   kursor pindah ke tablet → klik Chrome → ketik "cursoe.app" ⏎ (keyboard Mac) → kembali ke Mac
#   → seret file Excel ke tablet → klik Sheets (file terbuka di tablet) → kembali ke Mac → seret foto
#   → panel "Buka dengan" muncul di tablet.
# Lalu digabung jadi video website (1920×900, latar polos warna halaman, gelap & terang) dengan zoom
# otomatis pada momen penting:
#   web/public/media/cursoe-real.mp4 / cursoe-real-light.mp4 (+ poster .jpg)
#
#   ./scripts/demo-video/record-real.sh                 # rekam + gabung
#   ./scripts/demo-video/record-real.sh --compose-only  # gabung ulang dari rekaman terakhir
#   ZOOM="…" TRIM=awal,akhir NUDGE=0.1 ./scripts/demo-video/record-real.sh --compose-only
#
# Syarat: Cursoe tersambung (Mac ↔ tablet), tablet tercolok adb dengan Chrome di taskbar, Terminal/VS Code
# punya izin Accessibility & Screen Recording. Jangan sentuh mouse/trackpad selama merekam (±18 detik).
# Rekaman mentah (berisi isi layar) disimpan di scripts/demo-video/real/ dan tidak di-commit.
set -euo pipefail
cd "$(dirname "$0")/../.."
[[ -d web/public ]] || { echo "Butuh repo website di web/ (hasil video ditulis ke web/public/media/)." >&2; exit 1; }

RAW="$PWD/scripts/demo-video/real"
OUT=web/public/media
SECS="${SECS:-32}"
SIDE="${SIDE:-right}"
PHOTO="$RAW/Pemandangan.jpg"
XLSX="$RAW/Laporan Penjualan.xlsx"
XLSX_MIME=application/vnd.openxmlformats-officedocument.spreadsheetml.sheet
mkdir -p "$RAW" "$OUT"
BIN="$(mktemp -d)"
swiftc -O -swift-version 5 scripts/demo-video/ComposeReal.swift -o "$BIN/ComposeReal"
now_ms() { python3 -c 'import time; print(int(time.time()*1000))'; }

if [[ "${1:-}" != "--compose-only" ]]; then
    swiftc -O -swift-version 5 scripts/demo-video/DemoDriver.swift -o "$BIN/DemoDriver"
    swiftc -O -swift-version 5 scripts/demo-video/DemoBackdrop.swift -o "$BIN/DemoBackdrop"
    adb get-state >/dev/null 2>&1 || { echo "Tablet tidak terhubung lewat adb." >&2; exit 1; }

    # Layar Mac tetap menyala tanpa screensaver selama skrip berjalan, lalu bangunkan sekarang.
    caffeinate -dimu -w $$ &
    "$BIN/DemoDriver" --wake

    echo "==> Menyiapkan target di tablet (posisi Chrome & bilah alamat)"
    dump() { adb shell uiautomator dump --windows /sdcard/cursoe-ui.xml >/dev/null 2>&1; adb shell cat /sdcard/cursoe-ui.xml; adb shell rm -f /sdcard/cursoe-ui.xml; }
    center() { grep -o "$1" | head -1 | grep -o 'bounds="[^"]*"' | python3 -c 'import re,sys; a,b,c,d=map(int,re.findall(r"\d+",sys.stdin.read())); print((a+c)//2,(b+d)//2)'; }
    # Halaman utama Cursoe di depan (tutup Pengaturan/panel Cursoe sisa percobaan sebelumnya).
    cursoe_home() {
        for _ in 1 2 3; do
            case "$(adb shell dumpsys activity activities | grep -m1 topResumedActivity)" in
                *dev.cursoe/.SettingsActivity*|*dev.cursoe/.files.OpenWithActivity*) adb shell input keyevent BACK; sleep 0.6 ;;
                *) break ;;
            esac
        done
        adb shell am start -n dev.cursoe/.MainActivity >/dev/null 2>&1
    }
    # Satu tab khusus demo (dipakai ulang lewat application_id) berisi halaman netral, agar
    # "buka cursoe.app" benar-benar terlihat berpindah halaman.
    adb shell am start -a android.intent.action.VIEW -d "https://www.wikipedia.org/" \
        --es com.android.browser.application_id dev.cursoe.demo -p com.android.chrome >/dev/null 2>&1
    sleep 3
    UI=$(dump)
    URL_XY=$(echo "$UI" | center '<node[^>]*com.android.chrome:id/url_bar[^>]*>')
    # Foto profil akun Google di toolbar Chrome: ditutup di video (privasi).
    AVATAR=$(echo "$UI" | grep -o '<node[^>]*com.android.chrome:id/avatar_button[^>]*>' | head -1 \
        | grep -o 'bounds="[^"]*"' | grep -o '[0-9]*' | tr '\n' ',' | sed 's/,$//' || true)
    echo "${AVATAR:-}" > "$RAW/avatar.txt"
    # Tablet mulai dari layar Home (wallpaper + ikon); Chrome dibuka dari ikonnya di Home.
    adb shell input keyevent KEYCODE_HOME
    sleep 1.5
    CHROME_XY=$(dump | center '<node[^>]*content-desc="Chrome"[^>]*>')
    # Posisi tombol "Sheets" di panel "Buka dengan" untuk .xlsx: panel uji (build debug) lalu ditutup.
    adb shell am broadcast -a dev.cursoe.debug.OPENWITH -p dev.cursoe --es name cursoe-uji.xlsx --es mime "$XLSX_MIME" >/dev/null
    sleep 1.8
    SHEETS_XY=$(dump | center '<node[^>]*text="Sheets"[^>]*package="dev.cursoe"[^>]*>')
    adb shell input keyevent BACK
    sleep 0.6
    adb shell "content delete --uri content://media/external/downloads --where \"_display_name LIKE 'cursoe-uji%'\"" || true
    adb shell input keyevent KEYCODE_HOME
    sleep 1
    SIZE_WH=$(adb shell wm size | tail -1 | grep -o '[0-9]*x[0-9]*')
    DENSITY=$(adb shell wm density | tail -1 | grep -o '[0-9]*$')
    SENS=$(defaults read dev.cursoe.mac sensitivity 2>/dev/null || echo 1)
    [ -n "$URL_XY" ] && [ -n "$CHROME_XY" ] && [ -n "$SHEETS_XY" ] || {
        echo "Chrome, bilah alamat, atau tombol Sheets tidak ditemukan di tablet." >&2; exit 1; }

    echo "==> Desktop Mac: wallpaper asli + file Excel & foto"
    rm -f "$RAW/mac.mov" "$RAW/phone.mp4" "$RAW"/*.start "$RAW/events.txt" # screencapture tidak mau menimpa
    python3 scripts/demo-video/make-xlsx.py "$XLSX" >/dev/null
    "$BIN/DemoBackdrop" --desktop "$RAW/tile.json" "$XLSX" "$PHOTO" &
    BACKDROP_PID=$!
    trap 'kill "$BACKDROP_PID" 2>/dev/null || true' EXIT
    sleep 1.5
    python3 - "$RAW" "$URL_XY" "$CHROME_XY" "$SHEETS_XY" "$SIZE_WH" "$DENSITY" "$SENS" <<'PY'
import json, sys
raw, url, chrome, sheets, size, density, sens = sys.argv[1:]
files = json.load(open(f"{raw}/tile.json"))["files"]
w, h = map(int, size.split("x"))
w, h = max(w, h), min(w, h)          # Fold terbuka dipakai mendatar
sx, sy = map(int, sheets.split())
json.dump({"files": files, "url": list(map(int, url.split())), "chrome": list(map(int, chrome.split())),
           "sheets": [sx, sy - 40],  # sedikit di atas label = ikon Sheets
           # Sel di Sheets (tata letak bawaan file contoh pada Fold terbuka mendatar):
           # C7 = unit Juni yang diketik; sel kosong A11 untuk menyimpan isian. Saat mengedit, bilah atas
           # Sheets menyusut dan grid naik ±4 baris, jadi A11 ada di y≈930 (bukan 1210).
           "cell": [1016, 934], "commit": [330, 930],
           "phone": [w, h], "k": float(sens) * int(density) / 160}, open(f"{raw}/target.json", "w"))
PY
    "$BIN/DemoDriver" --place 900 560

    echo "==> Merekam $SECS detik (jangan sentuh mouse/trackpad)"
    now_ms > "$RAW/phone.start"
    DISPLAY_ID=$(adb shell dumpsys display | grep -o 'uniqueId="local:[0-9]*".*, state ON,' | head -1 \
        | grep -o 'local:[0-9]*' | cut -d: -f2 || true)
    REC=(--bit-rate 24000000 --time-limit "$SECS")
    [ -n "$DISPLAY_ID" ] && REC+=(--display-id "$DISPLAY_ID")
    adb shell screenrecord "${REC[@]}" /sdcard/cursoe-rec.mp4 &
    PHONE_PID=$!
    now_ms > "$RAW/mac.start"
    screencapture -x -C -V "$SECS" -D 1 "$RAW/mac.mov" &
    MAC_PID=$!
    sleep 1.2
    now_ms > "$RAW/driver.start"
    "$BIN/DemoDriver" --story "$RAW/target.json" | tee "$RAW/events.txt"
    wait "$PHONE_PID" "$MAC_PID" # hanya perekam (jendela latar berjalan terus sampai di-kill)
    kill "$BACKDROP_PID" 2>/dev/null || true

    echo "==> Membersihkan tablet"
    adb pull /sdcard/cursoe-rec.mp4 "$RAW/phone.mp4" >/dev/null
    adb shell rm -f /sdcard/cursoe-rec.mp4
    adb shell input keyevent BACK >/dev/null 2>&1 || true     # tutup panel "Buka dengan"
    sleep 0.8
    # Tutup dokumen contoh di Sheets tanpa menyimpan perubahan demo ("No thanks").
    for _ in 1 2 3; do
        case "$(adb shell dumpsys activity activities | grep -m1 topResumedActivity)" in
            *RitzActivity*) ;;
            *) break ;;
        esac
        adb shell input keyevent BACK >/dev/null 2>&1 || true
        sleep 1.2
        NO_XY=$(dump | center '<node[^>]*text="No thanks"[^>]*>' 2>/dev/null || true)
        if [ -n "$NO_XY" ]; then adb shell input tap $NO_XY; sleep 1; break; fi
    done
    for name in Pemandangan "Laporan Penjualan"; do
        adb shell "content delete --uri content://media/external/downloads --where \"_display_name LIKE '$name%'\"" || true
    done
    adb shell input keyevent KEYCODE_HOME >/dev/null 2>&1 || true
fi

# Zoom & potongan otomatis dari momen yang dicatat DemoDriver (detik sejak sutradara mulai).
read -r ZOOM_AUTO TRIM_AUTO MASK_AUTO XFADE_AUTO < <(python3 - "$RAW" <<'PY'
import json, os, sys
raw = sys.argv[1]
url = json.load(open(f"{raw}/target.json"))["url"]
off = (int(open(f"{raw}/driver.start").read()) - int(open(f"{raw}/mac.start").read())) / 1000
ev = {}
for line in open(f"{raw}/events.txt"):
    p = line.split()
    if len(p) == 3 and p[0] == "EVENT": ev[p[1]] = float(p[2]) + off
z = []
if "cross" in ev: z.append(f"{ev['cross']-0.7:.2f}-{ev.get('chrome', ev['cross']+1)+0.5:.2f}@seam")
if "type" in ev: z.append(f"{ev['type']-0.5:.2f}-{ev.get('enter', ev['type']+1)+1.4:.2f}@px:{url[0]}x{url[1]}")
for name in ("xlsx", "photo"):
    d, p = ev.get(f"{name}-drag"), ev.get(f"{name}-drop")
    if d and p: z.append(f"{d+0.3:.2f}-{p+0.6:.2f}@seam")
if "xlsx-drop" in ev and "sheets" in ev: z.append(f"{ev['xlsx-drop']+1.0:.2f}-{ev['sheets']+0.4:.2f}@phone")
if "cell" in ev: z.append(f"{ev['cell']-0.4:.2f}-{ev.get('total', ev['cell']+2)+1.2:.2f}@px:1016x960")
if "photo-drop" in ev: z.append(f"{ev['photo-drop']+1.2:.2f}-{ev.get('end', ev['photo-drop']+3)-0.2:.2f}@phone")
start = max(0, ev.get("start", 0) - 0.4)
end = ev.get("end", start + 14) + 0.5
avatar = open(f"{raw}/avatar.txt").read().strip() if os.path.exists(f"{raw}/avatar.txt") else ""
mask = f"{avatar}@{ev['chrome']:.2f}-{ev.get('sheets', 999):.2f}" if avatar and "chrome" in ev else "-"
# Saat Chrome membesar dari ikon dan saat menyusut karena Sheets dibuka, jendelanya bergerak sehingga penutup
# (posisi tetap) tidak mengenai foto profil: tampilkan crossfade frame sebelum → sesudah animasi saja.
xf = []
if "chrome" in ev: xf.append(f"{ev['chrome']-0.35:.2f}-{ev['chrome']+0.25:.2f}")
if "sheets" in ev: xf.append(f"{ev['sheets']-0.05:.2f}-{ev['sheets']+0.8:.2f}")
print(",".join(z), f"{start:.2f},{end:.2f}", mask, ",".join(xf) or "-")
PY
)
ARGS=(--mac "$RAW/mac.mov" --phone "$RAW/phone.mp4" --mac-start "$(cat "$RAW/mac.start")"
      --phone-start "$(cat "$RAW/phone.start")" --side "$SIDE" --nudge "${NUDGE:-0}"
      --size "${SIZE:-1920x900}" --zoom "${ZOOM:-$ZOOM_AUTO}" --trim "${TRIM:-$TRIM_AUTO}")
[ "${PLAIN:-1}" = 1 ] && ARGS+=(--plain) # menyatu dengan latar halaman (hero lebar penuh)
[ "$MASK_AUTO" != "-" ] && ARGS+=(--mask "$MASK_AUTO") # tutup foto profil Google di Chrome
[ "$XFADE_AUTO" != "-" ] && ARGS+=(--xfade "$XFADE_AUTO") # lewati animasi Chrome (foto profil bergerak)
POSTER="${POSTER:-1}"
echo "==> Menggabungkan (gelap & terang) · zoom ${ZOOM:-$ZOOM_AUTO} · potong ${TRIM:-$TRIM_AUTO}"
"$BIN/ComposeReal" "${ARGS[@]}" "$OUT/cursoe-real.mp4"
"$BIN/ComposeReal" "${ARGS[@]}" --poster "$POSTER" "$OUT/cursoe-real.jpg"
"$BIN/ComposeReal" "${ARGS[@]}" --light "$OUT/cursoe-real-light.mp4"
"$BIN/ComposeReal" "${ARGS[@]}" --light --poster "$POSTER" "$OUT/cursoe-real-light.jpg"
echo "{ \"version\": \"$(date +%s)\" }" > web/src/media.json
echo "Selesai: $OUT/cursoe-real{,-light}.mp4"
