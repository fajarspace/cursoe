package dev.cursoe.cursor

import android.Manifest
import android.accessibilityservice.AccessibilityService
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import dev.cursoe.BuildConfig
import dev.cursoe.DebugLog
import android.graphics.PixelFormat
import android.hardware.display.DisplayManager
import android.os.Build
import android.os.SystemClock
import android.util.DisplayMetrics
import android.util.Log
import android.view.Display
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.view.WindowManager
import android.view.accessibility.AccessibilityEvent
import android.widget.FrameLayout
import dev.cursoe.BridgeService
import dev.cursoe.BridgeState
import dev.cursoe.CursoeSwitch
import dev.cursoe.Permissions
import dev.cursoe.Prefs
import dev.cursoe.files.DropStrip
import dev.cursoe.ime.KeyboardStatus

/**
 * AccessibilityService Cursoe.
 * M2: overlay kursor (TYPE_ACCESSIBILITY_OVERLAY, tidak menerima sentuhan) yang
 * digerakkan oleh delta dari Mac. Semua method dipanggil di main thread.
 */
class CursorService : AccessibilityService() {

    private var windowManager: WindowManager? = null
    private var overlay: FrameLayout? = null
    private var pointer: CursorView? = null

    // Posisi ujung kursor dalam piksel layar (koordinat yang sama dengan dispatchGesture).
    private var x = 0f
    private var y = 0f
    private var lastWidth = 0
    private var lastHeight = 0

    val isActive: Boolean get() = overlay != null

    // Kembali ke Mac lewat tepi: tepi HP yang menghadap Mac & akumulasi dorongan (point Mac).
    private var macEdge = "left"
    private var pushAccumulated = 0f
    private var lastPushAt = 0L
    private var enteredAt = 0L
    private var screenOffReceiver: BroadcastReceiver? = null
    private val mainHandler = android.os.Handler(android.os.Looper.getMainLooper())

    // Layar tetap menyala selama terhubung ke Mac (jendela 1×1 px dengan FLAG_KEEP_SCREEN_ON).
    private var keepAwakeView: View? = null
    private val stateObserver: (BridgeState.Snapshot) -> Unit = { s ->
        updateKeepAwake(s.connected && Prefs(this).keepScreenOn)
    }

    private val gestures = GestureController(this, cursor = { x to y }, screen = { screenSize() })
    private var dropStrip: DropStrip? = null
    /** ⌘⇧S: screenshot pilih area (Android 11+). Dibuat malas: butuh context yang sudah terpasang. */
    private val snip: ScreenSnip? by lazy {
        if (Build.VERSION.SDK_INT >= 30) ScreenSnip(this) { pointer?.visibility = View.VISIBLE } else null
    }
    private val hideDropStrip = Runnable { dropStrip?.hide() }

    override fun onServiceConnected() {
        super.onServiceConnected()
        windowManager = getSystemService(WindowManager::class.java)
        dropStrip = DropStrip(this, windowManager!!) {
            // File sudah dilepas di tepi Mac: pindahkan kursor ke Mac.
            mainHandler.postDelayed({ if (overlay != null) leave("file dikirim ke Mac") }, 250)
        }
        dev.cursoe.files.FileBridge.onShare = { uris, mime, names ->
            dev.cursoe.files.OpenWithActivity.show(this, uris, mime, names)
        }
        gestures.onDragActive = { active ->
            mainHandler.removeCallbacks(hideDropStrip)
            if (active) dropStrip?.show(macEdge) else mainHandler.postDelayed(hideDropStrip, 1200)
        }
        InputRouter.attach(this)
        // Aksesibilitas tetap aktif walau Cursoe dimatikan, dan tersambung lagi saat HP dinyalakan ulang:
        // jangan ubah pilihan pengguna di sini. Jaringan hanya menyala bila Cursoe memang dinyalakan.
        DebugLog.enabled = DebugLog.enabled || Prefs(this).debugLog
        CursoeSwitch.refreshTile(this)
        registerScreenOffReceiver()
        if (BuildConfig.DEBUG) registerDebugReceiver()
        Log.i(TAG, "AccessibilityService tersambung")
        returnToCursoeIfAwaited()
        ensureBridgeServiceRunning()
        restoreKeyboard() // mis. setelah crash saat mode remote
        BridgeState.observe(stateObserver)
    }

