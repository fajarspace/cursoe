// "Sutradara" demo nyata: menggerakkan kursor & keyboard Mac (event sintetis) selama perekaman.
//
//   DemoDriver --wake                         geser kursor sedikit (bangunkan layar), cek layar terkunci
//   DemoDriver --place x y                    taruh kursor di titik awal
//   DemoDriver --story target.json            alur demo bertahap (±22 detik):
//      kursor ke tepi → pindah ke tablet → klik Chrome → klik bilah alamat → ketik "cursoe.app" ⏎
//      → kembali ke Mac → seret file Excel ke tablet → klik Sheets di panel "Buka dengan" (file
//      terbuka) → kembali ke Mac → seret foto → panel "Buka dengan" muncul di tablet.
//
// Posisi kursor di tablet dihitung persis seperti Cursoe: masuk di tepi kiri sesudah dorongan 24 pt,
// lalu setiap 1 pt gerak Mac = sensitivitas × density px. Momen penting dicetak "EVENT nama detik"
// (dipakai untuk zoom otomatis). Butuh izin Accessibility; jangan sentuh mouse selama berjalan.
import CoreGraphics
import Foundation

let display = CGDisplayBounds(CGMainDisplayID())
let source = CGEventSource(stateID: .hidSystemState)
let hz = 120.0
let started = Date()

func emit(_ name: String) {
    print(String(format: "EVENT %@ %.3f", name, Date().timeIntervalSince(started)))
    fflush(stdout)
}

func clamp(_ p: CGPoint) -> CGPoint {
    CGPoint(x: min(max(p.x, display.minX), display.maxX - 1), y: min(max(p.y, display.minY), display.maxY - 1))
}

// MARK: - Model posisi (Mac & tablet)

var virtual = CGEvent(source: nil)?.location ?? CGPoint(x: display.midX, y: display.midY)
var button = false               // tombol kiri ditahan (drag)
var onPhone = false
var phone = CGPoint.zero         // posisi kursor di tablet (px)
var phoneSize = CGSize(width: 2160, height: 1856)
var k = 2.49                     // px tablet per pt Mac
var push = 0.0
var lastPush = Date.distantPast
/// (Tidak dipakai lagi: sisa dorongan sesudah menyeberang ikut diteruskan Cursoe ke tablet.)
var swallow = false

/// Sisa pecahan delta: macOS menyimpan delta event sebagai bilangan bulat, jadi pecahan dibawa ke
/// langkah berikutnya (tanpa ini gerakan lambat "hilang" hingga ±35% di tablet).
var carryX = 0.0
var carryY = 0.0

/// Satu gerakan: lokasi (dibatasi ke layar Mac) + delta bulat (dipakai Cursoe saat kursor di tablet).
func post(dx rawX: Double, dy rawY: Double) {
    let wantX = rawX + carryX, wantY = rawY + carryY
    let dx = wantX.rounded(), dy = wantY.rounded()
    carryX = wantX - dx
    carryY = wantY - dy
    virtual.x += dx
    virtual.y += dy
    let location = clamp(virtual)
    let type: CGEventType = button ? .leftMouseDragged : .mouseMoved
    guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: location, mouseButton: .left)
    else { return }
    event.setIntegerValueField(.mouseEventDeltaX, value: Int64(dx.rounded()))
    event.setIntegerValueField(.mouseEventDeltaY, value: Int64(dy.rounded()))
    event.setDoubleValueField(.mouseEventDeltaX, value: dx)
    event.setDoubleValueField(.mouseEventDeltaY, value: dy)
    event.post(tap: .cghidEventTap)
    if !swallow { track(dx: dx, dy: dy, location: location) }
}

/// Cerminan logika Cursoe: dorongan ≥ 24 pt di tepi (dalam 0,35 dtk) = pindah perangkat.
func track(dx: Double, dy: Double, location: CGPoint) {
    let now = Date()
    if !onPhone {
        let atEdge = location.x >= display.maxX - 1.5 && dx > 0 && !button
        guard atEdge else { push = 0; return }
        if now.timeIntervalSince(lastPush) > 0.35 { push = 0 }
        lastPush = now
        push += dx
        if push >= 24 {
            push = 0
            onPhone = true
            phone = CGPoint(x: 0, y: (location.y - display.minY) / display.height * (phoneSize.height - 1))
            emit("cross")
        }
    } else {
        phone.x = min(max(phone.x + dx * k, 0), phoneSize.width - 1)
        phone.y = min(max(phone.y + dy * k, 0), phoneSize.height - 1)
        if phone.x <= 0.5 && dx < 0 {
            if now.timeIntervalSince(lastPush) > 0.35 { push = 0 }
            lastPush = now
            push += -dx * (k / 2.625) // ambang di HP memakai delta sesudah sensitivitas
            if push >= 24 { push = 0; onPhone = false; emit("back") }
        } else {
            push = 0
        }
    }
}

