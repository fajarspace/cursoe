import AppKit

/// Daftar aplikasi Mac yang bisa membuka file (dipakai panel penerimaan file dari HP).
enum OpenWithMenu {
    /// Aplikasi yang bisa membuka SEMUA file; aplikasi bawaan untuk file pertama di urutan teratas.
    static func applications(for urls: [URL]) -> [URL] {
        let sets = urls.map { Set(NSWorkspace.shared.urlsForApplications(toOpen: $0).map(\.standardizedFileURL)) }
        guard var common = sets.first else { return [] }
        for set in sets.dropFirst() { common.formIntersection(set) }
        common.remove(Bundle.main.bundleURL.standardizedFileURL)
        let preferred = NSWorkspace.shared.urlForApplication(toOpen: urls[0])?.standardizedFileURL
        let sorted = common.sorted {
            FileManager.default.displayName(atPath: $0.path).localizedCaseInsensitiveCompare(
                FileManager.default.displayName(atPath: $1.path)) == .orderedAscending
        }
        guard let preferred, common.contains(preferred) else { return sorted }
        return [preferred] + sorted.filter { $0 != preferred }
    }
}

/// Item menu dengan aksi berupa closure.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, symbol: String? = nil, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
        if let symbol { image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) tidak dipakai") }

    @objc private func run() { handler() }
}
