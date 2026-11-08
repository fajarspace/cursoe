import CryptoKit
import Foundation
import UniformTypeIdentifiers

/// Dipanggil BridgeClient di antrean jaringannya (urutan pesan & potongan biner terjaga).
protocol FileTransferHandler: AnyObject {
    func handleFileMessage(_ type: String, _ message: Message)
    func handleFileChunk(_ id: UUID, _ data: Data)
    func connectionLost()
}

/// Kirim/terima file Mac ↔ HP.
///
/// Protokol: FILE_BEGIN {id, name, size, mime, index, count} → potongan biner
/// [0x01][16 byte UUID][data] → FILE_END {id, sha256} → (penerima) FILE_RESULT {id, ok, message}.
/// File langsung ditulis/dibaca dari disk (tidak ditampung di memori). Potongan berikutnya
/// baru dikirim setelah yang sebelumnya diproses jaringan, jadi MOVE/PING tetap menyelip.
final class FileTransfer: FileTransferHandler {
    static let chunkBytes = 64 * 1024
    static let binaryMarker: UInt8 = 0x01

    /// Status untuk menu (main thread); nil = tidak ada transfer.
    var onStatus: ((String?) -> Void)?
    /// File dari HP selesai disimpan (main thread).
    /// File dari HP tersimpan. `last` = file terakhir dalam satu kiriman (untuk menu "Buka dengan").
    var onReceived: ((_ url: URL, _ last: Bool) -> Void)?
    private var shareBatch = false
    private var batchID = UUID()

    private let client: BridgeClient
    private let queue: DispatchQueue

    // Kirim (semua state hanya di `queue`)
    private var pending: [URL] = []
    private var batchTotal = 0
    private var batchIndex = 0
    private var outgoing: Outgoing?
    private var lastStatusAt = 0.0

    private struct Outgoing {
        let id: UUID
        let name: String
        let handle: FileHandle
        let size: Int
        var sent = 0
        var hasher = SHA256()
    }

    // Terima
    private var incoming: [UUID: Incoming] = [:]

    private struct Incoming {
        let name: String
        let size: Int
        let tempURL: URL
        let handle: FileHandle
        let isLast: Bool
        var received = 0
        var hasher = SHA256()
    }


    init(client: BridgeClient) {
        self.client = client
        queue = client.networkQueue
    }

    // MARK: Kirim ke HP

    /// [share] = setelah tersimpan di HP, tampilkan pilihan "Simpan saja / Buka dengan…" di HP.
    func send(_ urls: [URL], share: Bool = false) {
        queue.async {
            if self.outgoing == nil && self.pending.isEmpty {
                self.shareBatch = share
                self.batchID = UUID()
            }
            let files = urls.filter { url in
                var isDirectory: ObjCBool = false
                return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && !isDirectory.boolValue
            }
            if files.count < urls.count { Log.info("Folder dilewati (hanya file yang dikirim)") }
            guard !files.isEmpty else { return }
            if self.outgoing == nil && self.pending.isEmpty {
                self.batchTotal = 0
                self.batchIndex = 0
            }
            self.pending += files
            self.batchTotal += files.count
            if self.outgoing == nil { self.startNext() }
        }
    }

    private func startNext() {
        guard outgoing == nil else { return }
        guard !pending.isEmpty else {
            publish(nil)
            return
        }
        let url = pending.removeFirst()
        batchIndex += 1
        do {
            let handle = try FileHandle(forReadingFrom: url)
            let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
            let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
            let item = Outgoing(id: UUID(), name: url.lastPathComponent, handle: handle, size: size)
            outgoing = item
            client.sendOnQueue([
                "t": "FILE_BEGIN", "id": item.id.uuidString, "name": item.name, "size": size, "mime": mime,
                "index": batchIndex, "count": batchTotal,
                "share": shareBatch, "batch": batchID.uuidString,
            ])
            Log.info("Mengirim \(item.name) (\(size / 1024) KB) ke HP")
            pump()
        } catch {
            Log.info("Tidak bisa membaca \(url.lastPathComponent): \(error.localizedDescription)")
            startNext()
        }
    }

    private func pump() {
        guard var item = outgoing else { return }
        let data: Data
        do {
            data = try item.handle.read(upToCount: Self.chunkBytes) ?? Data()
        } catch {
            client.sendOnQueue(["t": "FILE_CANCEL", "id": item.id.uuidString])
            finishOutgoing()
            return
        }
        if data.isEmpty {
            let digest = item.hasher.finalize().map { String(format: "%02x", $0) }.joined()
            client.sendOnQueue(["t": "FILE_END", "id": item.id.uuidString, "sha256": digest])
            finishOutgoing()
            return
        }
        item.hasher.update(data: data)
        item.sent += data.count
        outgoing = item
        publishProgress("Mengirim \(item.name)", done: item.sent, total: item.size)

        var frame = Data([Self.binaryMarker])
        withUnsafeBytes(of: item.id.uuid) { frame.append(contentsOf: $0) }
        frame.append(data)
        let sent = client.sendBinaryOnQueue(frame) { [weak self] in self?.pump() }
        if !sent { abortOutgoing("koneksi putus") }
    }

    private func finishOutgoing() {
        try? outgoing?.handle.close()
        outgoing = nil
        startNext()
    }

