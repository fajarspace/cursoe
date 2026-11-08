import AppKit

/// Menyembunyikan/menampilkan kursor Mac dan melepas/menyambung kursor dari mouse.
enum CursorControl {
    /// Penanda (eventSourceUserData) untuk event yang diposting Cursoe sendiri.
    static let syntheticTag: Int64 = 0x6762_7262 // "gbrb"

    /// Berapa kali CGDisplayHideCursor dipanggil (harus diimbangi CGDisplayShowCursor).
    private static var hideCount = 0
    private static var backgroundEnabled = false

    static func detachAndHide() {
        enableBackgroundCursorControl()
        CGAssociateMouseAndMouseCursorPosition(0)
        if hideCount == 0 {
            CGDisplayHideCursor(CGMainDisplayID())
            hideCount = 1
        }
    }

    /// Aplikasi lain menjadi aktif saat mode remote (kursor bisa tampil lagi): sembunyikan ulang.
    static func reHide() {
        guard hideCount > 0 else { return }
        CGDisplayHideCursor(CGMainDisplayID())
        hideCount += 1
    }

    /// Sumber event untuk memindah kursor tanpa "suppression interval": setelah warp/post biasa,
    /// macOS menahan event mouse lokal ±0,25 detik sehingga kursor terasa nyangkut.
    private static let eventSource: CGEventSource? = {
        let source = CGEventSource(stateID: .combinedSessionState)
        source?.localEventsSuppressionInterval = 0
        return source
    }()

    static func attachAndShow(warpTo point: CGPoint? = nil) {
        CGAssociateMouseAndMouseCursorPosition(1)
        if let point {
            // Pindahkan kursor dengan memposting mouseMoved (dari sumber tanpa jeda), bukan
            // CGWarpMouseCursorPosition yang memicu jeda tahan event.
            if let move = CGEvent(mouseEventSource: eventSource, mouseType: .mouseMoved,
                                  mouseCursorPosition: point, mouseButton: .left) {
                move.setIntegerValueField(.eventSourceUserData, value: syntheticTag)
                move.post(tap: .cghidEventTap)
            } else {
                CGWarpMouseCursorPosition(point)
                CGAssociateMouseAndMouseCursorPosition(1)
            }
        }
        while hideCount > 0 {
            CGDisplayShowCursor(CGMainDisplayID())
            hideCount -= 1
        }
    }

    /// Posisi kursor sekarang (koordinat global, origin kiri-atas) dan batas layarnya.
    static func location() -> (point: CGPoint, display: CGRect) {
        let point = CGEvent(source: nil)?.location ?? .zero
        var display: CGDirectDisplayID = 0
        var count: UInt32 = 0
        CGGetDisplaysWithPoint(point, 1, &display, &count)
        return (point, CGDisplayBounds(count > 0 ? display : CGMainDisplayID()))
    }

    /// macOS hanya mengizinkan aplikasi yang sedang aktif (frontmost) menyembunyikan kursor.
    /// Cursoe berjalan di latar belakang, jadi kita pakai properti koneksi WindowServer
    /// "SetsCursorInBackground" (API privat yang juga dipakai Synergy/Deskflow).
    /// Bila simbolnya tidak ada, kursor tetap terlihat tetapi diam (tidak berbahaya).
    private static func enableBackgroundCursorControl() {
        guard !backgroundEnabled else { return }
        backgroundEnabled = true
        guard let handle = dlopen(nil, RTLD_LAZY),
              let connectionSymbol = dlsym(handle, "_CGSDefaultConnection") ?? dlsym(handle, "CGSMainConnectionID"),
              let setPropertySymbol = dlsym(handle, "CGSSetConnectionProperty") else {
            Log.info("SetsCursorInBackground tidak tersedia; kursor Mac mungkin tetap terlihat")
            return
        }
        typealias ConnectionFn = @convention(c) () -> Int32
        typealias SetPropertyFn = @convention(c) (Int32, Int32, CFString, CFTypeRef) -> Int32
        let connection = unsafeBitCast(connectionSymbol, to: ConnectionFn.self)()
        let result = unsafeBitCast(setPropertySymbol, to: SetPropertyFn.self)(
            connection, connection, "SetsCursorInBackground" as CFString, kCFBooleanTrue)
        Log.info("SetsCursorInBackground: \(result == 0 ? "aktif" : "gagal (\(result))")")
    }
}

/// Hotkey sistem macOS (diproses SEBELUM event tap). Selama mode remote, ⌘⇥ dll. harus
/// dinonaktifkan agar tidak memunculkan app switcher Mac (yang juga memunculkan kursor Mac).
/// API privat CGSSetSymbolicHotKeyEnabled — dipakai juga oleh AltTab.
enum SystemHotkeys {
    // CGSSymbolicHotKey: 1 = ⌘⇥, 2 = ⌘⇧⇥, 6 = ⌘` (ganti jendela)
    private static let appSwitcherKeys: [Int32] = [1, 2, 6]

    private typealias SetEnabledFn = @convention(c) (Int32, Bool) -> Int32
    private static let setEnabled: SetEnabledFn? = {
        guard let handle = dlopen(nil, RTLD_LAZY),
              let symbol = dlsym(handle, "CGSSetSymbolicHotKeyEnabled") else {
            Log.info("CGSSetSymbolicHotKeyEnabled tidak tersedia; ⌘⇥ tetap memunculkan app switcher Mac")
            return nil
        }
        return unsafeBitCast(symbol, to: SetEnabledFn.self)
    }()

    static func setAppSwitcherEnabled(_ enabled: Bool) {
        guard let setEnabled else { return }
        for key in appSwitcherKeys { _ = setEnabled(key, enabled) }
    }
}
