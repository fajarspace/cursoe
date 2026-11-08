package dev.cursoe.net

import android.util.Log
import org.json.JSONObject
import java.io.BufferedInputStream
import java.io.BufferedOutputStream
import java.io.DataInputStream
import java.io.DataOutputStream
import java.io.EOFException
import java.io.IOException
import java.net.Socket
import java.net.SocketTimeoutException
import java.security.MessageDigest
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.concurrent.thread

/**
 * Satu koneksi dari Mac: handshake, pairing/autentikasi, lalu loop pesan.
 * Thread pembaca memproses pesan masuk; thread penulis mengenkripsi & mengirim.
 */
class Session(private val socket: Socket, private val host: Host) {

    interface Host {
        val deviceId: String
        val deviceName: String
        fun tokenFor(macId: String): ByteArray?
        fun savePairing(macId: String, macName: String, token: ByteArray)
        fun showPin(pin: String, macName: String)
        fun hidePin()
        fun screenInfo(): JSONObject
        fun onAuthenticated(session: Session)
        fun onClosed(session: Session, reason: String)
        fun onMessage(session: Session, type: String, message: JSONObject)
        /** Frame biner [0x01][16 byte UUID][data] (potongan file). Thread pembaca. */
        fun onBinary(session: Session, frame: ByteArray)
    }

    private class Outgoing(val bytes: ByteArray, val encrypt: Boolean)

    private val input = DataInputStream(BufferedInputStream(socket.getInputStream()))
    private val output = DataOutputStream(BufferedOutputStream(socket.getOutputStream()))
    private val outbox = LinkedBlockingQueue<Outgoing>()
    private val poison = Outgoing(ByteArray(0), false)
    private val closed = AtomicBoolean(false)

    @Volatile private var channel: SecureChannel? = null
    @Volatile var authenticated = false
        private set
    var macName = "Mac"
        private set
    private var macId = ""

    private var pin: String? = null
    private var pinExpiresAt = 0L
    private var pinAttemptsLeft = 0

    val remoteAddress: String = socket.inetAddress?.hostAddress ?: "?"

    /** Jumlah pesan yang masih menunggu dikirim (untuk menahan laju pengiriman gambar). */
    val pendingOutgoing: Int get() = outbox.size

    fun start() {
        socket.tcpNoDelay = true
        socket.soTimeout = READ_TIMEOUT_MS
        thread(name = "gb-writer", isDaemon = true) { writerLoop() }
        thread(name = "gb-reader", isDaemon = true) { readerLoop() }
    }

    /** Kirim pesan aplikasi; diabaikan bila belum terautentikasi. */
    fun sendIfReady(message: JSONObject) {
        if (authenticated) send(message)
    }

    /** Kirim frame biner (potongan file); diabaikan bila belum terautentikasi. */
    fun sendBinaryIfReady(frame: ByteArray) {
        if (authenticated && !closed.get()) outbox.offer(Outgoing(frame, encrypt = true))
    }

    fun close(reason: String) {
        if (!closed.compareAndSet(false, true)) return
        Log.i(TAG, "Sesi $macName ditutup: $reason")
        outbox.offer(poison) // penulis mengirim sisa antrean dulu, lalu menutup socket
        thread(isDaemon = true) {
            Thread.sleep(1000)
            closeSocket()
        }
        if (pin != null) {
            pin = null
            host.hidePin()
        }
        host.onClosed(this, reason)
    }

    private fun send(message: JSONObject) {
        if (!closed.get()) outbox.offer(Outgoing(message.toString().toByteArray(), encrypt = true))
    }

    private fun closeSocket() {
        try {
            socket.close()
        } catch (_: IOException) {
        }
    }

    private fun writerLoop() {
        try {
            while (true) {
                val item = outbox.take()
                if (item === poison) break
                val payload = if (item.encrypt) channel!!.seal(item.bytes) else item.bytes
                Wire.writeFrame(output, payload)
            }
        } catch (e: Exception) {
            close("gagal mengirim: ${e.message}")
        } finally {
            closeSocket()
        }
    }

    private fun readerLoop() {
        val reason = try {
            handshake()
            while (!closed.get()) {
                val plaintext = channel!!.open(Wire.readFrame(input))
                if (plaintext.isNotEmpty() && plaintext[0] == BINARY_MARKER) {
                    if (authenticated) host.onBinary(this, plaintext)
                    continue
                }
                val message = JSONObject(String(plaintext, Charsets.UTF_8))
                handle(message.optString("t"), message)
            }
            "ditutup"
        } catch (_: SocketTimeoutException) {
            "Mac tidak merespons (timeout)"
        } catch (_: EOFException) {
            "Mac menutup koneksi"
        } catch (e: Exception) {
            e.message ?: e.javaClass.simpleName
        }
        close(reason)
    }