func ease(_ t: Double) -> Double { t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2 }

func glide(dx: Double, dy: Double, seconds: Double) {
    let steps = max(1, Int(seconds * hz))
    var done = 0.0
    for i in 1...steps {
        let target = ease(Double(i) / Double(steps))
        let step = target - done
        done = target
        post(dx: dx * step, dy: dy * step)
        Thread.sleep(forTimeInterval: 1 / hz)
    }
    swallow = false
}

func glide(to point: CGPoint, seconds: Double) {
    glide(dx: point.x - virtual.x, dy: point.y - virtual.y, seconds: seconds)
}

/// Gerak ke titik di layar tablet (px), memakai delta Mac.
func glideOnPhone(to target: CGPoint, seconds: Double) {
    glide(dx: (target.x - phone.x) / k, dy: (target.y - phone.y) / k, seconds: seconds)
}

/// Dari tepi kiri tablet (sesudah menyeberang) meluncur ke [target] sambil "menambatkan" ke tepi bawah:
/// gerak vertikal dilebihkan sehingga y tertahan di dasar layar (posisi pasti), x tepat ke target.
func glideToBottom(x targetX: Double, seconds: Double) {
    let dy = (phoneSize.height - phone.y) / k + 120
    glide(dx: (targetX - phone.x) / k, dy: dy, seconds: seconds)
    phone.y = phoneSize.height - 1
}

/// Jalankan adb (sinkron) dan kembalikan stdout.
func adb(_ arguments: [String]) -> String {
    let process = Process()
    let candidates = ["/opt/homebrew/bin/adb", "/usr/local/bin/adb", "\(NSHomeDirectory())/Library/Android/sdk/platform-tools/adb"]
    process.executableURL = URL(fileURLWithPath: candidates.first { FileManager.default.isExecutableFile(atPath: $0) } ?? "/usr/bin/false")
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = Pipe()
    try? process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return String(data: data, encoding: .utf8) ?? ""
}

/// Posisi kursor sebenarnya di tablet (build debug Cursoe: broadcast WHERE → logcat).
func phoneWhere() -> CGPoint? {
    let nonce = String(Int.random(in: 100_000...999_999))
    _ = adb(["shell", "am", "broadcast", "-a", "dev.cursoe.debug.WHERE", "-p", "dev.cursoe", "--es", "n", nonce])
    for _ in 0..<8 {
        for line in adb(["logcat", "-d", "-s", "Cursoe"]).split(separator: "\n") where line.contains("WHERE \(nonce) ") {
            let parts = line.split(separator: " ").map(String.init)
            if let i = parts.firstIndex(of: nonce), i + 2 < parts.count, let x = Double(parts[i + 1]), let y = Double(parts[i + 2]) {
                return CGPoint(x: x, y: y)
            }
        }
        wait(0.04)
    }
    return nil
}

/// Koreksi sebelum klik: tanya posisi asli, geser sisa jaraknya (maks. 2 kali).
func settle(on target: CGPoint) {
    for _ in 0..<2 {
        guard let actual = phoneWhere() else { return }
        phone = actual
        let ex = target.x - actual.x, ey = target.y - actual.y
        if abs(ex) < 12 && abs(ey) < 12 { return }
        glide(dx: ex / k, dy: ey / k, seconds: 0.16)
    }
}

func mouse(_ down: Bool) {
    button = down
    let type: CGEventType = down ? .leftMouseDown : .leftMouseUp
    CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: clamp(virtual), mouseButton: .left)?
        .post(tap: .cghidEventTap)
}

func click() {
    mouse(true)
    wait(0.07)
    mouse(false)
}

/// Kode tombol US untuk huruf yang dipakai.
let keyCodes: [Character: CGKeyCode] = [
    "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13,
    "e": 14, "r": 15, "y": 16, "t": 17, "o": 31, "u": 32, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45,
    "m": 46, ".": 47, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "9": 25, "7": 26, "8": 28, "0": 29,
]

func key(_ code: CGKeyCode) {
    CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true)?.post(tap: .cghidEventTap)
    wait(0.03)
    CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false)?.post(tap: .cghidEventTap)
}

