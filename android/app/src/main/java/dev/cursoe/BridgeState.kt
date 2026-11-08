package dev.cursoe

import android.os.Handler
import android.os.Looper
import java.util.concurrent.CopyOnWriteArrayList

/** Status bersama antara service dan Activity. Listener selalu dipanggil di main thread. */
object BridgeState {
    data class Snapshot(
        val serviceRunning: Boolean = false,
        val connected: Boolean = false,
        val status: String = "Layanan mati",
        val macName: String? = null,
        val pin: String? = null,
        val pinFor: String? = null,
        val port: Int = 0,
        val ip: String? = null,
        val screen: String = "",
        val remote: Boolean = false,
        val cursorReady: Boolean = false,
    )

    @Volatile
    var current = Snapshot()
        private set

    private val listeners = CopyOnWriteArrayList<(Snapshot) -> Unit>()
    private val main = Handler(Looper.getMainLooper())

    fun update(change: (Snapshot) -> Snapshot) {
        val snapshot = synchronized(this) { change(current).also { current = it } }
        main.post { listeners.forEach { it(snapshot) } }
    }

    /** Beri tahu semua listener ulang (mis. setelah pengaturan berubah). */
    fun refresh() = update { it }

    fun observe(listener: (Snapshot) -> Unit) {
        listeners += listener
        listener(current)
    }

    fun remove(listener: (Snapshot) -> Unit) {
        listeners -= listener
    }
}