    /**
     * Baru dinyalakan lewat tombol "Aktifkan" Cursoe (lihat CursoeSwitch.enableAccessibility): bawa pengguna
     * kembali ke Cursoe alih-alih tertinggal di Settings. Layanan Aksesibilitas yang terikat sistem boleh
     * membuka activity dari latar belakang.
     */
    private fun returnToCursoeIfAwaited() {
        val prefs = Prefs(this)
        val since = prefs.awaitingAccessibilitySince
        if (since == 0L) return
        prefs.awaitingAccessibilitySince = 0L
        // 10 menit: cukup untuk langkah "Izinkan setelan terbatas" (Android 13+) di tengah jalan.
        if (System.currentTimeMillis() - since > 10 * 60_000L) return
        try {
            startActivity(
                Intent(this, dev.cursoe.MainActivity::class.java).addFlags(
                    Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP,
                ),
            )
        } catch (e: RuntimeException) {
            Log.w(TAG, "Tidak bisa kembali ke Cursoe: ${e.message}")
        }
    }

    /**
     * Gerakan kursor saja tidak dihitung Android sebagai aktivitas pengguna, jadi layar akan
     * mati sendiri. Selama terhubung ke Mac, pasang jendela tak terlihat dengan
     * FLAG_KEEP_SCREEN_ON. Tidak mengubah pengaturan sistem; otomatis normal saat putus.
     * Tidak menyalakan layar yang sudah mati (tombol power tetap berfungsi).
     */
    private fun updateKeepAwake(on: Boolean) {
        val wm = windowManager ?: return
        if (on && keepAwakeView == null) {
            val view = View(this)
            val params = WindowManager.LayoutParams(
                1, 1,
                WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY,
                WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                    WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE or
                    WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON,
                PixelFormat.TRANSLUCENT,
            ).apply {
                gravity = Gravity.TOP or Gravity.START
                title = "CursoeKeepAwake"
            }
            wm.addView(view, params)
            keepAwakeView = view
            Log.i(TAG, "Layar HP dijaga tetap menyala (terhubung ke Mac)")
        } else if (!on && keepAwakeView != null) {
            runCatching { wm.removeViewImmediate(keepAwakeView) }
            keepAwakeView = null
            Log.i(TAG, "Layar HP kembali mengikuti timeout normal")
        }
    }

    // region Keyboard

    /**
     * Android 11+: ganti keyboard aktif ke "Cursoe Keyboard" selama kursor Mac di HP,
     * lalu kembalikan keyboard pengguna. Pengguna cukup MENGAKTIFKAN keyboard ini sekali di
     * Settings (tidak perlu dijadikan default).
     */
    private fun switchToCursoeKeyboard() {
        if (Build.VERSION.SDK_INT < 30) return
        val ours = KeyboardStatus.ourImeId(this) ?: run {
            Log.w(TAG, "Cursoe Keyboard belum diaktifkan di Settings")
            return
        }
        val current = KeyboardStatus.currentImeId(this)
        if (current == ours) return
        Prefs(this).previousIme = current
        val ok = softKeyboardController.switchToInputMethod(ours)
        Log.i(TAG, "Keyboard → Cursoe (${if (ok) "ok" else "gagal"}), sebelumnya $current")
    }

    private fun restoreKeyboard() {
        if (Build.VERSION.SDK_INT < 30) return
        val prefs = Prefs(this)
        val previous = prefs.previousIme ?: return
        prefs.previousIme = null
        // Bila pengguna sudah mengganti keyboard sendiri, jangan diubah.
        if (KeyboardStatus.currentImeId(this) != KeyboardStatus.ourImeId(this)) return
        val ok = softKeyboardController.switchToInputMethod(previous)
        Log.i(TAG, "Keyboard dikembalikan ke $previous (${if (ok) "ok" else "gagal"})")
    }