    private func abortOutgoing(_ reason: String) {
        if let item = outgoing { Log.info("Pengiriman \(item.name) dibatalkan: \(reason)") }
        try? outgoing?.handle.close()
        outgoing = nil
        pending.removeAll()
        publish(nil)
    }

    // MARK: Terima dari HP (FileTransferHandler, di `queue`)

    func handleFileMessage(_ type: String, _ m: Message) {
        switch type {
        case "FILE_BEGIN":
            guard let idText = m.string("id"), let id = UUID(uuidString: idText),
                  let size = m.int("size"), size >= 0 else { return }
            let name = Self.safeName(m.string("name") ?? "file")
            let temp = Self.downloads.appendingPathComponent(".cursoe-\(id.uuidString).part")
            guard FileManager.default.createFile(atPath: temp.path, contents: nil),
                  let handle = try? FileHandle(forWritingTo: temp) else {
                Log.info("Tidak bisa menulis ke Downloads")
                client.sendOnQueue(["t": "FILE_RESULT", "id": idText, "ok": false, "message": "Mac tidak bisa menulis ke Downloads"])
                return
            }
            let isLast = (m.int("index") ?? 1) >= (m.int("count") ?? 1)
            incoming[id] = Incoming(name: name, size: size, tempURL: temp, handle: handle, isLast: isLast)
            Log.info("Menerima \(name) (\(size / 1024) KB) dari HP")

        case "FILE_END":
            guard let idText = m.string("id"), let id = UUID(uuidString: idText), let item = incoming.removeValue(forKey: id) else { return }
            try? item.handle.close()
            let digest = item.hasher.finalize().map { String(format: "%02x", $0) }.joined()
            guard item.received == item.size, digest == m.string("sha256") else {
                try? FileManager.default.removeItem(at: item.tempURL)
                client.sendOnQueue(["t": "FILE_RESULT", "id": idText, "ok": false, "message": "file rusak/tidak lengkap"])
                return
            }
            let final = Self.uniqueURL(in: Self.downloads, name: item.name)
            do {
                try FileManager.default.moveItem(at: item.tempURL, to: final)
                client.sendOnQueue(["t": "FILE_RESULT", "id": idText, "ok": true, "message": "Tersimpan di Downloads Mac"])
                Log.info("File dari HP tersimpan: \(final.path)")
                publish(nil)
                DispatchQueue.main.async { self.onReceived?(final, item.isLast) }
            } catch {
                try? FileManager.default.removeItem(at: item.tempURL)
                client.sendOnQueue(["t": "FILE_RESULT", "id": idText, "ok": false, "message": error.localizedDescription])
            }

        case "FILE_CANCEL":
            guard let idText = m.string("id"), let id = UUID(uuidString: idText), let item = incoming.removeValue(forKey: id) else { return }
            try? item.handle.close()
            try? FileManager.default.removeItem(at: item.tempURL)
            publish(nil)

        case "FILE_RESULT":
            let ok = m.bool("ok") ?? false
            Log.info("HP: \(ok ? "file diterima" : "gagal menerima file") — \(m.string("message") ?? "")")

        default:
            break
        }
    }

    func handleFileChunk(_ id: UUID, _ data: Data) {
        guard var item = incoming[id] else { return }
        do {
            try item.handle.write(contentsOf: data)
        } catch {
            try? item.handle.close()
            try? FileManager.default.removeItem(at: item.tempURL)
            incoming[id] = nil
            client.sendOnQueue(["t": "FILE_RESULT", "id": id.uuidString, "ok": false, "message": "disk Mac penuh/tidak bisa ditulis"])
            return
        }
        item.hasher.update(data: data)
        item.received += data.count
        incoming[id] = item
        if item.received > item.size {
            handleFileMessage("FILE_CANCEL", ["id": id.uuidString])
            return
        }
        publishProgress("Menerima \(item.name)", done: item.received, total: item.size)
    }

    func connectionLost() {
        abortOutgoing("koneksi putus")
        for (_, item) in incoming {
            try? item.handle.close()
            try? FileManager.default.removeItem(at: item.tempURL)
        }
        incoming.removeAll()
    }

    // MARK: Utilitas

    private func publishProgress(_ label: String, done: Int, total: Int) {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastStatusAt > 0.25 || done >= total else { return }
        lastStatusAt = now
        let percent = total > 0 ? done * 100 / total : 100
        let batch = batchTotal > 1 && label.hasPrefix("Mengirim") ? " (\(batchIndex)/\(batchTotal))" : ""
        publish("\(label)\(batch) — \(percent)%")
    }

    private func publish(_ status: String?) {
        DispatchQueue.main.async { self.onStatus?(status) }
    }

    static var downloads: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Downloads")
    }

    /// Nama file dari HP: tanpa folder/karakter berbahaya.
    static func safeName(_ name: String) -> String {
        let cleaned = name.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmed = cleaned.hasPrefix(".") ? "_" + cleaned.dropFirst() : cleaned
        return trimmed.isEmpty ? "file" : String(trimmed.prefix(200))
    }

    static func uniqueURL(in folder: URL, name: String) -> URL {
        var candidate = folder.appendingPathComponent(name)
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var n = 1
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent(ext.isEmpty ? "\(base) (\(n))" : "\(base) (\(n)).\(ext)")
            n += 1
        }
        return candidate
    }
}
