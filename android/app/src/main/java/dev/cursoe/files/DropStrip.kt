package dev.cursoe.files

import android.animation.Animator
import android.animation.AnimatorListenerAdapter
import android.animation.ValueAnimator
import android.content.ClipData
import android.content.Context
import android.content.res.Configuration
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.PixelFormat
import android.graphics.RadialGradient
import android.graphics.Shader
import android.graphics.Typeface
import android.os.Build
import android.os.SystemClock
import android.util.Log
import android.view.DragEvent
import android.view.Gravity
import android.view.View
import android.view.WindowManager
import android.view.animation.AccelerateInterpolator
import android.view.animation.DecelerateInterpolator
import android.view.animation.OvershootInterpolator
import android.widget.Toast
import dev.cursoe.R
import dev.cursoe.tr

/**
 * Area lepas di tepi HP yang menghadap Mac. Hanya dipasang selama tombol kiri Mac ditahan
 * (drag berlangsung), sehingga tidak pernah mencuri klik biasa di tepi layar.
 * Drag-and-drop asli Android: lepas foto/file di sini → dikirim ke Mac.
 *
 * Tampilan: hanya kabut buram di tepi (tanpa kotak/kapsul) yang memudar ke tengah layar.
 * File diseret ke tepi → kabut melebar + ikon laptop "Mac" dan mengikuti tinggi jari/kursor.
 * Dilepas → ✓ "Terkirim", lalu kabut menyusut dan hilang.
 *
 * Catatan izin: jendela non-Activity tidak mendapat izin URI otomatis dari drag. Foto/video
 * dari Galeri (URI MediaStore) tetap bisa dibaca dengan izin "Foto & video"; untuk aplikasi
 * lain gunakan Bagikan › Kirim ke Mac.
 */
