package dev.cursoe

import android.content.Context
import dev.cursoe.net.Wire
import org.json.JSONObject
import java.util.UUID

/** Penyimpanan lokal aplikasi (privat, hanya bisa dibaca aplikasi ini). */
class Prefs(context: Context) {
    private val sp = context.applicationContext.getSharedPreferences("cursoe", Context.MODE_PRIVATE)

    val deviceId: String = sp.getString(KEY_DEVICE_ID, null)
        ?: UUID.randomUUID().toString().also { sp.edit().putString(KEY_DEVICE_ID, it).apply() }

    var serviceEnabled: Boolean
        get() = sp.getBoolean(KEY_SERVICE_ENABLED, true)
        set(value) = sp.edit().putBoolean(KEY_SERVICE_ENABLED, value).apply()

    /** Log rinci ke logcat (tag CursoeDbg). */
    var debugLog: Boolean
        get() = sp.getBoolean(KEY_DEBUG_LOG, false)
        set(value) = sp.edit().putBoolean(KEY_DEBUG_LOG, value).apply()

    /** Layar HP tetap menyala selama terhubung ke Mac. */
    var keepScreenOn: Boolean
        get() = sp.getBoolean(KEY_KEEP_SCREEN_ON, true)
        set(value) = sp.edit().putBoolean(KEY_KEEP_SCREEN_ON, value).apply()

    /**
     * Waktu (ms) pengguna diarahkan ke Settings untuk menyalakan Aksesibilitas Cursoe; 0 = tidak.
     * Saat layanan tersambung dalam rentang waktu itu, CursorService membawa pengguna kembali ke Cursoe.
     */
    var awaitingAccessibilitySince: Long
        get() = sp.getLong(KEY_AWAITING_A11Y, 0L)
        set(value) = sp.edit().putLong(KEY_AWAITING_A11Y, value).apply()

    /** Keyboard sebelum Cursoe Keyboard dipasang otomatis (untuk dikembalikan). */
    var previousIme: String?
        get() = sp.getString(KEY_PREVIOUS_IME, null)
        set(value) = sp.edit().putString(KEY_PREVIOUS_IME, value).commit().let { }

    fun token(macId: String): ByteArray? =
        sp.getString(MAC_PREFIX + macId, null)?.let { json ->
            runCatching { Wire.unb64(JSONObject(json).getString("token")) }.getOrNull()
        }

    fun savePairing(macId: String, macName: String, token: ByteArray) {
        val json = JSONObject()
            .put("name", macName)
            .put("token", Wire.b64(token))
            .put("pairedAt", System.currentTimeMillis())
        sp.edit().putString(MAC_PREFIX + macId, json.toString()).commit()
    }

    fun pairedMacNames(): List<String> =
        sp.all.filterKeys { it.startsWith(MAC_PREFIX) }.values.mapNotNull { value ->
            runCatching { JSONObject(value as String).getString("name") }.getOrNull()
        }

    fun forgetAllMacs() {
        val editor = sp.edit()
        sp.all.keys.filter { it.startsWith(MAC_PREFIX) }.forEach { editor.remove(it) }
        editor.apply()
    }

    private companion object {
        const val KEY_DEVICE_ID = "deviceId"
        const val KEY_SERVICE_ENABLED = "serviceEnabled"
        const val KEY_PREVIOUS_IME = "previousIme"
        const val KEY_KEEP_SCREEN_ON = "keepScreenOn"
        const val KEY_DEBUG_LOG = "debugLog"
        const val KEY_AWAITING_A11Y = "awaitingA11ySince"
        const val MAC_PREFIX = "mac."
    }
}
