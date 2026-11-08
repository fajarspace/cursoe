package dev.cursoe

import android.app.Activity
import android.content.Intent
import android.os.Bundle
import android.provider.Settings
import android.view.View
import android.widget.ImageButton
import android.widget.ScrollView
import android.widget.Switch
import android.widget.TextView
import dev.cursoe.ime.KeyboardStatus
import dev.cursoe.ui.GlassBar
import dev.cursoe.ui.SkyDrawable
import dev.cursoe.ui.SystemBars

/** Pengaturan: layar menyala, izin, Mac yang dipair, log debug. (Kecepatan kursor diatur di Mac.) */
class SettingsActivity : Activity() {

    private lateinit var prefs: Prefs
    private lateinit var accessibilityStatus: TextView
    private lateinit var keyboardStatus: TextView
    private lateinit var paired: TextView
    private lateinit var tetherStatus: TextView
    private val sky by lazy { SkyDrawable(this) }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_settings)
        prefs = Prefs(this)

        findViewById<ImageButton>(R.id.header_button).apply {
            setImageResource(R.drawable.ic_back)
            contentDescription = getString(R.string.back)
            setOnClickListener { finish() }
        }
        findViewById<TextView>(R.id.header_title).setText(R.string.settings)
        val root = findViewById<View>(R.id.root)
        val header = findViewById<GlassBar>(R.id.header)
        val scroll = findViewById<ScrollView>(R.id.scroll)
        SystemBars.apply(this, root, header, listOf(scroll), getColor(R.color.gb_bg))

        // Latar berkabut + header kaca melayang: konten di-scroll di bawahnya dan diburamkan.
        root.background = sky
        sky.onFrame = { if (header.progress > 0f) header.invalidate() }
        header.scrollSource = scroll
        header.backdrop = root
        header.addOnLayoutChangeListener { _, _, top, _, bottom, _, _, _, _ ->
            val height = bottom - top
            if (scroll.paddingTop != height) scroll.setPadding(scroll.paddingLeft, height, scroll.paddingRight, scroll.paddingBottom)
        }
        val fadeDistance = 24 * resources.displayMetrics.density
        scroll.setOnScrollChangeListener { _, _, y, _, _ ->
            header.progress = y / fadeDistance
            header.invalidate() // konten di bawah kaca bergeser → perbarui blur
        }

        findViewById<Switch>(R.id.keep_screen_on).apply {
            isChecked = prefs.keepScreenOn
            setOnCheckedChangeListener { _, on ->
                prefs.keepScreenOn = on
                BridgeState.refresh()
            }
        }

        accessibilityStatus = findViewById(R.id.accessibility_status)
        keyboardStatus = findViewById(R.id.keyboard_status)
        paired = findViewById(R.id.paired)
        findViewById<View>(R.id.row_accessibility).setOnClickListener {
            CursoeSwitch.openAccessibilitySettings(this, returnAfterEnable = false)
        }
        findViewById<View>(R.id.row_keyboard).setOnClickListener {
            open(Intent(Settings.ACTION_INPUT_METHOD_SETTINGS))
        }
        tetherStatus = findViewById(R.id.tether_status)
        findViewById<View>(R.id.row_tether).setOnClickListener { openTetherSettings() }
        findViewById<View>(R.id.forget).setOnClickListener {
            prefs.forgetAllMacs()
            renderPaired()
        }

        findViewById<Switch>(R.id.debug_log).apply {
            isChecked = prefs.debugLog
            setOnCheckedChangeListener { _, on ->
                prefs.debugLog = on
                DebugLog.enabled = on
            }
        }
        findViewById<TextView>(R.id.version).text = "Cursoe ${BuildConfig.VERSION_NAME}"
    }

    override fun onResume() {
        super.onResume()
        sky.start()
        val s = BridgeState.current
        accessibilityStatus.text = when {
            s.cursorReady -> "Aktif"
            CursoeSwitch.isAccessibilityEnabled(this) -> "Aktif, tetapi tidak berjalan. Matikan, lalu aktifkan kembali."
            else -> "Belum aktif"
        }
        keyboardStatus.text = if (KeyboardStatus.isEnabled(this)) "Aktif" else "Belum aktif"
        tetherStatus.text = when (UsbTether.mode()) {
            UsbTether.Mode.NCM -> "Aktif (NCM). Mac terhubung melalui kabel USB."
            UsbTether.Mode.RNDIS -> "Aktif (RNDIS). Mode ini tidak didukung Mac; gunakan mode NCM."
            UsbTether.Mode.OFF -> "Nonaktif. Aktifkan setelah kabel USB tersambung ke Mac."
        }
        renderPaired()
    }

    override fun onPause() {
        sky.stop()
        super.onPause()
    }

    private fun renderPaired() {
        val names = prefs.pairedMacNames()
        paired.text = if (names.isEmpty()) "Belum ada" else names.joinToString("\n")
    }

    /** Halaman Tethering USB (nama halamannya berbeda antar merek; cadangan: pengaturan jaringan). */
    private fun openTetherSettings() {
        val candidates = listOf(
            Intent().setClassName("com.android.settings", "com.android.settings.TetherSettings"),
            Intent().setClassName("com.android.settings", "com.android.settings.Settings\$TetherSettingsActivity"),
            Intent(Settings.ACTION_WIRELESS_SETTINGS),
        )
        for (intent in candidates) {
            try {
                startActivity(intent)
                return
            } catch (_: RuntimeException) {
            }
        }
    }

    private fun open(intent: Intent) {
        try {
            startActivity(intent)
        } catch (e: RuntimeException) {
            android.util.Log.w("Cursoe", "Tidak bisa membuka ${intent.action}", e)
        }
    }
}