    private fun handshake() {
        val macHello = Wire.readFrame(input)
        val m = JSONObject(String(macHello, Charsets.UTF_8))
        if (m.optString("t") != "HELLO" || m.optInt("v") != 1) throw IOException("HELLO dari Mac tidak valid")
        macId = m.getString("id")
        macName = m.optString("name", "Mac")

        val hs = Handshake()
        val hello = JSONObject()
            .put("t", "HELLO").put("v", 1).put("role", "fold")
            .put("id", host.deviceId).put("name", host.deviceName)
            .put("nonce", Wire.b64(hs.nonce))
            .put("epk", Wire.b64(hs.publicKeyDer))
            .put("paired", host.tokenFor(macId) != null)
        val helloBytes = hello.toString().toByteArray()
        outbox.offer(Outgoing(helloBytes, encrypt = false))

        channel = SecureChannel(hs, macHello, helloBytes, Wire.unb64(m.getString("epk")), Wire.unb64(m.getString("nonce")))
        Log.i(TAG, "Kanal terenkripsi siap dengan $macName ($remoteAddress)")
    }

    private fun handle(type: String, m: JSONObject) {
        when (type) {
            "PING" -> send(JSONObject().put("t", "PONG").put("ts", m.opt("ts")))
            "PONG" -> Unit
            "AUTH" -> onAuth(m)
            "PAIR_REQUEST" -> onPairRequest()
            "PAIR" -> onPair(m)
            else -> if (authenticated) host.onMessage(this, type, m)
        }
    }

    private fun onAuth(m: JSONObject) {
        val ch = channel!!
        val token = host.tokenFor(macId)
        if (token == null) {
            send(JSONObject().put("t", "AUTH_FAIL").put("reason", "Mac belum dipair"))
            throw IOException("Mac belum dipair")
        }
        if (!ch.verify(Wire.unb64(m.optString("proof")), token, AUTH_MAC)) {
            send(JSONObject().put("t", "AUTH_FAIL").put("reason", "token salah"))
            throw IOException("token Mac salah")
        }
        send(JSONObject().put("t", "AUTH_OK").put("proof", Wire.b64(ch.proof(token, AUTH_FOLD))))
        becomeAuthenticated()
    }

    private fun onPairRequest() {
        val newPin = Wire.randomPin()
        pin = newPin
        pinExpiresAt = System.currentTimeMillis() + PIN_TTL_MS
        pinAttemptsLeft = PIN_ATTEMPTS
        Log.i(TAG, "Permintaan pairing dari $macName")
        host.showPin(newPin, macName)
        send(JSONObject().put("t", "PAIR_PIN_SHOWN"))
    }

    private fun onPair(m: JSONObject) {
        val expected = pin
        if (expected == null || System.currentTimeMillis() > pinExpiresAt) {
            send(JSONObject().put("t", "PAIR_FAIL").put("left", 0).put("reason", "PIN kedaluwarsa"))
            throw IOException("PIN kedaluwarsa")
        }
        val given = m.optString("pin")
        if (MessageDigest.isEqual(given.toByteArray(), expected.toByteArray())) {
            pin = null
            host.hidePin()
            val token = Wire.randomBytes(32)
            host.savePairing(macId, macName, token)
            send(JSONObject().put("t", "PAIR_OK").put("token", Wire.b64(token)))
            Log.i(TAG, "Pairing dengan $macName berhasil")
            becomeAuthenticated()
        } else {
            pinAttemptsLeft--
            send(JSONObject().put("t", "PAIR_FAIL").put("left", pinAttemptsLeft))
            if (pinAttemptsLeft <= 0) throw IOException("PIN salah $PIN_ATTEMPTS kali")
        }
    }

    private fun becomeAuthenticated() {
        authenticated = true
        send(host.screenInfo())
        host.onAuthenticated(this)
    }

    companion object {
        private const val TAG = "Cursoe"
        private const val AUTH_MAC = "cursoe/v1/auth-mac"
        private const val AUTH_FOLD = "cursoe/v1/auth-fold"
        private const val READ_TIMEOUT_MS = 8_000 // Mac mengirim PING tiap 2 detik
        private const val PIN_TTL_MS = 120_000L
        private const val PIN_ATTEMPTS = 3
        const val BINARY_MARKER: Byte = 0x01
    }
}
