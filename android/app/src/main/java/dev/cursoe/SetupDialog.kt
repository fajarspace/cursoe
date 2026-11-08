package dev.cursoe

import android.app.Activity
import android.app.Dialog
import android.content.Intent
import android.graphics.Color
import android.graphics.drawable.ColorDrawable
import android.net.Uri
import android.os.Build
import android.provider.Settings
import android.util.Log
import android.view.View
import android.view.Window
import android.view.WindowManager
import android.widget.TextView
import dev.cursoe.ime.KeyboardStatus

/**
 * Pengingat penyiapan: Aksesibilitas (kursor & gestur) dan Cursoe Keyboard (mengetik).
 * Muncul otomatis selama Cursoe dinyalakan tetapi salah satunya belum aktif.
 */
class SetupDialog(private val activity: Activity, private val onLater: () -> Unit) : Dialog(activity) {

    private val stepAccessibility: TextView
    private val stepKeyboard: TextView
    private val actionAccessibility: TextView
    private val actionKeyboard: TextView
    private val restrictedHint: View

    init {
        requestWindowFeature(Window.FEATURE_NO_TITLE)
        setContentView(R.layout.dialog_setup)
        window?.setBackgroundDrawable(ColorDrawable(Color.TRANSPARENT))
        stepAccessibility = findViewById(R.id.step_accessibility)
        stepKeyboard = findViewById(R.id.step_keyboard)
        actionAccessibility = findViewById(R.id.action_accessibility)
        actionKeyboard = findViewById(R.id.action_keyboard)
        restrictedHint = findViewById(R.id.restricted_hint)

        actionAccessibility.setOnClickListener {
            // Dengan izin WRITE_SECURE_SETTINGS (adb) langsung menyala; selain itu halaman Aksesibilitas Cursoe.
            CursoeSwitch.enableAccessibility(activity)
            refresh()
        }
        actionKeyboard.setOnClickListener { open(Intent(Settings.ACTION_INPUT_METHOD_SETTINGS)) }
        restrictedHint.setOnClickListener {
            open(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.fromParts("package", activity.packageName, null)))
        }
        findViewById<View>(R.id.later).setOnClickListener {
            onLater()
            dismiss()
        }
        setOnCancelListener { onLater() }
    }

    override fun onStart() {
        super.onStart()
        val metrics = activity.resources.displayMetrics
        val width = minOf(metrics.widthPixels - (32 * metrics.density).toInt(), (440 * metrics.density).toInt())
        window?.setLayout(width, WindowManager.LayoutParams.WRAP_CONTENT)
        refresh()
    }

    /** @return true bila semua langkah sudah selesai. */
    fun refresh(): Boolean {
        val accessibility = CursoeSwitch.isAccessibilityEnabled(activity)
        val keyboard = KeyboardStatus.isEnabled(activity)
        showStep(stepAccessibility, actionAccessibility, "1", accessibility)
        showStep(stepKeyboard, actionKeyboard, "2", keyboard)
        // "Setelan terbatas" (Android 13+) memblokir Aksesibilitas aplikasi yang dipasang dari APK.
        restrictedHint.visibility = if (!accessibility && Build.VERSION.SDK_INT >= 33) View.VISIBLE else View.GONE
        return accessibility && keyboard
    }

    private fun showStep(step: TextView, action: TextView, number: String, done: Boolean) {
        step.text = if (done) "✓" else number
        step.setBackgroundResource(if (done) R.drawable.bg_step_done else R.drawable.bg_step)
        step.setTextColor(if (done) Color.WHITE else activity.getColor(R.color.gb_text))
        action.visibility = if (done) View.INVISIBLE else View.VISIBLE
    }

    private fun open(intent: Intent) {
        try {
            activity.startActivity(intent)
        } catch (e: RuntimeException) {
            Log.w("Cursoe", "Tidak bisa membuka ${intent.action}", e)
        }
    }
}