func type(_ text: String, perKey: Double) {
    for ch in text { if let code = keyCodes[ch] { key(code) }; wait(perKey) }
}

func wait(_ seconds: Double) { Thread.sleep(forTimeInterval: seconds) }

func syncToRealCursor() { virtual = CGEvent(source: nil)?.location ?? virtual }

// MARK: - Perintah

let args = Array(CommandLine.arguments.dropFirst())

if args.first == "--wake" {
    glide(dx: 24, dy: 0, seconds: 0.25)
    glide(dx: -24, dy: 0, seconds: 0.25)
    wait(1.0)
    // Layar terkunci: jangan rekam (dan tidak mencoba membukanya).
    if let session = CGSessionCopyCurrentDictionary() as? [String: Any],
       session["CGSSessionScreenIsLocked"] as? Bool == true {
        print("Layar Mac terkunci. Buka kunci dulu, lalu jalankan lagi.")
        exit(3)
    }
    exit(0)
}

if args.first == "--place", args.count >= 3, let x = Double(args[1]), let y = Double(args[2]) {
    glide(to: CGPoint(x: x, y: y), seconds: 0.3)
    exit(0)
}

// Ukur pemetaan gerak Mac → tablet (pakai WHERE): menyeberang, beberapa gerakan, cetak faktor px/pt.
if args.first == "--measure" {
    glide(to: CGPoint(x: display.maxX - 2, y: display.minY + display.height * 0.55), seconds: 0.6)
    glide(dx: 34, dy: 0, seconds: 0.22)
    wait(0.3)
    guard var last = phoneWhere() else { print("WHERE gagal"); exit(1) }
    print("masuk:", Int(last.x), Int(last.y))
    let moves: [(Double, Double, Double)] = [(300, 0, 0.7), (0, 200, 0.5), (200, -150, 0.3), (-150, -120, 0.9), (400, 0, 0.25)]
    for (dx, dy, sec) in moves {
        glide(dx: dx, dy: dy, seconds: sec)
        wait(0.25)
        guard let p = phoneWhere() else { break }
        let kx = dx != 0 ? (p.x - last.x) / dx : 0, ky = dy != 0 ? (p.y - last.y) / dy : 0
        print(String(format: "gerak (%4.0f,%4.0f) dalam %.2f dtk → Δ(%5.0f,%5.0f) px  kx=%.3f ky=%.3f", dx, dy, sec, p.x - last.x, p.y - last.y, kx, ky))
        last = p
    }
    glide(dx: -(last.x / 2.0 + 80), dy: 0, seconds: 0.8) // kembali ke Mac
    exit(0)
}

// Uji ketik di tablet: --type-test x y teks  (menyeberang, klik (x, y) px, ketik teks ⏎, kembali ke Mac)
if args.first == "--type-test", args.count >= 4, let tx = Double(args[1]), let ty = Double(args[2]) {
    glide(to: CGPoint(x: display.maxX - 2, y: display.minY + display.height * 0.55), seconds: 0.6)
    glide(dx: 34, dy: 0, seconds: 0.22)
    wait(0.2)
    glideOnPhone(to: CGPoint(x: tx, y: ty), seconds: 0.6)
    wait(0.15)
    click()
    wait(0.6)
    type(args[3], perKey: 0.09)
    wait(0.15)
    key(36)
    wait(0.8)
    glide(dx: -(phone.x / k + 60), dy: 0, seconds: 0.6)
    exit(0)
}

// Gerak mentah (mis. membawa kursor kembali ke Mac): --raw dx dy detik
if args.first == "--raw", args.count >= 4, let dx = Double(args[1]), let dy = Double(args[2]), let sec = Double(args[3]) {
    glide(dx: dx, dy: dy, seconds: sec)
    exit(0)
}

// Kalibrasi: menyeberang, tambatkan ke dasar layar tablet, lalu meluncur ke (x, y) px dan berhenti.
if args.first == "--calib", args.count >= 4, let tx = Double(args[1]), let ty = Double(args[2]) {
    k = Double(args[3]) ?? k
    glide(to: CGPoint(x: display.maxX - 2, y: display.minY + display.height * 0.55), seconds: 0.6)
    glide(dx: 34, dy: 0, seconds: 0.22)
    wait(0.15)
    glideToBottom(x: 300, seconds: 0.6)
    wait(0.1)
    glideOnPhone(to: CGPoint(x: tx, y: ty), seconds: 0.75)
    print("model:", Int(phone.x), Int(phone.y))
    exit(0)
}

