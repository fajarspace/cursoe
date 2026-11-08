package dev.cursoe.net

import dev.cursoe.tr
import java.nio.ByteBuffer
import java.security.KeyFactory
import java.security.KeyPair
import java.security.KeyPairGenerator
import java.security.MessageDigest
import java.security.spec.ECGenParameterSpec
import java.security.spec.X509EncodedKeySpec
import javax.crypto.Cipher
import javax.crypto.KeyAgreement
import javax.crypto.Mac
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

/** Bahan handshake milik HP untuk satu koneksi. */
class Handshake {
    val keyPair: KeyPair = KeyPairGenerator.getInstance("EC").run {
        initialize(ECGenParameterSpec("secp256r1"))
        generateKeyPair()
    }
    val nonce: ByteArray = Wire.randomBytes(32)
    val publicKeyDer: ByteArray get() = keyPair.public.encoded // SubjectPublicKeyInfo (DER)
}

/**
 * Kanal terenkripsi satu sesi; harus identik dengan SecureChannel.swift di Mac.
 *
 * - ECDH P-256 ephemeral → HKDF-SHA256(salt = nonceMac‖nonceFold,
 *   info = "cursoe/v1/keys"‖transcript) → 64 byte: [Mac→Fold | Fold→Mac].
 * - transcript = SHA-256(HELLO Mac ‖ HELLO Fold), byte persis seperti di kabel.
 * - Frame: nonce 12 byte (4 nol + counter 64-bit) ‖ ciphertext ‖ tag 16 byte.
 *
 * seal() hanya dipanggil dari thread penulis, open() hanya dari thread pembaca.
 */
class SecureChannel(
    handshake: Handshake,
    macHello: ByteArray,
    foldHello: ByteArray,
    peerPublicKeyDer: ByteArray,
    peerNonce: ByteArray,
) {
    val transcript: ByteArray
    private val sendKey: SecretKeySpec    // Fold → Mac
    private val receiveKey: SecretKeySpec // Mac → Fold
    private val sendCipher = Cipher.getInstance("AES/GCM/NoPadding")
    private val receiveCipher = Cipher.getInstance("AES/GCM/NoPadding")
    private var sendCounter = 0L
    private var receiveCounter = 0L

    init {
        val peerKey = KeyFactory.getInstance("EC").generatePublic(X509EncodedKeySpec(peerPublicKeyDer))
        val agreement = KeyAgreement.getInstance("ECDH")
        agreement.init(handshake.keyPair.private)
        agreement.doPhase(peerKey, true)
        val shared = agreement.generateSecret()

        transcript = MessageDigest.getInstance("SHA-256").run {
            update(macHello)
            update(foldHello)
            digest()
        }
        val material = hkdf(
            ikm = shared,
            salt = peerNonce + handshake.nonce,
            info = "cursoe/v1/keys".toByteArray() + transcript,
            length = 64,
        )
        receiveKey = SecretKeySpec(material.copyOfRange(0, 32), "AES")
        sendKey = SecretKeySpec(material.copyOfRange(32, 64), "AES")
    }

    fun seal(plaintext: ByteArray): ByteArray {
        val nonce = nonce(sendCounter++)
        sendCipher.init(Cipher.ENCRYPT_MODE, sendKey, GCMParameterSpec(128, nonce))
        return nonce + sendCipher.doFinal(plaintext)
    }

    fun open(payload: ByteArray): ByteArray {
        if (payload.size < 12 + 16) throw SecurityException(tr("frame too short", "frame terlalu pendek"))
        val nonce = payload.copyOfRange(0, 12)
        if (!nonce.contentEquals(nonce(receiveCounter))) throw SecurityException(tr("invalid message order", "urutan pesan tidak valid"))
        receiveCounter++
        receiveCipher.init(Cipher.DECRYPT_MODE, receiveKey, GCMParameterSpec(128, nonce))
        return receiveCipher.doFinal(payload, 12, payload.size - 12)
    }

    /** Bukti kepemilikan token pairing, terikat ke transcript sesi ini. */
    fun proof(token: ByteArray, label: String): ByteArray =
        hmac(token, label.toByteArray() + transcript)

    fun verify(proof: ByteArray, token: ByteArray, label: String): Boolean =
        MessageDigest.isEqual(proof, proof(token, label))

    companion object {
        private fun nonce(counter: Long): ByteArray =
            ByteBuffer.allocate(12).putInt(0).putLong(counter).array()

        fun hmac(key: ByteArray, data: ByteArray): ByteArray =
            Mac.getInstance("HmacSHA256").run {
                init(SecretKeySpec(key, "HmacSHA256"))
                doFinal(data)
            }

        /** HKDF-SHA256 (RFC 5869). */
        fun hkdf(ikm: ByteArray, salt: ByteArray, info: ByteArray, length: Int): ByteArray {
            val prk = hmac(salt, ikm)
            val out = ByteArray(length)
            var block = ByteArray(0)
            var written = 0
            var counter = 1
            while (written < length) {
                block = hmac(prk, block + info + byteArrayOf(counter.toByte()))
                val n = minOf(block.size, length - written)
                System.arraycopy(block, 0, out, written, n)
                written += n
                counter++
            }
            return out
        }
    }
}