    /** Shortcut global: Esc = Back, ⌘H = Home, ⌘⇥ = Recents, ⌘⇧S = screenshot area. @return true bila ditangani. */
    fun globalKey(key: String, mods: Set<String>): Boolean {
        val cmd = "cmd" in mods
        val snipper = snip
        if (snipper?.isActive == true) {
            when (key) {
                "esc" -> snipper.cancel()
                "enter" -> snipper.captureFull()
            }
            return true // selama memilih area, tombol lain tidak diteruskan ke aplikasi
        }
        if (key == "s" && cmd && "shift" in mods) {
            startSnip()
            return true
        }
        val action = when {
            key == "esc" && mods.isEmpty() -> GLOBAL_ACTION_BACK
            key == "h" && cmd -> GLOBAL_ACTION_HOME
            key == "tab" && cmd -> GLOBAL_ACTION_RECENTS
            else -> return false
        }
        performGlobalAction(action)
        return true
    }

    /** ⌘⇧S: bekukan layar lalu pilih area dengan trackpad Mac. Android 9–10: screenshot penuh. */
    private fun startSnip() {
        if (overlay == null) return
        val snipper = snip
        if (snipper == null) {
            if (Build.VERSION.SDK_INT >= 28) performGlobalAction(GLOBAL_ACTION_TAKE_SCREENSHOT)
            return
        }
        gestures.cancelAll()
        snipper.start(x, y) { pointer?.visibility = View.INVISIBLE }
    }

    /** Navigasi sistem dari gestur trackpad Mac (swipe 3 jari = "recents"). */
    fun nav(action: String) {
        val global = when (action) {
            "recents" -> GLOBAL_ACTION_RECENTS
            "home" -> GLOBAL_ACTION_HOME
            "back" -> GLOBAL_ACTION_BACK
            else -> {
                Log.d(TAG, "NAV tidak dikenal: $action")
                return
            }
        }
        performGlobalAction(global)
    }

    // endregion

    /**
     * Sistem selalu menghidupkan ulang AccessibilityService (setelah update aplikasi, reboot, dll),
     * tetapi tidak foreground service jaringan. Nyalakan bila pengguna mengaktifkannya.
     */
    private fun ensureBridgeServiceRunning() {
        val prefs = Prefs(this)
        if (!prefs.serviceEnabled || !Permissions.hasLocalNetwork(this) || BridgeState.current.serviceRunning) return
        try {
            BridgeService.start(this)
            Log.i(TAG, "BridgeService dinyalakan dari AccessibilityService")
        } catch (e: RuntimeException) {
            // Mis. ForegroundServiceStartNotAllowedException; pengguna perlu membuka aplikasi.
            Log.w(TAG, "Tidak bisa menyalakan BridgeService dari latar belakang: ${e.message}")
        }
    }

