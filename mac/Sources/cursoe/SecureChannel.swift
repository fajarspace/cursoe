import CryptoKit
import Foundation
import Security

enum ChannelError: Error {
    case malformed
    case outOfOrder
}

func randomBytes(_ count: Int) -> Data {
    var data = Data(count: count)
    let status = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!) }
    precondition(status == errSecSuccess, "SecRandomCopyBytes gagal")
    return data
}

/// Bahan handshake milik Mac untuk satu koneksi.
final class Handshake {
    let privateKey = P256.KeyAgreement.PrivateKey()
    let nonce = randomBytes(32)
    var publicKeyDER: Data { privateKey.publicKey.derRepresentation }
}

/// Kanal terenkripsi satu sesi.
///
/// - Kunci: ECDH P-256 ephemeral → HKDF-SHA256(salt = nonceMac‖nonceFold,
///   info = "cursoe/v1/keys"‖transcript) → 64 byte: [Mac→Fold | Fold→Mac].
/// - Transcript = SHA-256(HELLO Mac ‖ HELLO Fold) persis seperti byte di kabel.
/// - Frame: nonce 12 byte (4 nol + counter 64-bit) ‖ ciphertext ‖ tag 16 byte.
///   Counter harus urut, jadi pesan yang diputar ulang/diacak langsung ditolak.
final class SecureChannel {
    let transcript: Data
    private let sendKey: SymmetricKey
    private let receiveKey: SymmetricKey
    private var sendCounter: UInt64 = 0
    private var receiveCounter: UInt64 = 0

    init(handshake: Handshake, macHello: Data, foldHello: Data,
         peerPublicKeyDER: Data, peerNonce: Data) throws {
        let peerKey = try P256.KeyAgreement.PublicKey(derRepresentation: peerPublicKeyDER)
        let shared = try handshake.privateKey.sharedSecretFromKeyAgreement(with: peerKey)

        var hash = SHA256()
        hash.update(data: macHello)
        hash.update(data: foldHello)
        transcript = Data(hash.finalize())

        let material = shared.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: handshake.nonce + peerNonce,
            sharedInfo: Data("cursoe/v1/keys".utf8) + transcript,
            outputByteCount: 64
        )
        let bytes = material.withUnsafeBytes { Data($0) }
        sendKey = SymmetricKey(data: bytes.prefix(32))
        receiveKey = SymmetricKey(data: bytes.suffix(32))
    }

    func seal(_ plaintext: Data) throws -> Data {
        let nonce = try AES.GCM.Nonce(data: Self.nonce(sendCounter))
        sendCounter += 1
        return try AES.GCM.seal(plaintext, using: sendKey, nonce: nonce).combined!
    }

    func open(_ payload: Data) throws -> Data {
        guard payload.count >= 12 + 16 else { throw ChannelError.malformed }
        guard payload.prefix(12) == Self.nonce(receiveCounter) else { throw ChannelError.outOfOrder }
        receiveCounter += 1
        return try AES.GCM.open(AES.GCM.SealedBox(combined: payload), using: receiveKey)
    }

    /// Bukti kepemilikan token pairing, terikat ke transcript sesi ini
    /// (token-nya sendiri tidak pernah dikirim lagi setelah pairing).
    func proof(token: Data, label: String) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data(label.utf8) + transcript,
                                             using: SymmetricKey(data: token)))
    }

    func verify(proof: Data, token: Data, label: String) -> Bool {
        HMAC<SHA256>.isValidAuthenticationCode(proof,
                                               authenticating: Data(label.utf8) + transcript,
                                               using: SymmetricKey(data: token))
    }

    private static func nonce(_ counter: UInt64) -> Data {
        var bigEndian = counter.bigEndian
        return Data(count: 4) + Data(bytes: &bigEndian, count: 8)
    }
}
