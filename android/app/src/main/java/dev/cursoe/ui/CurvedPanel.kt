package dev.cursoe.ui

import android.content.Context
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.Path
import android.util.AttributeSet
import android.widget.LinearLayout
import dev.cursoe.R

/**
 * Panel kaca (seperti panel web) dengan satu tepi melengkung keluar: tepi atas (portrait) atau
 * tepi kiri (landscape), bergaris tepi terang tipis di lengkungannya. Latar di belakangnya
 * (SkyDrawable) sudah berkabut, jadi isi tembus pandang ini terlihat seperti kaca buram.
 * Anak-anaknya ditata seperti LinearLayout biasa.
 */
class CurvedPanel(context: Context, attrs: AttributeSet?) : LinearLayout(context, attrs) {
    private val curveAtStart: Boolean
    private val curve: Float
    private val paint = Paint(Paint.ANTI_ALIAS_FLAG)
    private val edge = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE
        strokeWidth = resources.displayMetrics.density
    }
    private val path = Path()
    private val edgePath = Path()

    init {
        setWillNotDraw(false)
        paint.color = context.getColor(R.color.gb_glass_card)
        edge.color = context.getColor(R.color.gb_glass_border)
        val a = context.obtainStyledAttributes(attrs, R.styleable.CurvedPanel)
        curveAtStart = a.getInt(R.styleable.CurvedPanel_curveEdge, 0) == 1
        curve = a.getDimension(R.styleable.CurvedPanel_curveSize, 40f * resources.displayMetrics.density)
        a.recycle()
    }

    override fun onSizeChanged(w: Int, h: Int, oldw: Int, oldh: Int) {
        super.onSizeChanged(w, h, oldw, oldh)
        val width = w.toFloat()
        val height = h.toFloat()
        path.reset()
        edgePath.reset()
        if (curveAtStart) {
            // Garis tepi: sisi atas lalu lengkungan kiri (panel kaca utuh, tidak "terpotong" di atas).
            edgePath.moveTo(width, 0f)
            edgePath.lineTo(curve, 0f)
            edgePath.quadTo(-curve, height / 2f, curve, height)
            // Titik kontrol di -curve: puncak lengkung tepat di x = 0 (tengah tinggi).
            path.moveTo(curve, 0f)
            path.quadTo(-curve, height / 2f, curve, height)
            path.lineTo(width, height)
            path.lineTo(width, 0f)
        } else {
            edgePath.moveTo(0f, curve)
            edgePath.quadTo(width / 2f, -curve, width, curve)
            path.moveTo(0f, curve)
            path.quadTo(width / 2f, -curve, width, curve)
            path.lineTo(width, height)
            path.lineTo(0f, height)
        }
        path.close()
    }

    override fun onDraw(canvas: Canvas) {
        canvas.drawPath(path, paint)
        canvas.drawPath(edgePath, edge)
        super.onDraw(canvas)
    }
}
