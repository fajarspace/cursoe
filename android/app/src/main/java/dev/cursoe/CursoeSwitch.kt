package dev.cursoe

import android.Manifest
import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.service.quicksettings.TileService
import android.util.Log
import dev.cursoe.cursor.CursorService
import dev.cursoe.cursor.InputRouter

/**
 * Sakelar utama Cursoe: "Cursoe aktif" = pengguna menyalakannya (Prefs.serviceEnabled) + layanan jaringan.
 *
 * Aksesibilitas cukup dinyalakan SEKALI: mematikan Cursoe hanya menghentikan layanan jaringan (koneksi ke Mac
 * putus, kursor & keyboard dikembalikan), layanan Aksesibilitas tetap aktif tetapi diam. Menyalakan lagi
 * tidak perlu ke Settings. Konsekuensinya: aplikasi yang menolak layanan Aksesibilitas aktif (mis. sebagian
 * aplikasi bank) tetap menolak sampai Aksesibilitas Cursoe dimatikan sendiri di Settings.
 *
 * Menyalakan Aksesibilitas tanpa membuka Settings: butuh WRITE_SECURE_SETTINGS, diberikan sekali via
 * `adb shell pm grant dev.cursoe android.permission.WRITE_SECURE_SETTINGS`.
 * Hanya dipakai untuk menambah layanan Cursoe sendiri ke daftar Aksesibilitas (dan memulai ulangnya).
 *
 * Tanpa izin itu (pengguna biasa), Android TIDAK mengizinkan aplikasi menyalakan Aksesibilitasnya sendiri:
 * pengguna harus menggeser sakelarnya. "Aktifkan" membuka daftar Aksesibilitas dengan Cursoe disorot
 * (bila Settings mendukung), dan begitu layanan tersambung CursorService membawa pengguna kembali ke Cursoe.
 * Halaman detail Aksesibilitas (ACCESSIBILITY_DETAILS_SETTINGS) tidak bisa dipakai: dikunci izin
 * OPEN_ACCESSIBILITY_DETAILS_SETTINGS (signature|installer).
 */
object CursoeSwitch {
    private const val TAG = "Cursoe"

    fun canToggleAccessibility(context: Context): Boolean =
        context.checkSelfPermission(Manifest.permission.WRITE_SECURE_SETTINGS) == PackageManager.PERMISSION_GRANTED

    private fun ourComponent(context: Context) = ComponentName(context, CursorService::class.java)

    /** Layanan Aksesibilitas Cursoe tercatat menyala di Settings. */
    fun isAccessibilityEnabled(context: Context): Boolean {
        val enabled = Settings.Secure.getString(
            context.contentResolver, Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES
        ) ?: return false
        val ours = ourComponent(context)
        return enabled.split(':').any { ComponentName.unflattenFromString(it) == ours }
    }

    fun isOn(context: Context): Boolean =
        Prefs(context).serviceEnabled && (InputRouter.cursorReady || isAccessibilityEnabled(context))

    /**
     * Nyalakan Cursoe. @return false bila layanan Aksesibilitas belum aktif dan tidak bisa
     * dinyalakan otomatis (pengguna perlu membuka Settings Aksesibilitas).
     */
    fun turnOn(context: Context): Boolean {
        Prefs(context).serviceEnabled = true
        val accessibilityOk = isAccessibilityEnabled(context) || setAccessibilityEnabled(context, true)
        // Bila Aksesibilitas baru dinyalakan, CursorService juga akan menyalakan BridgeService.
        if (Permissions.hasLocalNetwork(context)) {
            try {
                BridgeService.start(context)
            } catch (e: RuntimeException) {
                Log.w(TAG, "BridgeService belum bisa dinyalakan dari sini: ${e.message}")
            }
        }
        refreshTile(context)
        return accessibilityOk
    }

