package dev.cursoe

import android.util.Log

/**
 * Log debug yang bisa dinyalakan/dimatikan saat berjalan.
 * Build debug: adb shell am broadcast -a dev.cursoe.debug.LOG --ez on true
 * Lihat: adb logcat -s CursoeDbg
 */
object DebugLog {
    const val TAG = "CursoeDbg"

    @Volatile var enabled = false

    inline fun d(message: () -> String) {
        if (enabled) Log.d(TAG, message())
    }
}