    /**
     * Mac → HP dengan opsi "pilih aplikasi": buka menu Bagikan untuk file yang baru diterima.
     * Dibuka dari AccessibilityService (dikecualikan dari larangan membuka activity di latar belakang).
     */
    /** Pengaman: layar HP mati/terkunci saat mode remote → kursor kembali ke Mac. */
    private fun registerScreenOffReceiver() {
        if (screenOffReceiver != null) return
        val receiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context, intent: Intent) {
                if (overlay != null) leave("layar HP mati")
            }
        }
        val filter = IntentFilter(Intent.ACTION_SCREEN_OFF)
        if (Build.VERSION.SDK_INT >= 33) {
            registerReceiver(receiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            registerReceiver(receiver, filter)
        }
        screenOffReceiver = receiver
    }

    private var debugReceiver: BroadcastReceiver? = null

    /**
     * Hanya build debug. Pengirim wajib punya izin DUMP (adb shell / sistem):
     *   adb shell am broadcast -a dev.cursoe.debug.LOG --ez on true
     *   adb shell am broadcast -a dev.cursoe.debug.SCROLL --ei jitter 30 --ef scale 1
     *   adb shell am broadcast -a dev.cursoe.debug.SNIP --es step start|drag|exit
     *   adb shell am broadcast -a dev.cursoe.debug.OPENWITH [--es name x.xlsx --es mime …]  (file uji → panel "Buka dengan…")
     *   adb shell am broadcast -a dev.cursoe.debug.WHERE --es n 123   (log "WHERE 123 x y": posisi kursor)
     *     (drag: --ef x1 0.2 --ef y1 0.3 --ef x2 0.8 --ef y2 0.6, pecahan lebar/tinggi layar)
     */
    private fun registerDebugReceiver() {
        if (debugReceiver != null) return
        val receiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context, intent: Intent) {
                when (intent.action) {
                    ACTION_DEBUG_LOG -> {
                        DebugLog.enabled = intent.getBooleanExtra("on", true)
                        Log.i(TAG, "Log debug ${if (DebugLog.enabled) "nyala" else "mati"}")
                    }
                    ACTION_DEBUG_EDGE -> SyntheticInput.edgeLeave()
                    ACTION_DEBUG_PINCH -> SyntheticInput.pinch()
                    ACTION_DEBUG_STRIPTEST -> stripExperiment()
                    ACTION_DEBUG_SNIP -> debugSnip(intent)
                    ACTION_DEBUG_OPENWITH -> debugOpenWith(
                        intent.getBooleanExtra("sheet", false),
                        intent.getStringExtra("name") ?: "cursoe-uji.png",
                        intent.getStringExtra("mime") ?: "image/png",
                    )
                    // Posisi kursor saat ini (rekaman video demo: koreksi sebelum klik).
                    ACTION_DEBUG_WHERE -> Log.i(TAG, "WHERE ${intent.getStringExtra("n") ?: "-"} ${x.toInt()} ${y.toInt()} ${overlay != null}")
                    ACTION_DEBUG_STRIPVIEW -> when (val state = intent.getStringExtra("state") ?: "tab") {
                        "hide" -> dropStrip?.hide()
                        else -> {
                            dropStrip?.show(intent.getStringExtra("edge") ?: "left")
                            mainHandler.postDelayed({ dropStrip?.debugState(state) }, 300)
                        }
                    }
                    ACTION_DEBUG_SCROLL -> SyntheticInput.scroll(
                        jitterMs = intent.getIntExtra("jitter", 0),
                        scale = intent.getFloatExtra("scale", 1f),
                        seed = intent.getIntExtra("seed", 42),
                    )
                }
            }
        }
        val filter = IntentFilter().apply {
            addAction(ACTION_DEBUG_LOG)
            addAction(ACTION_DEBUG_SCROLL)
            addAction(ACTION_DEBUG_EDGE)
            addAction(ACTION_DEBUG_PINCH)
            addAction(ACTION_DEBUG_STRIPTEST)
            addAction(ACTION_DEBUG_SNIP)
            addAction(ACTION_DEBUG_OPENWITH)
            addAction(ACTION_DEBUG_STRIPVIEW)
            addAction(ACTION_DEBUG_WHERE)
        }
        if (Build.VERSION.SDK_INT >= 33) {
            registerReceiver(receiver, filter, Manifest.permission.DUMP, null, Context.RECEIVER_EXPORTED)
        } else {
            registerReceiver(receiver, filter, Manifest.permission.DUMP, null)
        }
        debugReceiver = receiver
    }

    /** Uji panel "Buka dengan…" tanpa Mac: simpan gambar kecil ke Download/Cursoe lalu tampilkan panel. */
    /**
     * File uji → panel "Buka dengan…". [name]/[mime] bebas (mis. .xlsx) agar daftar aplikasinya sama
     * dengan file sungguhan; isinya tetap PNG kecil (hanya tata letak panel yang diuji).
     */
    private fun debugOpenWith(forceSheet: Boolean, name: String, mime: String) {
        if (Build.VERSION.SDK_INT < 29) return
        val bitmap = android.graphics.Bitmap.createBitmap(64, 64, android.graphics.Bitmap.Config.ARGB_8888)
            .apply { eraseColor(android.graphics.Color.rgb(0x1E, 0x40, 0xAF)) }
        val values = android.content.ContentValues().apply {
            put(android.provider.MediaStore.Downloads.DISPLAY_NAME, name)
            put(android.provider.MediaStore.Downloads.MIME_TYPE, mime)
            put(android.provider.MediaStore.Downloads.RELATIVE_PATH, android.os.Environment.DIRECTORY_DOWNLOADS + "/Cursoe")
        }
        val uri = contentResolver.insert(android.provider.MediaStore.Downloads.EXTERNAL_CONTENT_URI, values) ?: return
        contentResolver.openOutputStream(uri)?.use { bitmap.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, it) }
        Log.i(TAG, "OPENWITH uji: $uri")
        dev.cursoe.files.OpenWithActivity.show(this, listOf(uri), mime, listOf(name), forceSheet)
    }

    /** Uji ⌘⇧S tanpa Mac: mulai, seret area (dalam pecahan layar), lalu keluar. */
    private fun debugSnip(intent: Intent) {
        val (w, h) = screenSize()
        when (intent.getStringExtra("step")) {
            "start" -> {
                if (overlay == null) enter(0.5, "center", macEdge)
                startSnip()
            }
            "drag" -> {
                x = intent.getFloatExtra("x1", 0.2f) * w
                y = intent.getFloatExtra("y1", 0.3f) * h
                button(0, true)
                for (i in 1..10) {
                    x = (intent.getFloatExtra("x1", 0.2f) + (intent.getFloatExtra("x2", 0.8f) - intent.getFloatExtra("x1", 0.2f)) * i / 10) * w
                    y = (intent.getFloatExtra("y1", 0.3f) + (intent.getFloatExtra("y2", 0.6f) - intent.getFloatExtra("y1", 0.3f)) * i / 10) * h
                    snip?.onMove(x, y)
                }
                if (intent.getBooleanExtra("release", true)) snip?.onButton(false, x, y, copy = false)
            }
            "exit" -> exit()
        }
    }

    /** EKSPERIMEN: drag dari aplikasi aktif (probe) ke strip "⇠ Mac" di tepi kiri. */
    private fun stripExperiment() {
        DebugLog.enabled = true
        InputRouter.handle("ENTER", org.json.JSONObject().put("yRatio", 0.5).put("from", "center").put("macEdge", "left"))
        mainHandler.postDelayed({ dropStrip?.show("left") }, 100)
        mainHandler.postDelayed({
            val strokes = ArrayList<android.accessibilityservice.GestureDescription.StrokeDescription>()
            var stroke = android.accessibilityservice.GestureDescription.StrokeDescription(
                android.graphics.Path().apply { moveTo(1000f, 900f) }, 0, 150, true)
            strokes += stroke
            var x = 1000f
            repeat(40) {
                val nx = (x - 25f).coerceAtLeast(10f)
                stroke = stroke.continueStroke(android.graphics.Path().apply { moveTo(x, 900f); lineTo(nx, 900f) }, 0, 16, true)
                strokes += stroke
                x = nx
            }
            strokes += stroke.continueStroke(android.graphics.Path().apply { moveTo(x, 900f) }, 0, 30, false)
            strokes.forEach { dispatchGesture(android.accessibilityservice.GestureDescription.Builder().addStroke(it).build(), null, mainHandler) }
        }, 300)
        mainHandler.postDelayed({ dropStrip?.hide() }, 2500)
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) = Unit

    override fun onInterrupt() = Unit

    override fun onUnbind(intent: Intent?): Boolean {
        shutdown()
        return super.onUnbind(intent)
    }

    override fun onDestroy() {
        shutdown()
        super.onDestroy()
    }

    private fun shutdown() {
        BridgeState.remove(stateObserver)
        updateKeepAwake(false)
        InputRouter.detach(this)
        exit()
        debugReceiver?.let { runCatching { unregisterReceiver(it) } }
        debugReceiver = null
        screenOffReceiver?.let { runCatching { unregisterReceiver(it) } }
        screenOffReceiver = null
    }

    // region Perintah dari Mac

    fun enter(yRatio: Double, from: String, macEdge: String) {
        this.macEdge = macEdge
        pushAccumulated = 0f
        enteredAt = SystemClock.uptimeMillis()
        if (overlay == null) {
            addOverlay()
            switchToCursoeKeyboard()
        }
        val (w, h) = screenSize()
        x = when (from) {
            "left" -> EDGE_INSET
            "right" -> w - 1 - EDGE_INSET
            else -> w / 2f
        }
        y = (yRatio.coerceIn(0.0, 1.0) * (h - 1)).toFloat()
        lastWidth = w
        lastHeight = h
        place()
        BridgeState.update { it.copy(remote = true) }
        Log.i(TAG, "ENTER dari $from (Mac di $macEdge), layar ${w}×$h, kursor (${x.toInt()}, ${y.toInt()})")
    }

    /** Kursor didorong keluar lewat tepi yang menghadap Mac: sembunyikan & kabari Mac. */
    private fun leave(reason: String) {
        val (_, h) = screenSize()
        val yRatio = if (h > 1) (y / (h - 1)).toDouble().coerceIn(0.0, 1.0) else 0.5
        Log.i(TAG, "LEAVE ($reason), yRatio=${"%.3f".format(yRatio)}")
        exit()
        InputRouter.notifyLeave(yRatio)
    }

    fun exit() {
        snip?.cancel()
        gestures.cancelAll()
        mainHandler.removeCallbacks(hideDropStrip)
        dropStrip?.hide()
        if (overlay != null) {
            // Clipboard hanya bisa dibaca selama Cursoe Keyboard aktif: kirim dulu ke Mac.
            InputRouter.beforeKeyboardRestore?.invoke()
            restoreKeyboard()
        }
        removeOverlay()
        BridgeState.update { it.copy(remote = false) }
    }

    fun move(dx: Float, dy: Float, macTs: Long) {
        if (overlay == null) return
        val (w, h) = screenSize()
        if (w != lastWidth || h != lastHeight) rescale(w, h)
        // Kecepatan diatur di Mac (menu bar › Kecepatan); di sini hanya dp → px.
        val factor = resources.displayMetrics.density
        x = (x + dx * factor).coerceIn(0f, (w - 1).toFloat())
        y = (y + dy * factor).coerceIn(0f, (h - 1).toFloat())
        place()
        snip?.takeIf { it.isActive }?.let {
            it.onMove(x, y)
            return // memilih area: jangan geser/drag aplikasi, jangan keluar ke Mac
        }
        gestures.onCursorMoved(macTs)
        if (checkEdgePush(dx, w)) leave("didorong ke tepi $macEdge")
    }

    /** true bila kursor sudah cukup didorong melewati tepi yang menghadap Mac. */
    private fun checkEdgePush(dx: Float, w: Int): Boolean {
        val push = when (macEdge) {
            "left" -> if (x <= 0.5f && dx < 0) -dx else 0f
            "right" -> if (x >= w - 1.5f && dx > 0) dx else 0f
            else -> 0f
        }
        // Jangan keluar saat tombol ditahan/drag berlangsung.
        if (push <= 0f || gestures.isBusy) {
            pushAccumulated = 0f
            return false
        }
        val now = SystemClock.uptimeMillis()
        if (now - lastPushAt > EDGE_PUSH_WINDOW_MS) pushAccumulated = 0f
        lastPushAt = now
        pushAccumulated += push
        return pushAccumulated >= EDGE_PUSH_THRESHOLD && now - enteredAt > ENTER_GRACE_MS
    }

    fun button(button: Int, down: Boolean) {
        if (overlay == null) return
        val snipper = snip
        if (snipper?.isActive == true) {
            if (button == 0) snipper.onButton(down, x, y)
            return
        }
        gestures.button(button, down)
    }

    private val snipping: Boolean get() = snip?.isActive == true

    fun scroll(dx: Float, dy: Float, macTs: Long, end: Boolean) {
        if (overlay != null && !snipping) gestures.scroll(dx, dy, macTs, end)
    }

    fun pinch(magnification: Float, macTs: Long, end: Boolean) {
        if (overlay != null && !snipping) gestures.pinch(magnification, macTs, end)
    }

    fun smartZoom() {
        if (overlay != null && !snipping) gestures.smartZoom()
    }

    // endregion

    // region Overlay

    private fun addOverlay() {
        val wm = windowManager ?: return
        val root = FrameLayout(this)
        val view = CursorView(this)
        root.addView(view, FrameLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT))
        root.addOnLayoutChangeListener { _, l, t, r, b, _, _, _, _ ->
            val w = r - l
            val h = b - t
            if (w > 0 && h > 0 && (w != lastWidth || h != lastHeight)) {
                Log.i(TAG, "Ukuran overlay ${w}×$h (sebelumnya ${lastWidth}×$lastHeight)")
                rescale(w, h)
            }
        }

        val params = WindowManager.LayoutParams(
            WindowManager.LayoutParams.MATCH_PARENT,
            WindowManager.LayoutParams.MATCH_PARENT,
            WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE or
                WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN or
                WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS or
                WindowManager.LayoutParams.FLAG_HARDWARE_ACCELERATED,
            PixelFormat.TRANSLUCENT,
        ).apply {
            gravity = Gravity.TOP or Gravity.START
            title = "CursoeCursor"
            if (Build.VERSION.SDK_INT >= 30) {
                layoutInDisplayCutoutMode = WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_ALWAYS
                fitInsetsTypes = 0
            } else if (Build.VERSION.SDK_INT >= 28) {
                layoutInDisplayCutoutMode = WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES
            }
        }
        wm.addView(root, params)
        overlay = root
        pointer = view
    }

    private fun removeOverlay() {
        val root = overlay ?: return
        overlay = null
        pointer = null
        try {
            windowManager?.removeViewImmediate(root)
        } catch (e: IllegalArgumentException) {
            Log.w(TAG, "removeView: ${e.message}")
        }
    }

    private fun place() {
        val view = pointer ?: return
        view.translationX = x - view.tipX
        view.translationY = y - view.tipY
    }

    /** Layar berubah (lipat/buka/rotasi): pertahankan posisi relatif kursor. */
    private fun rescale(w: Int, h: Int) {
        snip?.cancel() // layar beku tidak cocok lagi dengan ukuran layar baru
        gestures.cancelAll() // koordinat gesture yang sedang berjalan tidak berlaku lagi
        if (lastWidth > 0 && lastHeight > 0) {
            x = (x / lastWidth * w).coerceIn(0f, (w - 1).toFloat())
            y = (y / lastHeight * h).coerceIn(0f, (h - 1).toFloat())
        }
        lastWidth = w
        lastHeight = h
        place()
    }

    private fun screenSize(): Pair<Int, Int> {
        val root = overlay
        if (root != null && root.width > 0 && root.height > 0) return root.width to root.height
        val display = getSystemService(DisplayManager::class.java).getDisplay(Display.DEFAULT_DISPLAY)
        val metrics = DisplayMetrics()
        @Suppress("DEPRECATION")
        display.getRealMetrics(metrics)
        return metrics.widthPixels to metrics.heightPixels
    }

    // endregion

    companion object {
        private const val TAG = "Cursoe"
        private const val EDGE_INSET = 2f
        private const val EDGE_PUSH_THRESHOLD = 24f // point Mac, sama dengan ambang di Mac
        private const val EDGE_PUSH_WINDOW_MS = 350L
        private const val ENTER_GRACE_MS = 300L     // jangan langsung memantul balik setelah masuk
        private const val ACTION_DEBUG_LOG = "dev.cursoe.debug.LOG"
        private const val ACTION_DEBUG_SCROLL = "dev.cursoe.debug.SCROLL"
        private const val ACTION_DEBUG_EDGE = "dev.cursoe.debug.EDGE"
        private const val ACTION_DEBUG_PINCH = "dev.cursoe.debug.PINCH"
        private const val ACTION_DEBUG_STRIPTEST = "dev.cursoe.debug.STRIPTEST"
        private const val ACTION_DEBUG_SNIP = "dev.cursoe.debug.SNIP"
        private const val ACTION_DEBUG_OPENWITH = "dev.cursoe.debug.OPENWITH"
        private const val ACTION_DEBUG_STRIPVIEW = "dev.cursoe.debug.STRIPVIEW"
        private const val ACTION_DEBUG_WHERE = "dev.cursoe.debug.WHERE"
    }
}
