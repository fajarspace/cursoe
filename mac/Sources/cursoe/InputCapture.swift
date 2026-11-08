import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// Satu event scroll macOS. phase: 1 began, 2 changed, 4 ended, 8 cancelled, 128 may-begin.
/// momentumPhase: 0 none, 1 begin, 2 continue, 3 end (inersia setelah jari diangkat).
struct ScrollSample {
    let dx: Double
    let dy: Double
    let phase: Int64
    let momentumPhase: Int64

    /// Jari diangkat / scroll dibatalkan di trackpad.
    var fingerLifted: Bool { phase == 4 || phase == 8 }
    var isMomentum: Bool { momentumPhase != 0 }
}

protocol InputCaptureDelegate: AnyObject {
    /// Boleh menangkap ⌘⌥T saat mode lokal? (mis. hanya bila HP terhubung)
    func captureCanToggle() -> Bool
    func captureToggleRequested()
    func captureEmergencyExit()
}

enum SwipeDirection: String { case up, down, left, right }

/// CGEventTap global. Mode lokal: semua event diteruskan normal.
/// Mode remote: event mouse/keyboard ditelan dan diteruskan ke callback.
final class InputCapture {
    enum Mode { case local, remote }

    weak var delegate: InputCaptureDelegate?
    var mode: Mode = .local
    var onMove: ((_ dx: Double, _ dy: Double) -> Void)?
    var onButton: ((_ button: Int, _ down: Bool) -> Void)?
    var onScroll: ((ScrollSample) -> Void)?
    /// Mode remote: pinch trackpad (magnification delta, phase) dan ketuk-ganda dua jari.
    var onMagnify: ((_ magnification: Double, _ phase: NSEvent.Phase) -> Void)?
    var onSmartMagnify: (() -> Void)?
    /// Mode remote: swipe 3 jari selesai (gestur Mission Control/Space milik macOS).
    var onDockSwipe: ((_ direction: SwipeDirection) -> Void)?
    /// Mode remote: tombol keyboard (selain ⌘⌥T) — diteruskan ke HP.
    var onKey: ((_ event: CGEvent, _ down: Bool) -> Void)?
    /// Mode lokal: setiap gerak mouse tanpa tombol (untuk deteksi dorongan di tepi layar).
    var onLocalMove: ((_ location: CGPoint, _ dx: Double) -> Void)?
    /// Mode lokal: tombol kiri ditekan/dilepas dan drag (untuk panel kirim file).
    var onLocalLeftButton: ((_ down: Bool) -> Void)?
    var onLocalDrag: ((_ location: CGPoint) -> Void)?

    private(set) var isRunning = false
    private var tap: CFMachPort?
    /// Swipe 3 jari yang sedang berlangsung: arah (1 horizontal, 2 vertikal) dan progress terbesar.
    private var dockSwipeMotion: Int64 = 0
    private var dockSwipePeak: Double = 0
    private var escapeTimes: [TimeInterval] = []
    private var swallowKeyUps: Set<Int64> = []

    static var hasAccessibility: Bool { AXIsProcessTrusted() }

