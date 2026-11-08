package dev.cursoe.net

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.util.Log
import dev.cursoe.tr
import java.io.IOException
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetSocketAddress
import java.net.ServerSocket
import kotlin.concurrent.thread

/**
 * Server TCP + iklan Bonjour/NSD `_cursoe._tcp`.
 * Hanya satu sesi aktif; koneksi baru dari Mac menggantikan yang lama
 * (berguna saat Mac bangun dari sleep dan koneksi lama "menggantung").
 *
 * Ditambah penjawab UDP di port yang sama: Mac mengirim "CURSOE?" ke gateway jaringan
 * tethering USB, HP menjawab id & namanya. Dengan begitu Mac tahu pasti jaringan kabel itu
 * milik HP ini tanpa membuka koneksi TCP (yang akan menggantikan sesi aktif).
 */
class BridgeServer(
    private val context: Context,
    private val host: Session.Host,
    private val onListening: (port: Int) -> Unit,
) {
    private val lock = Any()
    private var serverSocket: ServerSocket? = null
    private var probeSocket: DatagramSocket? = null
    private var registration: NsdManager.RegistrationListener? = null
    private var running = false

    @Volatile var current: Session? = null
        private set

    /** Jangan dipanggil di main thread. */
    fun start() {
        synchronized(lock) {
            if (running) return
            running = true
            val ss = openServerSocket()
            serverSocket = ss
            Log.i(TAG, "Server mendengarkan di port ${ss.localPort}")
            registerNsd(ss.localPort)
            onListening(ss.localPort)
            thread(name = "gb-accept", isDaemon = true) { acceptLoop(ss) }
            openProbeResponder(ss.localPort)
        }
    }

    /** Jangan dipanggil di main thread. */
    fun stop() {
        synchronized(lock) {
            if (!running) return
            running = false
            unregisterNsd()
            try {
                serverSocket?.close()
            } catch (_: IOException) {
            }
            serverSocket = null
            probeSocket?.close()
            probeSocket = null
            current?.close(tr("service stopped", "layanan dimatikan"))
            current = null
        }
    }

    /** Port tetap memudahkan koneksi manual lewat IP; bila terpakai, pakai port acak. */
    private fun openServerSocket(): ServerSocket {
        val fixed = ServerSocket()
        return try {
            fixed.reuseAddress = true
            fixed.bind(InetSocketAddress(DEFAULT_PORT))
            fixed
        } catch (e: IOException) {
            fixed.close()
            Log.w(TAG, "Port $DEFAULT_PORT terpakai (${e.message}); pakai port acak")
            ServerSocket(0)
        }
    }

    private fun acceptLoop(ss: ServerSocket) {
        while (true) {
            val socket = try {
                ss.accept()
            } catch (_: IOException) {
                break // server ditutup
            }
            Log.i(TAG, "Koneksi masuk dari ${socket.inetAddress?.hostAddress}")
            val session = Session(socket, host)
            val previous = current
            current = session
            previous?.close(tr("replaced by a new connection", "digantikan koneksi baru"))
            session.start()
        }
    }

    /** Penjawab "CURSOE?" (UDP). Jawaban kecil & hanya untuk permintaan yang persis sama. */
    private fun openProbeResponder(listenPort: Int) {
        val socket = try {
            DatagramSocket(listenPort)
        } catch (e: IOException) {
            Log.w(TAG, "Penjawab UDP tidak aktif: ${e.message}")
            return
        }
        probeSocket = socket
        thread(name = "gb-probe", isDaemon = true) {
            val buffer = ByteArray(64)
            while (true) {
                val packet = DatagramPacket(buffer, buffer.size)
                try {
                    socket.receive(packet)
                } catch (_: IOException) {
                    break // ditutup
                }
                if (String(packet.data, 0, packet.length, Charsets.UTF_8) != PROBE_REQUEST) continue
                val name = host.deviceName.replace('\n', ' ').take(80)
                val reply = "$PROBE_REPLY id=${host.deviceId} port=$listenPort name=$name".toByteArray(Charsets.UTF_8)
                runCatching { socket.send(DatagramPacket(reply, reply.size, packet.socketAddress)) }
                Log.d(TAG, "Probe UDP dari ${packet.address?.hostAddress} dijawab")
            }
        }
    }

    private fun registerNsd(listenPort: Int) {
        val nsd = context.getSystemService(NsdManager::class.java)
        val name = host.deviceName
        val id = host.deviceId
        val info = NsdServiceInfo().apply {
            serviceName = name
            serviceType = SERVICE_TYPE
            port = listenPort
            setAttribute("id", id)
            setAttribute("v", "1")
        }
        val listener = object : NsdManager.RegistrationListener {
            override fun onServiceRegistered(info: NsdServiceInfo) {
                Log.i(TAG, "NSD terdaftar sebagai \"${info.serviceName}\"")
            }

            override fun onRegistrationFailed(info: NsdServiceInfo, errorCode: Int) {
                Log.w(TAG, "NSD gagal mendaftar (kode $errorCode)")
            }

            override fun onServiceUnregistered(info: NsdServiceInfo) = Unit
            override fun onUnregistrationFailed(info: NsdServiceInfo, errorCode: Int) = Unit
        }
        registration = listener
        nsd.registerService(info, NsdManager.PROTOCOL_DNS_SD, listener)
    }

    private fun unregisterNsd() {
        val listener = registration ?: return
        registration = null
        try {
            context.getSystemService(NsdManager::class.java).unregisterService(listener)
        } catch (e: IllegalArgumentException) {
            Log.w(TAG, "NSD unregister: ${e.message}")
        }
    }

    companion object {
        private const val TAG = "Cursoe"
        const val SERVICE_TYPE = "_cursoe._tcp"
        const val DEFAULT_PORT = 47800
        private const val PROBE_REQUEST = "CURSOE?"
        private const val PROBE_REPLY = "CURSOE!"
    }
}
