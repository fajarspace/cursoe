package dev.cursoe.cursor

import android.os.Handler
import android.os.Looper
import android.util.Log
import dev.cursoe.BridgeState
import org.json.JSONObject

/**
 * Jembatan antara BridgeService (pesan jaringan, thread pembaca) dan
 * CursorService (AccessibilityService, main thread). Satu proses, jadi cukup singleton.
 */
object InputRouter {
    private const val TAG = "Cursoe"
    private val main = Handler(Looper.getMainLooper())

    @Volatile private var cursor: CursorService? = null
    @Volatile private var keyboard: dev.cursoe.ime.CursoeKeyboardService? = null

    fun attachKeyboard(service: dev.cursoe.ime.CursoeKeyboardService) {
        keyboard = service
    }

    fun detachKeyboard(service: dev.cursoe.ime.CursoeKeyboardService) {
        if (keyboard === service) keyboard = null
    }

    /** Dipanggil (main thread) saat AccessibilityService aktif/nonaktif. */
    @Volatile var onReadyChanged: (() -> Unit)? = null

    val cursorReady: Boolean get() = cursor != null

    /** Dipasang BridgeService: baca clipboard HP selagi Cursoe Keyboard masih aktif. */
    @Volatile var beforeKeyboardRestore: (() -> Unit)? = null

    /** Dipasang BridgeService: kirim LEAVE(yRatio) ke Mac. Dipanggil di main thread. */
    @Volatile var onLeave: ((Double) -> Unit)? = null

    fun notifyLeave(yRatio: Double) {
        onLeave?.invoke(yRatio)
    }

    fun attach(service: CursorService) {
        cursor = service
        BridgeState.update { it.copy(cursorReady = true) }
        main.post { onReadyChanged?.invoke() }
    }

    fun detach(service: CursorService) {
        if (cursor !== service) return
        cursor = null
        BridgeState.update { it.copy(cursorReady = false, remote = false) }
        main.post { onReadyChanged?.invoke() }
    }

    /** Dipanggil dari thread pembaca jaringan. */
    fun handle(type: String, message: JSONObject) {
        main.post {
            val c = cursor ?: return@post
            when (type) {
                "ENTER" -> c.enter(
                    message.optDouble("yRatio", 0.5),
                    message.optString("from", "center"),
                    message.optString("macEdge", "left"),
                )
                "EXIT" -> c.exit()
                "MOVE" -> c.move(message.optDouble("dx").toFloat(), message.optDouble("dy").toFloat(), message.optLong("ts"))
                "BUTTON" -> c.button(message.optInt("button"), message.optBoolean("down"))
                "SCROLL" -> c.scroll(
                    message.optDouble("dx").toFloat(), message.optDouble("dy").toFloat(),
                    message.optLong("ts"), message.optBoolean("end"),
                )
                "PINCH" -> c.pinch(
                    message.optDouble("mag").toFloat(), message.optLong("ts"), message.optBoolean("end"),
                )
                "SMART_ZOOM" -> c.smartZoom()
                "NAV" -> if (c.isActive) c.nav(message.optString("action"))
                "TEXT" -> if (c.isActive) {
                    keyboard?.commitText(message.optString("text"))
                        ?: Log.w(TAG, "TEXT diabaikan: Cursoe Keyboard tidak aktif")
                }
                "KEY" -> if (c.isActive) {
                    val key = message.optString("key")
                    val mods = message.optJSONArray("mods")?.let { arr -> (0 until arr.length()).map { arr.optString(it) }.toSet() }
                        ?: emptySet()
                    if (!c.globalKey(key, mods)) {
                        val handled = keyboard?.key(key, mods) ?: false
                        if (!handled) Log.d(TAG, "KEY $key $mods tidak ditangani")
                    }
                }
                else -> Log.d(TAG, "Pesan tidak dikenal: $type")
            }
        }
    }

    /** Koneksi ke Mac putus: sembunyikan kursor. */
    fun disconnected() {
        main.post { cursor?.exit() }
    }
}
