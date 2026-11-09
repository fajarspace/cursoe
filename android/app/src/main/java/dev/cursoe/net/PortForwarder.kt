package dev.cursoe.net

import android.util.Log
import dev.cursoe.BridgeState
import java.io.IOException
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import kotlin.concurrent.thread
import org.json.JSONObject

/**
 * Port forwarding: `localhost:PORT` di HP → `localhost:PORT` di Mac, lewat sesi Cursoe yang terenkripsi
 * (kabel, hotspot, atau Wi-Fi). Seperti `adb reverse`, tanpa adb.
 *
 * Mac mengirim FORWARD {ports}; HP membuka ServerSocket di 127.0.0.1 dan ::1 untuk tiap port. Setiap koneksi
 * masuk (mis. dari Chrome) menjadi satu aliran: TUNNEL_OPEN {id, port} → data dua arah berupa frame biner
 * [0x02][id Int32 big-endian][data]. Arah yang selesai mengirim mengabarkan TUNNEL_EOF {id} (half-close, seperti
 * TCP: klien bisa menutup sisi kirimnya lalu tetap menunggu balasan); aliran selesai bila kedua arah EOF.
 * TUNNEL_CLOSE {id} = batalkan aliran (galat). Port di bawah 1024 tidak bisa dibuka aplikasi Android.
 * Semua aplikasi di HP bisa memakai port yang diteruskan (sama seperti `adb reverse`); Mac hanya menerima port
 * yang didaftarkan pengguna di menunya.
 */
class PortForwarder(private val session: () -> Session?) {

    /** Per port: soket IPv4 (127.0.0.1) dan IPv6 (::1), agar "localhost" lewat alamat mana pun tersambung. */
    private val listeners = ConcurrentHashMap<Int, List<ServerSocket>>()
    private val streams = ConcurrentHashMap<Int, Stream>()
    private val nextId = AtomicInteger(1)

    private inner class Stream(val id: Int, val port: Int, private val socket: Socket) {
        /** Data dari Mac yang menunggu ditulis ke aplikasi lokal (atau penanda REMOTE_EOF / STOP). */
        private val incoming = LinkedBlockingQueue<ByteArray>()
        private val closed = AtomicBoolean(false)
        @Volatile private var localDone = false  // aplikasi lokal selesai mengirim
        @Volatile private var remoteDone = false // Mac selesai mengirim

        fun start() {
            thread(name = "gb-tunnel-in-$id", isDaemon = true) { readLoop() }
            thread(name = "gb-tunnel-out-$id", isDaemon = true) { writeLoop() }
        }

        fun deliver(data: ByteArray) = incoming.offer(data)

        fun remoteEof() = incoming.offer(REMOTE_EOF)

        /** Aplikasi lokal → Mac. Laju ditahan agar antrean kirim sesi tetap pendek (pesan lain bisa menyelip). */
        private fun readLoop() {
            val buffer = ByteArray(CHUNK_BYTES)
            try {
                val input = socket.getInputStream()
                while (!closed.get()) {
                    val count = input.read(buffer)
                    if (count < 0) {
                        // Aplikasi lokal selesai mengirim (half-close): kabari Mac, tetap tunggu balasannya.
                        localDone = true
                        session()?.sendIfReady(JSONObject().put("t", "TUNNEL_EOF").put("id", id))
                        finishIfDone()
                        return
                    }
                    if (count == 0) continue
                    val s = session() ?: break
                    while (s.pendingOutgoing > MAX_PENDING_FRAMES && !closed.get()) Thread.sleep(2)
                    val frame = ByteArray(HEADER_BYTES + count)
                    frame[0] = MARKER
                    putInt(frame, 1, id)
                    System.arraycopy(buffer, 0, frame, HEADER_BYTES, count)
                    s.sendBinaryIfReady(frame)
                }
            } catch (_: IOException) {
            } catch (_: InterruptedException) {
            }
            close(notify = true)
        }

        /** Mac → aplikasi lokal (thread sendiri: aplikasi yang lambat membaca tidak menahan sesi). */
        private fun writeLoop() {
            try {
                val output = socket.getOutputStream()
                while (true) {
                    val data = incoming.take()
                    if (data === STOP) return
                    if (data === REMOTE_EOF) {
                        remoteDone = true
                        socket.shutdownOutput()
                        finishIfDone()
                        return
                    }
                    output.write(data)
                    output.flush()
                }
            } catch (_: IOException) {
            } catch (_: InterruptedException) {
            }
            close(notify = true)
        }

        private fun finishIfDone() {
            if (localDone && remoteDone) close(notify = false)
        }

        fun close(notify: Boolean) {
            if (!closed.compareAndSet(false, true)) return
            streams.remove(id)
            incoming.offer(STOP)
            try {
                socket.close()
            } catch (_: IOException) {
            }
            if (notify) session()?.sendIfReady(JSONObject().put("t", "TUNNEL_CLOSE").put("id", id))
        }
    }