    /// Tampilkan dialog sistem "izinkan cursoe mengontrol komputer ini".
    static func requestAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    /// Membuat event tap. Gagal (false) bila izin Accessibility belum diberikan.
    func start() -> Bool {
        if isRunning { return true }
        let types: [CGEventType] = [
            .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
            .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp,
            .scrollWheel, .keyDown, .keyUp, .flagsChanged,
        ]
        var mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << CGEventMask($1.rawValue)) }
        // Event gesture trackpad (tidak ada di enum CGEventType): 29 gesture, 30 magnify, 32 smart magnify.
        for raw in Self.gestureTypes { mask |= CGEventMask(1) << CGEventMask(raw) }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: inputTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            return false
        }
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        isRunning = true
        Log.info("Event tap aktif")
        return true
    }

    fileprivate func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)

        // Event yang diposting Cursoe sendiri (mis. menempatkan kursor): jangan diproses.
        if event.getIntegerValueField(.eventSourceUserData) == CursorControl.syntheticTag {
            return pass
        }

        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            Log.info("Event tap dimatikan sistem (\(type.rawValue)); diaktifkan lagi")
            return pass
        }

        if type == .keyDown || type == .keyUp {
            let code = event.getIntegerValueField(.keyboardEventKeycode)
            let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0

            if type == .keyUp, swallowKeyUps.remove(code) != nil { return nil }

            // ⌘⌥T: masuk/keluar mode remote (pengaman utama, selalu dicek duluan).
            if type == .keyDown, Self.isToggleHotkey(code, event.flags),
               mode == .remote || delegate?.captureCanToggle() == true {
                swallowKeyUps.insert(code)
                if !isRepeat { delegate?.captureToggleRequested() }
                return nil
            }

            // Esc 3x dalam 1,5 detik: paksa kembali ke mode lokal.
            if mode == .remote, type == .keyDown, !isRepeat, code == Int64(kVK_Escape) {
                registerEscape()
            }
        }

        if Self.gestureTypes.contains(type.rawValue) {
            guard mode == .remote else { return pass }
            // Mode remote: semua gesture trackpad ditelan (termasuk swipe Mission Control/Space).
            if type.rawValue == 30, event.getIntegerValueField(Self.fieldGestureHIDType) == Self.hidDockSwipe {
                handleDockSwipe(event)
                return nil
            }
            if let nsEvent = NSEvent(cgEvent: event) {
                switch nsEvent.type {
                case .magnify: onMagnify?(Double(nsEvent.magnification), nsEvent.phase)
                case .smartMagnify: onSmartMagnify?()
                default: break
                }
            }
            return nil
        }

        guard mode == .remote else {
            switch type {
            case .mouseMoved: onLocalMove?(event.location, event.getDoubleValueField(.mouseEventDeltaX))
            case .leftMouseDown: onLocalLeftButton?(true)
            case .leftMouseUp: onLocalLeftButton?(false)
            case .leftMouseDragged: onLocalDrag?(event.location)
            default: break
            }
            return pass
        }

        switch type {
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            onMove?(event.getDoubleValueField(.mouseEventDeltaX), event.getDoubleValueField(.mouseEventDeltaY))
        case .leftMouseDown: onButton?(0, true)
        case .leftMouseUp: onButton?(0, false)
        case .rightMouseDown: onButton?(1, true)
        case .rightMouseUp: onButton?(1, false)
        case .otherMouseDown, .otherMouseUp:
            onButton?(Int(event.getIntegerValueField(.mouseEventButtonNumber)), type == .otherMouseDown)
        case .scrollWheel:
            onScroll?(ScrollSample(
                dx: event.getDoubleValueField(.scrollWheelEventPointDeltaAxis2),
                dy: event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1),
                phase: event.getIntegerValueField(.scrollWheelEventScrollPhase),
                momentumPhase: event.getIntegerValueField(.scrollWheelEventMomentumPhase)
            ))
        case .keyDown, .keyUp:
            onKey?(event, type == .keyDown)
        case .flagsChanged:
            // Modifier tetap diteruskan ke Mac supaya status ⌘/⌥/⇧ di macOS tidak "nyangkut".
            return pass
        default:
            break
        }
        return nil
    }

    private static let gestureTypes: Set<UInt32> = [29, 30, 32]

    // Field privat event gesture (CGS). "Dock swipe" = swipe 3/4 jari yang biasanya ditangani Dock
    // (Mission Control, App Exposé, pindah Space). Tidak ada API publik; nilai ini stabil sejak lama.
    private static let fieldGestureHIDType = CGEventField(rawValue: 110)!
    private static let fieldSwipeMotion = CGEventField(rawValue: 123)! // 1 horizontal, 2 vertikal, 3 pinch
    private static let fieldSwipeProgress = CGEventField(rawValue: 124)!
    private static let fieldGesturePhase = CGEventField(rawValue: 132)! // 1 began, 2 changed, 4 ended, 8 cancelled
    private static let hidDockSwipe: Int64 = 23

    private func handleDockSwipe(_ event: CGEvent) {
        let phase = event.getIntegerValueField(Self.fieldGesturePhase)
        let motion = event.getIntegerValueField(Self.fieldSwipeMotion)
        let progress = event.getDoubleValueField(Self.fieldSwipeProgress)

        if phase == 1 {
            dockSwipeMotion = motion
            dockSwipePeak = 0
        }
        if abs(progress) > abs(dockSwipePeak) { dockSwipePeak = progress }
        guard phase == 4 || phase == 8 else { return }

        let peak = dockSwipePeak
        let swipeMotion = dockSwipeMotion != 0 ? dockSwipeMotion : motion
        dockSwipeMotion = 0
        dockSwipePeak = 0
        Log.info("Swipe 3 jari: motion=\(swipeMotion) progress=\(String(format: "%.3f", peak)) phase=\(phase)")
        // Sentuhan singkat/ragu-ragu diabaikan, seperti macOS yang membatalkan Mission Control.
        guard abs(peak) >= 0.08 else { return }
        switch swipeMotion {
        case 1: onDockSwipe?(peak < 0 ? .left : .right)
        case 2: onDockSwipe?(peak < 0 ? .up : .down)
        default: break
        }
    }

    private static func isToggleHotkey(_ code: Int64, _ flags: CGEventFlags) -> Bool {
        code == Int64(kVK_ANSI_T)
            && flags.contains(.maskCommand) && flags.contains(.maskAlternate)
            && !flags.contains(.maskControl) && !flags.contains(.maskShift)
    }

    private func registerEscape() {
        let now = ProcessInfo.processInfo.systemUptime
        escapeTimes = escapeTimes.filter { now - $0 < 1.5 } + [now]
        if escapeTimes.count >= 3 {
            escapeTimes.removeAll()
            delegate?.captureEmergencyExit()
        }
    }
}

private func inputTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                              refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    return Unmanaged<InputCapture>.fromOpaque(refcon).takeUnretainedValue().handle(type, event)
}
