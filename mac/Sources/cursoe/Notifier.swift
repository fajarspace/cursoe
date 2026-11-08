import AppKit
import UserNotifications

/// Notifikasi macOS untuk file yang diterima dari HP. Klik → tampilkan di Finder.
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()

    func setup() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            if !granted { Log.info("Notifikasi macOS tidak diizinkan; file baru akan ditampilkan di Finder") }
        }
    }

    func fileReceived(_ url: URL) {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else {
                DispatchQueue.main.async { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                return
            }
            let content = UNMutableNotificationContent()
            content.title = L("File from your device", "File dari HP")
            content.body = L("\(url.lastPathComponent) was saved to Downloads", "\(url.lastPathComponent) tersimpan di Downloads")
            content.sound = .default
            content.userInfo = ["path": url.path]
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if let path = response.notification.request.content.userInfo["path"] as? String {
            DispatchQueue.main.async {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            }
        }
        completionHandler()
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
