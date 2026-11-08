package dev.cursoe.net

import java.io.DataInputStream
import java.io.DataOutputStream
import java.io.IOException
import java.security.SecureRandom
import java.util.Base64

/**
 * Format di kabel: [panjang Int32 big-endian][payload].
 * HELLO berupa JSON polos; setelah handshake payload = AES-GCM(JSON).
 */
object Wire {
    const val MAX_FRAME = 1 shl 20 // 1 MB

    private val random = SecureRandom()

    fun readFrame(input: DataInputStream): ByteArray {
        val length = input.readInt()
        if (length <= 0 || length > MAX_FRAME) throw IOException("ukuran frame tidak valid ($length)")
        val buffer = ByteArray(length)
        input.readFully(buffer)
        return buffer
    }

    fun writeFrame(output: DataOutputStream, payload: ByteArray) {
        output.writeInt(payload.size)
        output.write(payload)
        output.flush()
    }

    fun b64(bytes: ByteArray): String = Base64.getEncoder().encodeToString(bytes)

    fun unb64(text: String): ByteArray = Base64.getDecoder().decode(text)

    fun randomBytes(count: Int): ByteArray = ByteArray(count).also { random.nextBytes(it) }

    fun randomPin(): String = "%06d".format(random.nextInt(1_000_000))
}
