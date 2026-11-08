package dev.cursoe

import android.animation.ObjectAnimator
import android.animation.PropertyValuesHolder
import android.animation.ValueAnimator
import android.app.Activity
import android.content.Intent
import android.content.res.Configuration
import android.graphics.Color
import android.graphics.Typeface
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.widget.LinearLayout
import android.widget.TextView
import android.widget.Toast
import dev.cursoe.ime.KeyboardStatus
import dev.cursoe.ui.SystemBars

/**
 * Halaman utama: satu tombol power besar (nyala/mati Cursoe) di panel bawah, ilustrasi atau
 * PIN pairing di tengah, dan pengingat bila Aksesibilitas/Keyboard Cursoe belum aktif.
 */
class MainActivity : Activity() {

    private lateinit var prefs: Prefs
    private lateinit var banners: ViewGroup
    private lateinit var illustration: View
    private lateinit var pinCard: View
    private lateinit var pinText: TextView
    private lateinit var pinHint: TextView
    private lateinit var stateTitle: TextView
    private lateinit var stateSubtitle: TextView
    private lateinit var stateHint: TextView
    private lateinit var power: View
    private lateinit var powerIcon: android.widget.ImageView
    private val sky by lazy { dev.cursoe.ui.SkyDrawable(this) }
    private lateinit var halo: View
    private var pulse: ObjectAnimator? = null
    private var bannerKey = ""

