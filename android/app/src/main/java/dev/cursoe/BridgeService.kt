package dev.cursoe

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.ServiceInfo
import android.graphics.drawable.Icon
import android.hardware.display.DisplayManager
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.provider.Settings
import android.util.DisplayMetrics
import android.util.Log
import android.view.Display
import dev.cursoe.clip.ClipboardSync
import dev.cursoe.cursor.InputRouter
import dev.cursoe.files.FileBridge
import dev.cursoe.files.FileTransfer
import dev.cursoe.ime.KeyboardStatus
import dev.cursoe.net.BridgeServer
import dev.cursoe.net.Session
import org.json.JSONObject
import kotlin.concurrent.thread

/**
 * Foreground service: server TCP + iklan NSD, notifikasi persisten, PIN pairing.
 */
class BridgeService : Service(), Session.Host {

    private lateinit var prefs: Prefs
    private lateinit var server: BridgeServer
    private lateinit var notifications: NotificationManager
    private lateinit var displays: DisplayManager
    private var clipboardSync: ClipboardSync? = null
    private var fileTransfer: FileTransfer? = null
    private val main = Handler(Looper.getMainLooper())
    @Volatile private var destroyed = false
    private var statusText = tr("Waiting for Mac…", "Menunggu Mac…")
    @Volatile private var stopReason: String? = null
    private var lastScreenKey = ""

    private val networkCallback = object : android.net.ConnectivityManager.NetworkCallback() {
        override fun onLinkPropertiesChanged(network: android.net.Network, properties: android.net.LinkProperties) {
            val ip = Permissions.localIpv4(this@BridgeService)
            if (ip != BridgeState.current.ip) {
                Log.i(TAG, "Jaringan berubah, IP HP sekarang $ip")
                BridgeState.update { it.copy(ip = ip) }
            }
        }
    }

    private val keyboardObserver = object : android.database.ContentObserver(Handler(Looper.getMainLooper())) {
        override fun onChange(selfChange: Boolean) = pushScreenInfo()
    }

    /** Mode low-latency Wi-Fi selama kursor Mac aktif di HP (mengurangi jeda power-save). */
    private val wifiLock: WifiManager.WifiLock by lazy {
        @Suppress("DEPRECATION")
        val mode = if (Build.VERSION.SDK_INT >= 29) WifiManager.WIFI_MODE_FULL_LOW_LATENCY
        else WifiManager.WIFI_MODE_FULL_HIGH_PERF
        getSystemService(WifiManager::class.java).createWifiLock(mode, "cursoe:remote").apply {
            setReferenceCounted(false)
        }
    }

    private val displayListener = object : DisplayManager.DisplayListener {
        override fun onDisplayChanged(displayId: Int) {
            if (displayId == Display.DEFAULT_DISPLAY) pushScreenInfo()
        }

        override fun onDisplayAdded(displayId: Int) = Unit
        override fun onDisplayRemoved(displayId: Int) = Unit
    }

    override val deviceId: String get() = prefs.deviceId

    override val deviceName: String by lazy {
        Settings.Global.getString(contentResolver, Settings.Global.DEVICE_NAME)
            ?.takeIf { it.isNotBlank() } ?: Build.MODEL
    }

    override fun onCreate() {
        super.onCreate()
        prefs = Prefs(this)
        DebugLog.enabled = DebugLog.enabled || prefs.debugLog
        notifications = getSystemService(NotificationManager::class.java)
        displays = getSystemService(DisplayManager::class.java)
        createChannels()
        registerDismissReceiver()
        startInForeground() // wajib segera setelah startForegroundService()
        server = BridgeServer(this, this) { port -> BridgeState.update { it.copy(port = port) } }

        if (!Permissions.hasLocalNetwork(this)) {
            stopReason = tr("Local network permission is not granted. Open the app and allow it.", "Izin jaringan lokal belum diberikan. Buka aplikasi lalu izinkan.")
            stopSelf()
            return
        }

        BridgeState.update {
            it.copy(
                serviceRunning = true, connected = false, status = tr("Waiting for Mac…", "Menunggu Mac…"),
                screen = describeScreen(), ip = Permissions.localIpv4(this),
            )
        }
        displays.registerDisplayListener(displayListener, main)
        // Jaringan berubah (pindah Wi-Fi/hotspot): perbarui alamat IP yang ditampilkan.
        getSystemService(android.net.ConnectivityManager::class.java).registerDefaultNetworkCallback(networkCallback, main)
        InputRouter.onReadyChanged = { pushScreenInfo() }
        fileTransfer = FileTransfer(this) { server.current }.also { FileBridge.transfer = it }
        clipboardSync = ClipboardSync(this) { server.current }.also { sync ->
            sync.start()
            InputRouter.beforeKeyboardRestore = { sync.pushCurrent("kursor kembali ke Mac") }
        }
        // Kirim ulang SCREEN_INFO saat pengguna mengaktifkan/menonaktifkan keyboard di Settings.
        contentResolver.registerContentObserver(
            Settings.Secure.getUriFor(Settings.Secure.ENABLED_INPUT_METHODS), false, keyboardObserver,
        )
        InputRouter.onLeave = { yRatio ->
            setRemoteWifiLock(false)
            server.current?.sendIfReady(JSONObject().put("t", "LEAVE").put("yRatio", yRatio))
        }

        thread(name = "gb-start") {
            try {
                server.start()
            } catch (e: Exception) {
                Log.e(TAG, "Server gagal start", e)
                stopReason = tr("Server failed: ${e.message}", "Server gagal: ${e.message}")
                main.post { stopSelf() }
            }
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            CursoeSwitch.turnOff(this) // Aksesibilitas tetap aktif; hanya koneksi ke Mac yang berhenti
            stopSelf()
            return START_NOT_STICKY
        }
        return START_STICKY
    }

