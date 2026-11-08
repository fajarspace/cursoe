import AppKit

/// Dialog input PIN pairing. Harus dipanggil di main thread dari luar blok GCD
/// (lihat BridgeClient.runOnMainRunLoop) supaya antrean main tetap jalan selama modal.
enum PinPrompt {
    private static var isShowing = false

    /// Mengembalikan PIN 6 digit, atau nil bila dibatalkan.
    static func ask(device: String, message: String?) -> String? {
        NSApp.activate()
        isShowing = true
        defer { isShowing = false }

        var note = message
        while true {
            let alert = NSAlert()
            alert.messageText = L("Pair with \(device)", "Pairing dengan \(device)")
            alert.informativeText = [note, L("Enter the 6-digit PIN shown in the Cursoe app or notification on your device.", "Ketik PIN 6 digit yang muncul di notifikasi / aplikasi Cursoe di HP.")]
                .compactMap { $0 }
                .joined(separator: "\n\n")
            let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 28))
            field.placeholderString = "123456"
            field.font = .monospacedDigitSystemFont(ofSize: 18, weight: .medium)
            alert.accessoryView = field
            alert.addButton(withTitle: "Pair")
            alert.addButton(withTitle: L("Cancel", "Batal"))
            alert.window.initialFirstResponder = field

            guard alert.runModal() == .alertFirstButtonReturn else { return nil }
            let pin = field.stringValue.filter { ("0"..."9").contains($0) }
            if pin.count == 6 { return pin }
            note = L("The PIN must be 6 digits.", "PIN harus 6 digit angka.")
        }
    }

    /// Menutup dialog yang sedang tampil (mis. koneksi putus di tengah pairing).
    static func cancel() {
        if isShowing { NSApp.abortModal() }
    }
}
