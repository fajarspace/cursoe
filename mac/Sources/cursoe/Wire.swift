import Foundation

typealias Message = [String: Any]

/// Format di kabel: [panjang UInt32 big-endian][payload].
/// Payload HELLO berupa JSON polos; setelah handshake payload = AES-GCM(JSON).
enum Wire {
    static let maxFrame = 1 << 20  // 1 MB, cukup untuk clipboard teks

    static func encodeJSON(_ message: Message) -> Data {
        (try? JSONSerialization.data(withJSONObject: message, options: [.withoutEscapingSlashes])) ?? Data()
    }

    static func decodeJSON(_ data: Data) -> Message? {
        (try? JSONSerialization.jsonObject(with: data)) as? Message
    }

    static func frame(_ payload: Data) -> Data {
        var length = UInt32(payload.count).bigEndian
        var out = Data(bytes: &length, count: 4)
        out.append(payload)
        return out
    }

    static func readLength(_ header: Data) -> Int {
        header.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
    }
}

extension Dictionary where Key == String, Value == Any {
    func string(_ key: String) -> String? { self[key] as? String }
    func int(_ key: String) -> Int? { (self[key] as? NSNumber)?.intValue }
    func int64(_ key: String) -> Int64? { (self[key] as? NSNumber)?.int64Value }
    func double(_ key: String) -> Double? { (self[key] as? NSNumber)?.doubleValue }
    func bool(_ key: String) -> Bool? { (self[key] as? NSNumber)?.boolValue }
    func base64(_ key: String) -> Data? { string(key).flatMap { Data(base64Encoded: $0) } }
}
