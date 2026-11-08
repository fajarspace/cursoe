package dev.cursoe.ui

import android.animation.ValueAnimator
import android.content.Context
import android.content.res.Configuration
import android.graphics.Canvas
import android.graphics.ColorFilter
import android.graphics.LinearGradient
import android.graphics.Paint
import android.graphics.PixelFormat
import android.graphics.RadialGradient
import android.graphics.Shader
import android.graphics.drawable.Animatable
import android.graphics.drawable.Drawable
import android.os.SystemClock
import android.view.animation.LinearInterpolator
import dev.cursoe.R
import kotlin.math.max
import kotlin.math.min

/**
 * Latar "kaca berkabut" seperti website: warna latar + tiga cahaya biru yang sangat buram di
 * bagian atas, memudar ke latar polos di bawah, dan bergerak pelan (drift). Posisi/ukuran
 * memakai satuan vmax/vw/vh yang sama dengan CSS web (`.sky-blob.is-a/b/c`).
 *
 * Buram didekati dengan gradien radial berprofil Gaussian (lingkaran yang di-blur), jadi murah
 * dan jalan di semua versi Android. Animasi dibatasi ±30 fps dan hanya berjalan saat [start].
 */
class SkyDrawable(context: Context) : Drawable(), Animatable {
    private val density = context.resources.displayMetrics.density
    private val night = (context.resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK) ==
        Configuration.UI_MODE_NIGHT_YES
    private val background = context.getColor(R.color.gb_bg)
    private val glowA = context.getColor(R.color.gb_glow_a)
    private val glowB = context.getColor(R.color.gb_glow_b)
    private val glowC = context.getColor(R.color.gb_glow_c)
    private val blobAlpha = if (night) 0.55f else 0.32f

    private val paint = Paint(Paint.ANTI_ALIAS_FLAG)
    private val fade = Paint()
    private var animator: ValueAnimator? = null
    private var lastFrame = 0L
    private val startedAt = SystemClock.uptimeMillis()

    /** Dipanggil setiap bingkai animasi (mis. agar header kaca ikut memperbarui blur-nya). */
    var onFrame: (() -> Unit)? = null

    override fun draw(canvas: Canvas) {
        val w = bounds.width().toFloat()
        val h = bounds.height().toFloat()
        if (w <= 0 || h <= 0) return
        canvas.drawColor(background)
        val vmax = max(w, h) / 100f
        val vw = w / 100f
        val vh = h / 100f
        val skyHeight = max(h, 820 * density) // web: height: max(100vh, 820px)
        val seconds = (SystemClock.uptimeMillis() - startedAt) / 1000f

        canvas.save()
        canvas.translate(bounds.left.toFloat(), bounds.top.toFloat())
        canvas.clipRect(0f, 0f, w, min(h, skyHeight))
        // .is-a: 52vmax, top −26vmax, left −18vmax, 42 dtk
        blob(canvas, glowA, 26 * vmax, 8 * vmax, 0f, blobAlpha, drift(seconds, 42f, 0f), vw, vh)
        // .is-b: 52vmax, top −8vmax, right −26vmax, 48 dtk, mulai −14 dtk
        blob(canvas, glowB, 26 * vmax, w, 18 * vmax, blobAlpha, drift(seconds, 48f, 14f), vw, vh)
        // .is-c: 38vmax, top 12%, left 30vw, 42 dtk, mulai −26 dtk, 70% opasitas
        blob(canvas, glowC, 19 * vmax, 30 * vw + 19 * vmax, 0.12f * skyHeight + 19 * vmax, blobAlpha * 0.7f,
            drift(seconds, 42f, 26f), vw, vh)
        // Masker web: pekat sampai 40% lalu memudar ke latar polos.
        fade.shader = LinearGradient(0f, 0.4f * skyHeight, 0f, skyHeight,
            background and 0x00FFFFFF, background, Shader.TileMode.CLAMP)
        canvas.drawRect(0f, 0.4f * skyHeight, w, skyHeight, fade)
        canvas.restore()
    }

    /** Lingkaran berjari-jari [r] yang di-blur (σ ≈ 0,3·r, setara blur 110px di web) dengan geser & skala [motion]. */
    private fun blob(
        canvas: Canvas, color: Int, r: Float, cx: Float, cy: Float, alpha: Float,
        motion: FloatArray, vw: Float, vh: Float,
    ) {
        val x = cx + motion[0] * vw
        val y = cy + motion[1] * vh
        val radius = r * motion[2]
        val sigma = radius * 0.3f
        val outer = radius + 3 * sigma
        // Profil tepi lingkaran yang di-blur Gaussian (½·erfc), di titik r−2σ … r+3σ.
        val stops = floatArrayOf(0f, (radius - 2 * sigma) / outer, (radius - sigma) / outer, radius / outer,
            (radius + sigma) / outer, (radius + 2 * sigma) / outer, 1f)
        val levels = floatArrayOf(1f, 0.977f, 0.84f, 0.5f, 0.16f, 0.023f, 0f)
        val colors = IntArray(levels.size) { withAlpha(color, alpha * levels[it]) }
        paint.shader = RadialGradient(x, y, outer, colors, stops, Shader.TileMode.CLAMP)
        canvas.drawCircle(x, y, outer, paint)
    }

    /**
     * @keyframes drift (alternate, ease-in-out): 0% (0,0,1) → 50% (6vw,4vh,1.08) → 100% (−4vw,8vh,0.94).
     * @return [dx dalam vw, dy dalam vh, skala]
     */
    private fun drift(seconds: Float, duration: Float, delay: Float): FloatArray {
        val cycle = ((seconds + delay) / duration)
        val leg = cycle.toInt()
        var u = cycle - leg
        if (leg % 2 == 1) u = 1 - u // alternate
        val (from, to, t) = if (u < 0.5f) Triple(0, 1, u / 0.5f) else Triple(1, 2, (u - 0.5f) / 0.5f)
        val e = t * t * (3 - 2 * t) // ease-in-out
        val keys = arrayOf(floatArrayOf(0f, 0f, 1f), floatArrayOf(6f, 4f, 1.08f), floatArrayOf(-4f, 8f, 0.94f))
        return FloatArray(3) { keys[from][it] + (keys[to][it] - keys[from][it]) * e }
    }

    private fun withAlpha(color: Int, alpha: Float) =
        (color and 0x00FFFFFF) or ((alpha.coerceIn(0f, 1f) * 255).toInt() shl 24)

    override fun start() {
        if (animator != null) return
        animator = ValueAnimator.ofFloat(0f, 1f).apply {
            duration = 60_000
            repeatCount = ValueAnimator.INFINITE
            interpolator = LinearInterpolator()
            addUpdateListener {
                val now = SystemClock.uptimeMillis()
                if (now - lastFrame < 33) return@addUpdateListener // ±30 fps cukup untuk gerak sepelan ini
                lastFrame = now
                invalidateSelf()
                onFrame?.invoke()
            }
            start()
        }
    }

    override fun stop() {
        animator?.cancel()
        animator = null
    }

    override fun isRunning() = animator != null

    override fun setAlpha(alpha: Int) = Unit
    override fun setColorFilter(colorFilter: ColorFilter?) = Unit
    @Deprecated("Deprecated in Java")
    override fun getOpacity() = PixelFormat.OPAQUE
}
