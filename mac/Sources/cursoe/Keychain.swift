import Foundation
import Security

/// Token pairing per HP disimpan di login Keychain (generic password).
enum Keychain {
    private static let service = "dev.cursoe.pairing"

    static func token(for deviceId: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: deviceId,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status != errSecSuccess && status != errSecItemNotFound {
            Log.info("Keychain: gagal membaca token (\(status))")
        }
        return status == errSecSuccess ? result as? Data : nil
    }

    static func save(token: Data, for deviceId: String, deviceName: String) {
        delete(deviceId)
        let item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: deviceId,
            kSecAttrLabel as String: "Cursoe – \(deviceName)",
            kSecValueData as String: token,
        ]
        let status = SecItemAdd(item as CFDictionary, nil)
        Log.info(status == errSecSuccess
                 ? "Keychain: token untuk \(deviceName) disimpan"
                 : "Keychain: gagal menyimpan token (\(status))")
    }

    static func delete(_ deviceId: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: deviceId,
        ]
        SecItemDelete(query as CFDictionary)
    }

    static func deleteAll() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        // Di macOS SecItemDelete bisa hanya menghapus satu item per panggilan.
        for _ in 0..<64 where SecItemDelete(query as CFDictionary) == errSecSuccess {}
    }
}
