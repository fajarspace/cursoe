import AppKit

// Titik masuk aplikasi menu bar. Tidak ada jendela dan tidak ada ikon Dock
// (LSUIElement=true di Info.plist; .accessory untuk saat dijalankan via `swift run`).
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
