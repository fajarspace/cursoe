package dev.cursoe

import android.app.PendingIntent
import android.content.Intent
import android.os.Build
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService

/**
 * Tile Quick Settings "Cursoe": nyalakan/matikan Cursoe dari panel notifikasi.
 * Mematikan hanya memutus Mac; layanan Aksesibilitas tetap aktif (cukup dinyalakan sekali).
 */
class CursoeTileService : TileService() {

    override fun onStartListening() {
        super.onStartListening()
        render()
    }

    override fun onClick() {
        super.onClick()
        if (CursoeSwitch.isOn(this)) {
            CursoeSwitch.turnOff(this)
        } else if (!CursoeSwitch.turnOn(this)) {
            // Tanpa izin WRITE_SECURE_SETTINGS: pengguna perlu menyalakan Aksesibilitas sendiri
            // (halaman khusus Cursoe; setelah menyala kembali ke aplikasi Cursoe).
            CursoeSwitch.markReturnAfterEnable(this)
            openActivity(CursoeSwitch.accessibilitySettingsIntent(this))
        }
        render()
    }

    private fun render() {
        val tile = qsTile ?: return
        val on = CursoeSwitch.isOn(this)
        tile.state = if (on) Tile.STATE_ACTIVE else Tile.STATE_INACTIVE
        tile.label = getString(R.string.app_name)
        if (Build.VERSION.SDK_INT >= 29) tile.subtitle = if (on) tr("On", "Aktif") else tr("Off", "Mati")
        tile.updateTile()
    }

    private fun openActivity(intent: Intent) {
        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        if (Build.VERSION.SDK_INT >= 34) {
            startActivityAndCollapse(PendingIntent.getActivity(this, 0, intent, PendingIntent.FLAG_IMMUTABLE))
        } else {
            @Suppress("DEPRECATION")
            startActivityAndCollapse(intent)
        }
    }
}
