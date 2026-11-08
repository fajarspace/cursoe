package dev.cursoe.ui

import android.content.Context
import android.util.AttributeSet
import android.widget.LinearLayout
import dev.cursoe.R

/** LinearLayout yang tidak melebar melewati `gbMaxWidth` (rapi di tablet & layar lipat terbuka). */
class MaxWidthLinearLayout(context: Context, attrs: AttributeSet?) : LinearLayout(context, attrs) {
    private val maxWidth: Int

    init {
        val a = context.obtainStyledAttributes(attrs, R.styleable.MaxWidthLinearLayout)
        maxWidth = a.getDimensionPixelSize(R.styleable.MaxWidthLinearLayout_gbMaxWidth, Int.MAX_VALUE)
        a.recycle()
    }

    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
        val size = MeasureSpec.getSize(widthMeasureSpec)
        val spec = if (size > maxWidth) MeasureSpec.makeMeasureSpec(maxWidth, MeasureSpec.EXACTLY) else widthMeasureSpec
        super.onMeasure(spec, heightMeasureSpec)
    }
}
