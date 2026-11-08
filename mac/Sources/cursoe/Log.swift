import Foundation
import os

/// Log Cursoe.
/// - Selalu: unified logging macOS (Console.app, atau
///   `log stream --info --predicate 'subsystem == "dev.cursoe.mac"'`).
/// - Bila "Log debug" dinyalakan (menu, tersimpan) atau CURSOE_DEBUG=1: juga log rinci
///   ke ~/Library/Logs/Cursoe/cursoe.log (dirotasi di 5 MB).
enum Log {
    private static let logger = Logger(subsystem: "dev.cursoe.mac", category: "bridge")
    private static let fileQueue = DispatchQueue(label: "dev.cursoe.log")
    private static let maxFileBytes = 5 * 1024 * 1024

    static var verbose: Bool = UserDefaults.standard.bool(forKey: "debugLog")
        || ProcessInfo.processInfo.environment["CURSOE_DEBUG"] == "1" {
        didSet {
            UserDefaults.standard.set(verbose, forKey: "debugLog")
            info("Log debug \(verbose ? "dinyalakan" : "dimatikan")")
        }
    }

    static let fileURL: URL = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Logs/Cursoe/cursoe.log")

    static func info(_ message: String) {
        logger.notice("\(message, privacy: .public)")
        if verbose { appendToFile(message) }
    }

    static func debug(_ message: @autoclosure () -> String) {
        guard verbose else { return }
        let text = message()
        logger.debug("\(text, privacy: .public)")
        appendToFile(text)
    }

    private static let timestamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter
    }()

    private static func appendToFile(_ message: String) {
        let now = Date()
        fileQueue.async {
            let manager = FileManager.default
            try? manager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let size = (try? manager.attributesOfItem(atPath: fileURL.path)[.size] as? NSNumber)?.intValue,
               size > maxFileBytes {
                let old = fileURL.appendingPathExtension("1")
                try? manager.removeItem(at: old)
                try? manager.moveItem(at: fileURL, to: old)
            }
            let line = Data("\(timestamp.string(from: now))  \(message)\n".utf8)
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                handle.seekToEndOfFile()
                handle.write(line)
                try? handle.close()
            } else {
                manager.createFile(atPath: fileURL.path, contents: line)
            }
        }
    }
}