    /** Pesan dari Mac (thread pembaca sesi). */
    fun handle(type: String, message: JSONObject) {
        when (type) {
            "FORWARD" -> {
                val array = message.optJSONArray("ports")
                setPorts((0 until (array?.length() ?: 0)).map { array!!.optInt(it) })
            }
            "TUNNEL_EOF" -> streams[message.optInt("id")]?.remoteEof()
            "TUNNEL_CLOSE" -> streams[message.optInt("id")]?.close(notify = false)
        }
    }

    /** Frame biner [0x02][id][data] dari Mac (thread pembaca sesi). */
    fun onData(frame: ByteArray) {
        if (frame.size <= HEADER_BYTES) return
        streams[getInt(frame, 1)]?.deliver(frame.copyOfRange(HEADER_BYTES, frame.size))
    }

    /** Sesi berakhir: tutup semua port & aliran (dibuka lagi saat Mac tersambung dan mengirim FORWARD). */
    fun stopAll() {
        for (port in listeners.keys.toList()) stopListening(port)
        for (stream in streams.values.toList()) stream.close(notify = false)
        publish()
    }

    private fun setPorts(ports: List<Int>) {
        val wanted = ports.filter { it in 1024..65535 }.toSet()
        for (port in listeners.keys - wanted) stopListening(port)
        for (port in wanted - listeners.keys) startListening(port)
        publish()
    }

    private fun startListening(port: Int) {
        val sockets = LOOPBACKS.mapNotNull { address ->
            try {
                ServerSocket().apply {
                    reuseAddress = true
                    bind(InetSocketAddress(address, port), BACKLOG)
                }
            } catch (e: IOException) {
                Log.w(TAG, "Port $port tidak bisa dibuka di ${address.hostAddress}: ${e.message}")
                null
            }
        }
        if (sockets.isEmpty()) return
        listeners[port] = sockets
        Log.i(TAG, "Port forwarding aktif: localhost:$port → Mac")
        for (server in sockets) {
            thread(name = "gb-forward-$port", isDaemon = true) { acceptLoop(server, port) }
        }
    }

    private fun acceptLoop(server: ServerSocket, port: Int) {
        while (!server.isClosed) {
            val socket = try {
                server.accept()
            } catch (_: IOException) {
                return
            }
            val s = session()
            if (s == null || !s.authenticated) {
                try {
                    socket.close()
                } catch (_: IOException) {
                }
                continue
            }
            socket.tcpNoDelay = true
            val stream = Stream(nextId.getAndIncrement(), port, socket)
            streams[stream.id] = stream
            s.sendIfReady(JSONObject().put("t", "TUNNEL_OPEN").put("id", stream.id).put("port", port))
            stream.start()
        }
    }

    private fun stopListening(port: Int) {
        for (server in listeners.remove(port).orEmpty()) {
            try {
                server.close()
            } catch (_: IOException) {
            }
        }
        for (stream in streams.values.filter { it.port == port }) stream.close(notify = true)
        Log.i(TAG, "Port forwarding dimatikan: localhost:$port")
    }

    private fun publish() {
        val ports = listeners.keys.sorted()
        BridgeState.update { it.copy(forwardedPorts = ports) }
    }

    companion object {
        private const val TAG = "Cursoe"
        const val MARKER: Byte = 0x02
        private const val HEADER_BYTES = 5
        private const val CHUNK_BYTES = 32 * 1024
        private const val MAX_PENDING_FRAMES = 16
        private const val BACKLOG = 50
        private val LOOPBACKS: List<InetAddress> = listOf(
            InetAddress.getByAddress("localhost", byteArrayOf(127, 0, 0, 1)),
            InetAddress.getByAddress("localhost", ByteArray(16).also { it[15] = 1 }), // ::1
        )
        /** Penanda di antrean tulis (dibandingkan per referensi). */
        private val REMOTE_EOF = ByteArray(0)
        private val STOP = ByteArray(0)

        private fun putInt(bytes: ByteArray, at: Int, value: Int) {
            bytes[at] = (value ushr 24).toByte()
            bytes[at + 1] = (value ushr 16).toByte()
            bytes[at + 2] = (value ushr 8).toByte()
            bytes[at + 3] = value.toByte()
        }

        private fun getInt(bytes: ByteArray, at: Int): Int =
            (bytes[at].toInt() and 0xFF shl 24) or (bytes[at + 1].toInt() and 0xFF shl 16) or
                (bytes[at + 2].toInt() and 0xFF shl 8) or (bytes[at + 3].toInt() and 0xFF)
    }
}
