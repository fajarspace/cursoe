package dev.cursoe.cursor

import android.content.Context
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.Path
import android.view.View

/** Panah kursor bergaya macOS (putih bergaris hitam). Ujung panah ada di (tipX, tipY). */
class CursorView(context: Context) : View(context) {
    private val density = resources.displayMetrics.density
    private val scale = density * 1.15f
    private val pad = 2f * density

    // Koordinat dalam "unit kursor" (≈ dp sebelum diskalakan).
    private val arrow = Path().apply {
        moveTo(0f, 0f)
        lineTo(0f, 17f)
        lineTo(4f, 13.2f)
        lineTo(6.8f, 19.4f)
        lineTo(9.4f, 18.3f)
        lineTo(6.6f, 12.2f)
        lineTo(12f, 12.2f)
        close()
    }
    private val fill = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = 0xFFFFFFFF.toInt()
        style = Paint.Style.FILL
    }
    private val outline = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = 0xFF000000.toInt()
        style = Paint.Style.STROKE
        strokeWidth = 1.3f
        strokeJoin = Paint.Join.ROUND
    }

    val tipX: Float get() = pad
    val tipY: Float get() = pad

    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
        setMeasuredDimension((14f * scale + pad * 2).toInt(), (21f * scale + pad * 2).toInt())
    }

    override fun onDraw(canvas: Canvas) {
        canvas.save()
        canvas.translate(pad, pad)
        canvas.scale(scale, scale)
        canvas.drawPath(arrow, fill)
        canvas.drawPath(arrow, outline)
        canvas.restore()
    }
}