class DropStrip(
    private val context: Context,
    private val windowManager: WindowManager,
    private val onDropped: () -> Unit,
) {
    private val density = context.resources.displayMetrics.density
    private var island: IslandView? = null
    private var params: WindowManager.LayoutParams? = null

    fun show(macEdge: String) {
        if (island != null) return
        val onLeft = macEdge == "left"
        val view = IslandView(context, onLeft).apply { setOnDragListener { _, event -> onDrag(event) } }
        val windowParams = WindowManager.LayoutParams(
            dp(IDLE_WIDTH),
            WindowManager.LayoutParams.MATCH_PARENT,
            WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN or
                WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS,
            PixelFormat.TRANSLUCENT,
        ).apply {
            gravity = Gravity.TOP or (if (onLeft) Gravity.START else Gravity.END)
            title = "CursoeDropStrip"
            if (Build.VERSION.SDK_INT >= 30) {
                layoutInDisplayCutoutMode = WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_ALWAYS
                fitInsetsTypes = 0
            }
        }
        windowManager.addView(view, windowParams)
        island = view
        params = windowParams
        view.appear()
    }

    /**
     * Kabut menyusut ke tepi lalu jendelanya dilepas. Sesudah drop, tunggu dulu sampai
     * "Terkirim ✓" terlihat (kursor sudah pindah ke Mac, animasi tetap terlihat utuh).
     */
    fun hide() {
        val view = island ?: return
        island = null
        params = null
        val wait = if (view.isSent) (SENT_HOLD_MS - (SystemClock.uptimeMillis() - view.sentAt)).coerceAtLeast(0) else 0
        view.postDelayed({ view.disappear { runCatching { windowManager.removeViewImmediate(view) } } }, wait)
    }

    /** Lebarkan jendela saat kabut melebar (agar ikon & teks muat); kembali sempit saat diam. */
    private fun setWindowWide(wide: Boolean) {
        val view = island ?: return
        val windowParams = params ?: return
        val width = dp(if (wide) OPEN_WIDTH else IDLE_WIDTH)
        if (windowParams.width == width) return
        windowParams.width = width
        runCatching { windowManager.updateViewLayout(view, windowParams) }
    }

    private fun setOpen(open: Boolean) {
        val view = island ?: return
        if (open) setWindowWide(true)
        view.setOpen(open) { if (island === view && !view.isOpen && !view.isSent) setWindowWide(false) }
    }

    private fun onDrag(event: DragEvent): Boolean {
        val view = island ?: return false
        when (event.action) {
            DragEvent.ACTION_DRAG_STARTED -> return true // terima semua jenis isi
            DragEvent.ACTION_DRAG_ENTERED -> {
                view.follow(event.y)
                setOpen(true)
            }
            DragEvent.ACTION_DRAG_LOCATION -> {
                // Jendela terbuka lebar: menjauh dari tepi > zona lepas → kabut menyempit lagi.
                val fromEdge = view.distanceFromEdge(event.x)
                if (fromEdge > dp(DROP_ZONE)) setOpen(false) else {
                    if (!view.isOpen) setOpen(true)
                    view.follow(event.y)
                }
            }
            DragEvent.ACTION_DRAG_EXITED -> setOpen(false)
            DragEvent.ACTION_DRAG_ENDED -> if (!event.result) setOpen(false)
            DragEvent.ACTION_DROP -> return view.isOpen && handleDrop(event.clipData)
        }
        return true
    }

    private fun handleDrop(clip: ClipData?): Boolean {
        val uris = clip?.let { c -> (0 until c.itemCount).mapNotNull { c.getItemAt(it).uri } }.orEmpty()
        Log.i(TAG, "Drop di tepi Mac: ${uris.size} URI ${uris.map { it.authority }}")
        val transfer = FileBridge.transfer
        if (uris.isEmpty() || transfer == null) {
            setOpen(false)
            Toast.makeText(context, tr("Only files and photos can be sent to your Mac", "Hanya file/foto yang bisa dikirim ke Mac"), Toast.LENGTH_SHORT).show()
            return false
        }
        val mimeHint = clip?.description?.takeIf { it.mimeTypeCount > 0 }?.getMimeType(0)
        transfer.send(FileTransfer.Batch(uris, mimeHint))
        island?.playSent()
        onDropped()
        return true
    }

    /** Hanya uji debug: tampilkan keadaan tertentu tanpa drag sungguhan. */
    fun debugState(state: String) {
        val view = island ?: return
        when (state) {
            "expand" -> {
                view.follow(view.height / 2f)
                setOpen(true)
            }
            "sent" -> {
                view.follow(view.height / 2f)
                setOpen(true)
                view.postDelayed({ view.playSent() }, 420)
            }
        }
    }

    private fun dp(value: Int) = (value * density).toInt()

    /**
     * Kabut buram di tepi (tanpa kapsul): gradien elips berwarna permukaan yang pekat di tepi lalu
     * memudar halus ke dalam layar, digambar langsung di Canvas. Saat file di atasnya kabut melebar
     * dan muncul ikon laptop + "Mac". Semua ukuran dalam dp lalu dikali density.
     * (Blur latar asli tidak tersedia untuk jendela overlay — dan Samsung menonaktifkan blur
     * antarjendela — jadi kabut pekat inilah yang meniru efek blur.)
     */
    private class IslandView(context: Context, private val onLeft: Boolean) : View(context) {
        private val d = context.resources.displayMetrics.density
        private val night = (context.resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK) ==
            Configuration.UI_MODE_NIGHT_YES

        private var open = 0f      // 0 diam → 1 terbuka (sesaat > 1 karena pantulan)
        private var shown = 0f     // 0 → 1 saat muncul / hilang
        private var pulse = 0f     // kabut "bernapas" pelan saat diam
        private var flash = 0f     // kilau sesaat ketika terkirim
        private var centerY = -1f
        var isOpen = false
            private set
        var isSent = false
            private set
        var sentAt = 0L
            private set

        private var openAnim: ValueAnimator? = null
        private var pulseAnim: ValueAnimator? = null
        private var shownAnim: ValueAnimator? = null

        // Kabut: warna permukaan (terang/gelap) — menutupi isi layar seperti kaca buram.
        private val fogColor = if (night) 0xFF232326.toInt() else 0xFFF4F4F5.toInt()
        private val fog = Paint(Paint.ANTI_ALIAS_FLAG)
        private val textColor = context.getColor(R.color.gb_text)
        private val title = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = textColor
            textSize = 14f * d
            textAlign = Paint.Align.CENTER
            typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
        }
        private val subtitle = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = context.getColor(R.color.gb_text_secondary)
            textSize = 11.5f * d
            textAlign = Paint.Align.CENTER
        }
        private val laptop = context.getDrawable(R.drawable.ic_laptop)!!.mutate().apply { setTint(textColor) }
        private val check = context.getDrawable(R.drawable.ic_check_circle)!!.mutate().apply { setTint(textColor) }

        fun distanceFromEdge(x: Float) = if (onLeft) x else width - x

        fun follow(y: Float) {
            centerY = y
            invalidate()
        }

        fun appear() {
            shownAnim = animate(0f, 1f, 280, DecelerateInterpolator(1.6f)) { shown = it }
            pulseAnim = ValueAnimator.ofFloat(0f, 1f).apply {
                duration = 1400
                repeatCount = ValueAnimator.INFINITE
                repeatMode = ValueAnimator.REVERSE
                addUpdateListener { pulse = it.animatedValue as Float; invalidate() }
                start()
            }
        }

        fun disappear(done: () -> Unit) {
            pulseAnim?.cancel()
            openAnim?.cancel()
            shownAnim?.cancel()
            shownAnim = animate(shown, 0f, 220, AccelerateInterpolator(1.4f), onEnd = done) { shown = it }
        }

        /** Lebarkan/sempitkan kabut. [onClosed] dipanggil sesudah animasi menyempit selesai. */
        fun setOpen(value: Boolean, onClosed: () -> Unit) {
            if (value == isOpen || isSent) return
            isOpen = value
            openAnim?.cancel()
            openAnim = if (value) {
                animate(open, 1f, 420, OvershootInterpolator(1.1f)) { open = it }
            } else {
                animate(open, 0f, 220, DecelerateInterpolator(), onEnd = onClosed) { open = it }
            }
        }

        /** ✓ tr("Sent", "Terkirim") + kabut berkilau sekali. */
        fun playSent() {
            isSent = true
            sentAt = SystemClock.uptimeMillis()
            pulseAnim?.cancel()
            animate(1f, 0f, 700, DecelerateInterpolator(1.4f)) { flash = it }
        }

        private fun animate(
            from: Float, to: Float, duration: Long, interpolator: android.animation.TimeInterpolator,
            onEnd: (() -> Unit)? = null, update: (Float) -> Unit,
        ): ValueAnimator = ValueAnimator.ofFloat(from, to).apply {
            this.duration = duration
            this.interpolator = interpolator
            addUpdateListener { update(it.animatedValue as Float); invalidate() }
            if (onEnd != null) addListener(object : AnimatorListenerAdapter() {
                private var cancelled = false
                override fun onAnimationCancel(animation: Animator) { cancelled = true }
                override fun onAnimationEnd(animation: Animator) { if (!cancelled) onEnd() }
            })
            start()
        }

        override fun onDraw(canvas: Canvas) {
            if (shown <= 0.01f) return
            val o = open.coerceAtLeast(0f)
            // Jari-jari elips: horizontal dari tepi (dibatasi lebar jendela) × vertikal.
            val rx = (lerp(IDLE_RX, OPEN_RX, o) * d).coerceAtMost(width.toFloat()) * shown
            val ry = lerp(IDLE_RY, OPEN_RY, o) * d * (0.6f + 0.4f * shown)
            val lo = ry * 0.5f
            val cy = (if (centerY < 0) height / 2f else centerY).coerceIn(lo, (height - lo).coerceAtLeast(lo))
            val edgeX = if (onLeft) 0f else width.toFloat()

            // Kabut: pekat di tepi, memudar halus. Saat diam sedikit "bernapas"; saat terkirim berkilau.
            val strength = (0.82f + 0.12f * pulse * (1 - o.coerceAtMost(1f)) + 0.18f * o.coerceAtMost(1f)).coerceAtMost(1f) *
                shown.coerceAtMost(1f)
            val base = if (flash > 0) blend(fogColor, if (night) Color.WHITE else Color.BLACK, 0.12f * flash) else fogColor
            fog.shader = RadialGradient(
                0f, 0f, ry,
                FOG_ALPHAS.map { withAlpha(base, it * strength) }.toIntArray(), FOG_STOPS, Shader.TileMode.CLAMP,
            )
            canvas.save()
            canvas.translate(edgeX, cy)
            canvas.scale(rx / ry, 1f) // lingkaran → elips menempel di tepi
            canvas.drawCircle(0f, 0f, ry, fog)
            canvas.restore()

            // Ikon & teks (muncul saat kabut melebar), sedikit meluncur dari arah tepi.
            val reveal = ((o - 0.35f) / 0.65f).coerceIn(0f, 1f) * shown.coerceAtMost(1f)
            if (reveal <= 0) return
            val slide = (1 - reveal) * 14 * d
            val cx = if (onLeft) CONTENT_INSET * d - slide else width - CONTENT_INSET * d + slide
            val icon = if (isSent) check else laptop
            val size = (30 * d).toInt()
            val top = cy - 34 * d
            icon.setBounds((cx - size / 2).toInt(), top.toInt(), (cx + size / 2).toInt(), (top + size).toInt())
            icon.alpha = (255 * reveal).toInt()
            icon.draw(canvas)
            title.alpha = (255 * reveal).toInt()
            subtitle.alpha = (255 * reveal).toInt()
            canvas.drawText(if (isSent) tr("Sent", "Terkirim") else "Mac", cx, cy + 16 * d, title)
            canvas.drawText(if (isSent) tr("to Mac", "ke Mac") else tr("Drop to send", "Lepas untuk mengirim"), cx, cy + 34 * d, subtitle)
        }

        private fun lerp(a: Float, b: Float, t: Float) = a + (b - a) * t
        private fun withAlpha(color: Int, alpha: Float) = (color and 0x00FFFFFF) or ((alpha.coerceIn(0f, 1f) * 255).toInt() shl 24)
        private fun blend(a: Int, b: Int, t: Float): Int {
            fun ch(shift: Int) = ((a shr shift and 0xFF) * (1 - t) + (b shr shift and 0xFF) * t).toInt() shl shift
            return (0xFF shl 24) or ch(16) or ch(8) or ch(0)
        }

        override fun onDetachedFromWindow() {
            super.onDetachedFromWindow()
            pulseAnim?.cancel()
            openAnim?.cancel()
            shownAnim?.cancel()
        }
    }

    private companion object {
        const val TAG = "Cursoe"
        const val IDLE_WIDTH = 56   // area tangkap (dp) saat belum ada file di atasnya
        const val OPEN_WIDTH = 300  // saat kabut melebar
        const val DROP_ZONE = 220   // jarak dari tepi (dp) yang masih dihitung "di atas area lepas"
        const val SENT_HOLD_MS = 1100L // lama "Terkirim ✓" terlihat sebelum kabut hilang
        const val CONTENT_INSET = 104f // pusat ikon & teks dari tepi (dp)
        const val IDLE_RX = 50f
        const val IDLE_RY = 190f
        const val OPEN_RX = 285f
        const val OPEN_RY = 330f
        val FOG_STOPS = floatArrayOf(0f, 0.42f, 0.66f, 0.86f, 1f)
        val FOG_ALPHAS = floatArrayOf(1f, 0.97f, 0.72f, 0.22f, 0f)
    }
}