    /**
     * Tombol "Aktifkan" Aksesibilitas: langsung menyala bila bisa (izin adb); selain itu buka halaman
     * Aksesibilitas Cursoe dan kembali ke Cursoe otomatis setelah sakelarnya dinyalakan.
     * @return true bila Aksesibilitas sudah menyala.
     */
    fun enableAccessibility(context: Context): Boolean {
        if (turnOn(context)) return true
        openAccessibilitySettings(context, returnAfterEnable = true)
        return false
    }

    /**
     * Daftar Aksesibilitas dengan baris Cursoe disorot. Kunci baris di Settings = nama komponen layanan;
     * extra ":settings:fragment_args_key" diabaikan bila Settings (mis. One UI) tidak mendukungnya.
     */
    fun accessibilitySettingsIntent(context: Context): Intent {
        val key = ourComponent(context).flattenToString()
        return Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS)
            .putExtra(":settings:fragment_args_key", key)
            .putExtra(":settings:show_fragment_args", Bundle().apply { putString(":settings:fragment_args_key", key) })
    }

    /** Tandai: bila layanan tersambung sebentar lagi, bawa pengguna kembali ke Cursoe. */
    fun markReturnAfterEnable(context: Context) {
        Prefs(context).awaitingAccessibilitySince = System.currentTimeMillis()
    }

    fun openAccessibilitySettings(context: Context, returnAfterEnable: Boolean) {
        if (returnAfterEnable) markReturnAfterEnable(context)
        val newTask = if (context is Activity) 0 else Intent.FLAG_ACTIVITY_NEW_TASK
        try {
            context.startActivity(accessibilitySettingsIntent(context).addFlags(newTask))
        } catch (e: ActivityNotFoundException) {
            Log.w(TAG, "Settings Aksesibilitas tidak tersedia: ${e.message}")
        }
    }

    /**
     * Layanan tercatat aktif tetapi tidak berjalan (Android menandainya "tidak berfungsi" setelah crash):
     * matikan lalu nyalakan lagi otomatis. @return false bila tidak punya izin (pengguna perlu ke Settings).
     */
    fun restartAccessibility(context: Context): Boolean {
        if (!canToggleAccessibility(context)) return false
        setAccessibilityEnabled(context, false)
        Handler(Looper.getMainLooper()).postDelayed({ setAccessibilityEnabled(context, true) }, 600)
        return true
    }

    /**
     * Matikan Cursoe: hentikan layanan jaringan (Mac terputus; BridgeService.onDestroy mengembalikan kursor
     * & keyboard). Layanan Aksesibilitas TIDAK dimatikan, jadi menyalakan lagi cukup satu ketukan.
     */
    fun turnOff(context: Context) {
        Prefs(context).serviceEnabled = false
        context.stopService(Intent(context, BridgeService::class.java))
        Log.i(TAG, "Cursoe dimatikan (Aksesibilitas tetap aktif)")
        refreshTile(context)
    }

    private fun setAccessibilityEnabled(context: Context, on: Boolean): Boolean {
        if (!canToggleAccessibility(context)) return false
        val resolver = context.contentResolver
        val ours = ourComponent(context)
        val current = Settings.Secure.getString(resolver, Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES).orEmpty()
        val services = current.split(':').filter { it.isNotBlank() }.toMutableList()
        services.removeAll { ComponentName.unflattenFromString(it) == ours }
        if (on) services += ours.flattenToString()
        return try {
            Settings.Secure.putString(resolver, Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES, services.joinToString(":"))
            if (on) Settings.Secure.putInt(resolver, Settings.Secure.ACCESSIBILITY_ENABLED, 1)
            Log.i(TAG, "Layanan Aksesibilitas Cursoe ${if (on) "dinyalakan" else "dimatikan"} otomatis")
            true
        } catch (e: SecurityException) {
            Log.w(TAG, "Tidak bisa mengubah daftar Aksesibilitas: ${e.message}")
            false
        }
    }

    fun refreshTile(context: Context) {
        TileService.requestListeningState(context, ComponentName(context, CursoeTileService::class.java))
    }
}