    override fun onDestroy() {
        destroyed = true
        displays.unregisterDisplayListener(displayListener)
        runCatching {
            getSystemService(android.net.ConnectivityManager::class.java).unregisterNetworkCallback(networkCallback)
        }
        InputRouter.onReadyChanged = null
        InputRouter.onLeave = null
        InputRouter.beforeKeyboardRestore = null
        clipboardSync?.stop()
        clipboardSync = null
        FileBridge.transfer = null
        fileTransfer?.shutdown()
        fileTransfer = null
        contentResolver.unregisterContentObserver(keyboardObserver)
        runCatching { unregisterReceiver(dismissReceiver) }
        InputRouter.disconnected()
        setRemoteWifiLock(false)
        val s = server
        thread(name = "gb-stop") { s.stop() }
        notifications.cancel(NOTIF_PIN)
        BridgeState.update {
            BridgeState.Snapshot(status = stopReason ?: tr("Service stopped", "Layanan mati"), cursorReady = InputRouter.cursorReady)
        }
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    // region Session.Host

    override fun tokenFor(macId: String): ByteArray? = prefs.token(macId)

    override fun savePairing(macId: String, macName: String, token: ByteArray) =
        prefs.savePairing(macId, macName, token)

    override fun showPin(pin: String, macName: String) {
        BridgeState.update { it.copy(pin = pin, pinFor = macName) }
        val pretty = pin.chunked(3).joinToString(" ")
        val notification = Notification.Builder(this, CH_PAIRING)
            .setSmallIcon(R.drawable.ic_stat_cursoe)
            .setContentTitle(tr("Pairing PIN: $pretty", "PIN pairing: $pretty"))
            .setContentText(tr("Enter this PIN on $macName", "Ketik PIN ini di $macName"))
            .setContentIntent(openAppIntent())
            .setCategory(Notification.CATEGORY_STATUS)
            .setVisibility(Notification.VISIBILITY_PUBLIC)
            .setTimeoutAfter(120_000)
            .setAutoCancel(true)
            .build()
        notifications.notify(NOTIF_PIN, notification)
    }

    override fun hidePin() {
        BridgeState.update { it.copy(pin = null, pinFor = null) }
        notifications.cancel(NOTIF_PIN)
    }

    override fun screenInfo(): JSONObject {
        val (metrics, rotation) = readScreen()
        return JSONObject()
            .put("t", "SCREEN_INFO")
            .put("w", metrics.widthPixels)
            .put("h", metrics.heightPixels)
            .put("density", metrics.density.toDouble())
            .put("rotation", rotation)
            .put("cursor", InputRouter.cursorReady)
            .put("ime", KeyboardStatus.isEnabled(this))
    }

    override fun onAuthenticated(session: Session) {
        if (destroyed || session !== server.current) return
        BridgeState.update {
            it.copy(connected = true, macName = session.macName, status = tr("Connected to ${session.macName}", "Terhubung ke ${session.macName}"))
        }
        updateStatusNotification(tr("Connected to ${session.macName}", "Terhubung ke ${session.macName}"))
    }

    override fun onClosed(session: Session, reason: String) {
        if (destroyed) return
        val current = server.current
        if (current != null && current !== session) return // sesi lama yang sudah digantikan
        InputRouter.disconnected()
        setRemoteWifiLock(false)
        fileTransfer?.abortIncoming()
        BridgeState.update {
            it.copy(connected = false, macName = null, status = tr("Waiting for Mac… (last: $reason)", "Menunggu Mac… (terakhir: $reason)"))
        }
        updateStatusNotification(tr("Waiting for Mac…", "Menunggu Mac…"))
    }

    /** Dipanggil dari thread pembaca jaringan. */
    override fun onMessage(session: Session, type: String, message: JSONObject) {
        if (session !== server.current) return
        if (type != "MOVE" && type != "SCROLL" && type != "PINCH") DebugLog.d { "← $type" }
        if (type == "CLIPBOARD" || type.startsWith("CLIP_IMAGE_")) {
            clipboardSync?.handle(type, message)
            return
        }
        if (type.startsWith("FILE_")) {
            fileTransfer?.handle(type, message)
            return
        }
        when (type) {
            "ENTER" -> setRemoteWifiLock(true)
            "EXIT" -> setRemoteWifiLock(false)
        }
        InputRouter.handle(type, message)
    }

    override fun onBinary(session: Session, frame: ByteArray) {
        if (session === server.current) fileTransfer?.onChunk(frame)
    }

    private fun setRemoteWifiLock(on: Boolean) {
        try {
            if (on && !wifiLock.isHeld) wifiLock.acquire()
            if (!on && wifiLock.isHeld) wifiLock.release()
        } catch (e: RuntimeException) {
            Log.w(TAG, "WifiLock: ${e.message}")
        }
    }

    // endregion

    /** onDisplayChanged juga terpicu oleh hal lain (mis. refresh rate adaptif), jadi kirim hanya bila berubah. */
    private fun pushScreenInfo() {
        val info = screenInfo()
        val key = "${info.optInt("w")}x${info.optInt("h")}@${info.optDouble("density")}" +
            "r${info.optInt("rotation")}c${info.optBoolean("cursor")}k${info.optBoolean("ime")}"
        if (key == lastScreenKey) return
        lastScreenKey = key
        BridgeState.update { it.copy(screen = describeScreen(), ip = Permissions.localIpv4(this)) }
        Log.i(TAG, "SCREEN_INFO: ${info.optInt("w")}×${info.optInt("h")} rotasi ${info.optInt("rotation")} kursor ${info.optBoolean("cursor")}")
        server.current?.sendIfReady(info)
    }

    private fun readScreen(): Pair<DisplayMetrics, Int> {
        val display = displays.getDisplay(Display.DEFAULT_DISPLAY)
        val metrics = DisplayMetrics()
        @Suppress("DEPRECATION")
        display.getRealMetrics(metrics)
        return metrics to display.rotation
    }

    private fun describeScreen(): String {
        val (m, _) = readScreen()
        return "${m.widthPixels}×${m.heightPixels} px · ${m.density}x"
    }

    // region Notifikasi

    private fun createChannels() {
        notifications.createNotificationChannel(
            NotificationChannel(CH_STATUS, tr("Connection status", "Status koneksi"), NotificationManager.IMPORTANCE_LOW)
        )
        notifications.createNotificationChannel(
            NotificationChannel(CH_PAIRING, tr("Pairing PIN", "PIN pairing"), NotificationManager.IMPORTANCE_HIGH)
        )
    }

    private fun startInForeground() {
        val notification = statusNotification(tr("Waiting for Mac…", "Menunggu Mac…"))
        if (Build.VERSION.SDK_INT >= 29) {
            startForeground(NOTIF_STATUS, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE)
        } else {
            startForeground(NOTIF_STATUS, notification)
        }
    }

    private fun updateStatusNotification(text: String) {
        statusText = text
        notifications.notify(NOTIF_STATUS, statusNotification(text))
    }

    /**
     * Android 14+ membolehkan pengguna men-swipe notifikasi foreground service walaupun ongoing.
     * Layanan tetap jalan, hanya notifikasinya hilang — jadi begitu di-swipe, langsung dipasang lagi.
     * Receiver hanya terdaftar selama layanan hidup, sehingga setelah "Matikan" tidak ada yang muncul lagi.
     */
    private val dismissReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            if (destroyed) return
            Log.i(TAG, "Notifikasi status di-swipe; ditampilkan lagi")
            updateStatusNotification(statusText)
        }
    }

    private fun registerDismissReceiver() {
        val filter = IntentFilter(ACTION_STATUS_DISMISSED)
        if (Build.VERSION.SDK_INT >= 33) {
            registerReceiver(dismissReceiver, filter, RECEIVER_NOT_EXPORTED)
        } else {
            registerReceiver(dismissReceiver, filter)
        }
    }

    private fun statusNotification(text: String): Notification {
        val stop = PendingIntent.getService(
            this, 1, Intent(this, BridgeService::class.java).setAction(ACTION_STOP),
            PendingIntent.FLAG_IMMUTABLE,
        )
        val dismissed = PendingIntent.getBroadcast(
            this, 2, Intent(ACTION_STATUS_DISMISSED).setPackage(packageName),
            PendingIntent.FLAG_IMMUTABLE,
        )
        return Notification.Builder(this, CH_STATUS)
            .setSmallIcon(R.drawable.ic_stat_cursoe)
            .setContentTitle(tr("Cursoe is on", "Cursoe aktif"))
            .setContentText(text)
            .setContentIntent(openAppIntent())
            .setDeleteIntent(dismissed)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .addAction(Notification.Action.Builder(null as Icon?, tr("Turn off", "Matikan"), stop).build())
            .build()
    }

    private fun openAppIntent(): PendingIntent = PendingIntent.getActivity(
        this, 0, Intent(this, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE,
    )

    // endregion

    companion object {
        private const val TAG = "Cursoe"
        private const val ACTION_STOP = "dev.cursoe.action.STOP"
        private const val ACTION_STATUS_DISMISSED = "dev.cursoe.action.STATUS_DISMISSED"
        private const val CH_STATUS = "status"
        private const val CH_PAIRING = "pairing"
        private const val NOTIF_STATUS = 1
        private const val NOTIF_PIN = 2

        fun start(context: Context) {
            context.startForegroundService(Intent(context, BridgeService::class.java))
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, BridgeService::class.java))
        }
    }
}