guard args.first == "--story", args.count >= 2,
      let data = FileManager.default.contents(atPath: args[1]),
      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let files = json["files"] as? [[Double]], files.count >= 2,
      let chrome = json["chrome"] as? [Double], let urlBar = json["url"] as? [Double],
      let sheets = json["sheets"] as? [Double], let cell = json["cell"] as? [Double],
      let commit = json["commit"] as? [Double], let size = json["phone"] as? [Double],
      let factor = json["k"] as? Double else {
    print("Pakai: DemoDriver --story target.json  (files [[xlsx],[foto]], chrome, url, sheets, phone [w,h], k)")
    exit(2)
}
phoneSize = CGSize(width: size[0], height: size[1])
k = factor
let xlsx = CGPoint(x: files[0][0], y: files[0][1])
let photo = CGPoint(x: files[1][0], y: files[1][1])

/// Seret file di desktop Mac ke tepi kanan (blur Cursoe), lepas → Cursoe membawa kursor ke tablet.
func dragToTablet(from point: CGPoint, name: String) {
    glide(to: point, seconds: 0.7)
    wait(0.1)
    emit("\(name)-drag")
    mouse(true)
    wait(0.1)
    glide(to: CGPoint(x: display.maxX - 45, y: point.y - 20), seconds: 0.95)
    glide(dx: 6, dy: 4, seconds: 0.3) // sedikit bergoyang di atas area lepas agar terdeteksi
    wait(0.12)
    mouse(false)
    emit("\(name)-drop")
    onPhone = true
    phone = CGPoint(x: 0, y: (clamp(virtual).y - display.minY) / display.height * (phoneSize.height - 1))
}

/// Dari tablet kembali ke Mac: tempuh balik ke tepi kiri + dorongan.
func backToMac() {
    glide(dx: -(phone.x / k + 60), dy: 0, seconds: 0.6)
    wait(0.15)
    syncToRealCursor()
}

emit("start")
// 1. Dari tengah Mac meluncur ke tepi kanan, terus mendorong → pindah ke tablet (masuk ±55% tinggi).
glide(to: CGPoint(x: display.maxX - 2, y: display.minY + display.height * 0.55), seconds: 0.8)
glide(dx: 34, dy: 0, seconds: 0.22)
wait(0.12)
// 2. Klik Chrome di tablet.
glideOnPhone(to: CGPoint(x: chrome[0], y: chrome[1]), seconds: 0.7)
wait(0.1)
emit("chrome")
click()
wait(1.05)
// 3. Klik bilah alamat, ketik cursoe.app ⏎ dengan keyboard Mac.
glideOnPhone(to: CGPoint(x: urlBar[0], y: urlBar[1]), seconds: 0.6)
wait(0.1)
click()
wait(0.45)
emit("type")
type("cursoe.app", perKey: 0.07)
wait(0.12)
key(36) // Return
emit("enter")
wait(0.5)
glideOnPhone(to: CGPoint(x: phoneSize.width * 0.55, y: phoneSize.height * 0.55), seconds: 0.7)
wait(0.6)
// 4. Kembali ke Mac, seret file Excel ke tablet → panel "Buka dengan" → klik Sheets → file terbuka.
backToMac()
dragToTablet(from: xlsx, name: "xlsx")
wait(1.1)
glideOnPhone(to: CGPoint(x: sheets[0], y: sheets[1]), seconds: 0.6)
wait(0.12)
emit("sheets")
click()
wait(2.2)
// Ketik di Sheets dengan keyboard Mac: unit Juni 264 → 300, klik sel kosong untuk menyimpan isian;
// Total (rumus SUM) ikut berubah.
glideOnPhone(to: CGPoint(x: cell[0], y: cell[1]), seconds: 0.55)
wait(0.12)
emit("cell")
click()
wait(0.45)
type("300", perKey: 0.16)
wait(0.35)
glideOnPhone(to: CGPoint(x: commit[0], y: commit[1]), seconds: 0.45)
click()
emit("total")
wait(0.7)
// Keluar dari mode isian (Esc di Mac = Back di tablet), agar keyboard HP tidak muncul saat kursor pergi.
key(53)
wait(0.8)
// 5. Kembali ke Mac, seret foto → panel "Buka dengan" muncul di tablet.
backToMac()
dragToTablet(from: photo, name: "photo")
wait(0.9)
glideOnPhone(to: CGPoint(x: phoneSize.width * 0.42, y: phoneSize.height * 0.5), seconds: 0.7)
wait(1.6)
emit("end")