    private var setupDialog: SetupDialog? = null
    /** "Nanti" ditekan: pengingat tidak muncul otomatis lagi sampai aplikasi dibuka ulang. */
    private var setupPostponed = false
    private val main = Handler(Looper.getMainLooper())
    private val promptSetup = Runnable { maybePromptSetup() }
    private val observer: (BridgeState.Snapshot) -> Unit = { render(it) }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_main)
        prefs = Prefs(this)
        setupPostponed = savedInstanceState?.getBoolean(KEY_POSTPONED) ?: false

        banners = findViewById(R.id.banners)
        illustration = findViewById(R.id.illustration)
        pinCard = findViewById(R.id.pin_card)
        pinText = findViewById(R.id.pin)
        pinHint = findViewById(R.id.pin_hint)
        stateTitle = findViewById(R.id.state_title)
        stateSubtitle = findViewById(R.id.state_subtitle)
        stateHint = findViewById(R.id.state_hint)
        power = findViewById(R.id.power)
        powerIcon = findViewById(R.id.power_icon)
        halo = findViewById(R.id.halo)

        val panel = findViewById<View>(R.id.panel)
        val landscape = resources.configuration.orientation == Configuration.ORIENTATION_LANDSCAPE
        // Latar berkabut seperti website (cahaya biru buram yang bergerak pelan).
        findViewById<View>(R.id.root).background = sky
        SystemBars.apply(
            this, findViewById(R.id.root), findViewById(R.id.header),
            if (landscape) listOf(panel, findViewById(R.id.top_area)) else listOf(panel),
            getColor(R.color.gb_bg),
        )

        findViewById<View>(R.id.header_button).setOnClickListener {
            startActivity(Intent(this, SettingsActivity::class.java))
        }
        power.setOnClickListener { onPowerTapped() }
        requestRuntimePermissions()
    }

    override fun onSaveInstanceState(outState: Bundle) {
        super.onSaveInstanceState(outState)
        outState.putBoolean(KEY_POSTPONED, setupPostponed)
    }

    override fun onStart() {
        super.onStart()
        BridgeState.observe(observer)
    }

    override fun onResume() {
        super.onResume()
        sky.start()
        maybeStartService() // izin mungkin baru diberikan lewat Settings
        render(BridgeState.current)
        // Beri jeda agar status Aksesibilitas/Keyboard yang baru diubah sempat terbaca.
        main.postDelayed(promptSetup, 600)
    }

    override fun onPause() {
        sky.stop()
        main.removeCallbacks(promptSetup)
        super.onPause()
    }

    override fun onStop() {
        BridgeState.remove(observer)
        stopPulse()
        super.onStop()
    }

    override fun onDestroy() {
        setupDialog?.dismiss()
        setupDialog = null
        super.onDestroy()
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (!Permissions.hasLocalNetwork(this) && Build.VERSION.SDK_INT >= 37 &&
            !shouldShowRequestPermissionRationale(android.Manifest.permission.ACCESS_LOCAL_NETWORK)
        ) {
            openAppDetails() // ditolak permanen: arahkan ke halaman izin aplikasi
        }
        maybeStartService()
        render(BridgeState.current)
        main.postDelayed(promptSetup, 300)
    }

    // region Aksi

    private fun onPowerTapped() {
        if (cursoeWanted(BridgeState.current)) {
            CursoeSwitch.turnOff(this)
        } else {
            setupPostponed = false
            CursoeSwitch.turnOn(this) // Aksesibilitas yang belum aktif → pengingat di bawah
            if (!Permissions.hasLocalNetwork(this)) requestRuntimePermissions()
            main.postDelayed(promptSetup, 300)
        }
        render(BridgeState.current)
    }

    private fun maybePromptSetup() {
        if (isFinishing || isDestroyed) return
        val needed = cursoeWanted(BridgeState.current) && Permissions.hasLocalNetwork(this) && !setupComplete()
        if (needed && !setupPostponed) showSetup()
    }

    private fun showSetup() {
        val dialog = setupDialog ?: SetupDialog(this) { setupPostponed = true }.also { setupDialog = it }
        if (dialog.isShowing) dialog.refresh() else dialog.show()
    }

    private fun maybeStartService() {
        if (prefs.serviceEnabled && Permissions.hasLocalNetwork(this) && !BridgeState.current.serviceRunning) {
            BridgeService.start(this)
        }
    }

    private fun requestRuntimePermissions() {
        val wanted = Permissions.runtimeWanted(this)
        if (wanted.isNotEmpty()) requestPermissions(wanted.toTypedArray(), 1)
    }

    private fun openAppDetails() = open(
        Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, android.net.Uri.fromParts("package", packageName, null))
    )

    private fun open(intent: Intent) {
        try {
            startActivity(intent)
        } catch (e: RuntimeException) {
            android.util.Log.w("Cursoe", "Tidak bisa membuka ${intent.action}", e)
        }
    }

    // endregion

    // region Tampilan

    /** Pengguna ingin Cursoe menyala (tombol power dalam posisi "on"). */
    private fun cursoeWanted(s: BridgeState.Snapshot) = prefs.serviceEnabled || s.serviceRunning

    private fun setupComplete() = CursoeSwitch.isAccessibilityEnabled(this) && KeyboardStatus.isEnabled(this)

    private fun render(s: BridgeState.Snapshot) {
        val wanted = cursoeWanted(s)
        val network = Permissions.hasLocalNetwork(this)
        val accessibility = CursoeSwitch.isAccessibilityEnabled(this)
        val keyboard = KeyboardStatus.isEnabled(this)

        val (title, subtitle) = when {
            !wanted -> "Ketuk untuk menyalakan" to ""
            !network -> "Butuh izin jaringan" to "Agar Mac bisa menemukan HP ini"
            !accessibility -> "Penyiapan belum selesai" to "Aktifkan Aksesibilitas Cursoe"
            s.remote -> "Kursor Mac aktif" to (s.macName ?: "")
            s.connected -> "Terhubung" to (s.macName ?: "")
            s.serviceRunning -> "Menunggu Mac…" to
                (s.ip?.let { if (s.port > 0) "$it:${s.port}" else it } ?: "")
            else -> "Menyalakan…" to ""
        }
        stateTitle.text = title
        stateSubtitle.text = subtitle
        stateSubtitle.visibility = if (subtitle.isEmpty()) View.GONE else View.VISIBLE
        val hint = if (wanted && s.connected && s.cursorReady && !s.remote) "⌘⌥T di Mac untuk mulai" else ""
        stateHint.text = hint
        stateHint.visibility = if (hint.isEmpty()) View.GONE else View.VISIBLE

        // Nyala: lingkaran biru merek, ikon putih. Mati: lingkaran kaca, ikon warna teks.
        power.setBackgroundResource(if (wanted) R.drawable.bg_power_on else R.drawable.bg_power_off)
        powerIcon.imageTintList = android.content.res.ColorStateList.valueOf(
            if (wanted) Color.WHITE else getColor(R.color.gb_text),
        )
        power.contentDescription = getString(if (wanted) R.string.power_off else R.string.power_on)
        val waiting = wanted && network && accessibility && s.serviceRunning && !s.connected
        updateHalo(waiting, wanted)

        val pairing = s.pin != null
        pinCard.visibility = if (pairing) View.VISIBLE else View.GONE
        illustration.visibility = if (pairing) View.INVISIBLE else View.VISIBLE
        pinText.text = s.pin?.chunked(3)?.joinToString(" ") ?: ""
        pinHint.text = "Ketik PIN ini di ${s.pinFor ?: "Mac"}"

        renderBanners(s, wanted, network, accessibility, keyboard)

        setupDialog?.takeIf { it.isShowing }?.let { dialog ->
            if (dialog.refresh() || !wanted) {
                dialog.dismiss()
                if (wanted) Toast.makeText(this, "Cursoe siap dipakai", Toast.LENGTH_SHORT).show()
            }
        }
    }

    private fun renderBanners(
        s: BridgeState.Snapshot, wanted: Boolean, network: Boolean, accessibility: Boolean, keyboard: Boolean,
    ) {
        val stalled = accessibility && s.serviceRunning && !s.cursorReady
        val key = "$wanted$network$accessibility$keyboard$stalled"
        if (key == bannerKey) return
        bannerKey = key
        banners.removeAllViews()
        if (!wanted) return
        if (!network) addBanner("Izin jaringan lokal belum diberikan", "Izinkan") { requestRuntimePermissions() }
        if (!accessibility) {
            addBanner("Aksesibilitas Cursoe belum aktif", "Aktifkan") {
                CursoeSwitch.enableAccessibility(this)
                render(BridgeState.current)
            }
        } else if (stalled) {
            // Android menandai layanan "tidak berfungsi" setelah aplikasi crash.
            addBanner("Aksesibilitas tidak berjalan. Matikan lalu nyalakan lagi.", "Perbaiki") {
                // Dengan izin adb: dimulai ulang otomatis; selain itu halaman Aksesibilitas Cursoe.
                if (!CursoeSwitch.restartAccessibility(this)) CursoeSwitch.openAccessibilitySettings(this, true)
            }
        }
        if (!keyboard) addBanner("Cursoe Keyboard belum aktif", "Aktifkan") { showSetup() }
    }

    private fun addBanner(text: String, action: String, onClick: () -> Unit) {
        val d = resources.displayMetrics.density
        val row = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setBackgroundResource(R.drawable.bg_banner)
            setPadding((16 * d).toInt(), (10 * d).toInt(), (10 * d).toInt(), (10 * d).toInt())
            layoutParams = LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT,
            ).apply { bottomMargin = (8 * d).toInt() }
        }
        row.addView(TextView(this).apply {
            this.text = "⚠︎  $text"
            setTextColor(getColor(R.color.gb_text))
            textSize = 14f
            layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
        })
        row.addView(TextView(this).apply {
            this.text = action
            setTextColor(Color.WHITE)
            textSize = 13f
            setTypeface(typeface, Typeface.BOLD)
            gravity = Gravity.CENTER
            minHeight = (34 * d).toInt()
            setPadding((14 * d).toInt(), 0, (14 * d).toInt(), 0)
            setBackgroundResource(R.drawable.bg_pill)
            layoutParams = LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.WRAP_CONTENT, LinearLayout.LayoutParams.WRAP_CONTENT,
            ).apply { marginStart = (12 * d).toInt() }
            setOnClickListener { onClick() }
        })
        banners.addView(row)
    }

    /** Lingkaran di belakang tombol: berdenyut saat menunggu Mac, diam saat lainnya. */
    private fun updateHalo(waiting: Boolean, active: Boolean) {
        if (waiting) {
            if (pulse == null) {
                pulse = ObjectAnimator.ofPropertyValuesHolder(
                    halo,
                    PropertyValuesHolder.ofFloat(View.SCALE_X, 0.72f, 1.12f),
                    PropertyValuesHolder.ofFloat(View.SCALE_Y, 0.72f, 1.12f),
                    PropertyValuesHolder.ofFloat(View.ALPHA, 1f, 0f),
                ).apply {
                    duration = 1600
                    repeatCount = ValueAnimator.INFINITE
                    start()
                }
            }
            return
        }
        stopPulse()
        halo.scaleX = 1f
        halo.scaleY = 1f
        halo.alpha = if (active) 1f else 0.4f
    }

    private fun stopPulse() {
        pulse?.cancel()
        pulse = null
    }

    // endregion

    private companion object {
        const val KEY_POSTPONED = "setupPostponed"
    }
}
