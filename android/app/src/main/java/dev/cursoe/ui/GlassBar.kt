package dev.cursoe.ui

import android.annotation.TargetApi
import android.content.Context
import android.graphics.Canvas
import android.graphics.ColorMatrix
import android.graphics.ColorMatrixColorFilter
import android.graphics.Paint
import android.graphics.Path
import android.graphics.RectF
import android.graphics.RenderEffect
import android.graphics.RenderNode
import android.graphics.Shader
import android.os.Build
import android.util.AttributeSet
import android.view.View
import android.widget.LinearLayout
import dev.cursoe.R

/**
 * Header kaca melayang seperti navbar website: transparan saat konten di paling atas, berubah
 * menjadi kapsul kaca (blur + saturasi, garis tepi terang) dan sedikit menyempit saat di-scroll.
 *
 * Blur asli (Android 12+): isi [scrollSource] dan latar [backdrop] direkam ke RenderNode lalu
 * diburamkan dengan RenderEffect. Ini blur di dalam aplikasi sendiri (bukan blur antarjendela),
 * jadi tetap jalan di HP yang mematikan blur antarjendela. Android lama: kaca padat tanpa blur.
 */
class GlassBar(context: Context, attrs: AttributeSet?) : LinearLayout(context, attrs) {
    /** Konten yang di-scroll di bawah header (tidak boleh berisi header ini). */
    var scrollSource: View? = null
    /** View yang latarnya (mis. SkyDrawable) ikut diburamkan. */
    var backdrop: View? = null

    /** 0 = transparan (di paling atas) … 1 = kaca penuh. */
    var progress = 0f
        set(value) {
            field = value.coerceIn(0f, 1f)
            invalidate()
        }

    private val d = resources.displayMetrics.density
    private val node: RenderNode? = if (Build.VERSION.SDK_INT >= 31) createNode() else null
    private val glass = context.getColor(R.color.gb_glass_strong)
    private val solid = context.getColor(R.color.gb_bg)
    private val fill = Paint(Paint.ANTI_ALIAS_FLAG)
    private val border = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE
        strokeWidth = 1 * d
        color = context.getColor(R.color.gb_glass_border)
    }
    private val rect = RectF()
    private val path = Path()
    private val here = IntArray(2)
    private val there = IntArray(2)

    init {
        setWillNotDraw(false)
    }

    @TargetApi(31)
    private fun createNode() = RenderNode("cursoe-glass").apply {
        // web: backdrop-filter: blur(24px) saturate(180%)
        val saturate = ColorMatrix().apply { setSaturation(1.8f) }
        setRenderEffect(
            RenderEffect.createColorFilterEffect(
                ColorMatrixColorFilter(saturate),
                RenderEffect.createBlurEffect(22 * d, 22 * d, Shader.TileMode.CLAMP),
            ),
        )
    }

    override fun onDraw(canvas: Canvas) {
        val p = progress
        if (p > 0.001f) {
            val inset = (8 + 10 * p) * d // menyempit saat di-scroll, seperti navbar web
            rect.set(inset, paddingTop + 4 * d, width - inset, height - 4 * d)
            val radius = rect.height() / 2
            path.reset()
            path.addRoundRect(rect, radius, radius, Path.Direction.CW)
            val blurred = Build.VERSION.SDK_INT >= 31 && drawBackdrop(canvas, p)
            fill.color = if (blurred) glass else solid
            fill.alpha = ((fill.color ushr 24) * p).toInt()
            canvas.drawPath(path, fill)
            border.alpha = ((context.getColor(R.color.gb_glass_border) ushr 24) * p).toInt()
            canvas.drawPath(path, border)
        }
        super.onDraw(canvas)
    }

    /** Rekam latar + konten di bawah header, buramkan, gambar di dalam kapsul. */
    @TargetApi(31)
    private fun drawBackdrop(canvas: Canvas, p: Float): Boolean {
        val node = node ?: return false
        val source = scrollSource ?: return false
        if (!canvas.isHardwareAccelerated || width == 0 || height == 0) return false
        node.setPosition(0, 0, width, height)
        val recording = node.beginRecording(width, height)
        getLocationInWindow(here)
        backdrop?.let { view ->
            val sky = view.background ?: return@let
            view.getLocationInWindow(there)
            recording.save()
            recording.translate((there[0] - here[0]).toFloat(), (there[1] - here[1]).toFloat())
            sky.draw(recording)
            recording.restore()
        }
        source.getLocationInWindow(there)
        recording.save()
        recording.translate((there[0] - here[0]).toFloat(), (there[1] - here[1]).toFloat())
        recording.translate(-source.scrollX.toFloat(), -source.scrollY.toFloat())
        source.draw(recording)
        recording.restore()
        node.endRecording()
        node.alpha = p
        canvas.save()
        canvas.clipPath(path)
        canvas.drawRenderNode(node)
        canvas.restore()
        return true
    }
}
