package dev.cursoe.debug

import android.app.Activity
import android.content.Context
import android.graphics.Canvas
import android.graphics.Paint
import android.os.Bundle
import android.util.Log
import android.view.MotionEvent
import android.view.ScaleGestureDetector
import android.view.VelocityTracker
import android.view.View

/**
 * Hanya di build debug. Merekam setiap sampel sentuh (termasuk historis) yang diterima
 * dan mencetak ringkasan kelancaran per stroke ke logcat (tag GBProbe):
 *   adb shell am start -n dev.cursoe/.debug.TouchProbeActivity
 */
class TouchProbeActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val view = ProbeView(this)
        if (intent.getBooleanExtra("dragSource", false)) {
            view.setOnTouchListener { v, e ->
                if (e.actionMasked == MotionEvent.ACTION_DOWN) {
                    val uri = android.net.Uri.parse(intent.getStringExtra("dragUri") ?: "content://media/external/images/media/1")
                    val clip = android.content.ClipData.newUri(contentResolver, "foto", uri)
                    val ok = v.startDragAndDrop(clip, View.DragShadowBuilder(v), null, View.DRAG_FLAG_GLOBAL or View.DRAG_FLAG_GLOBAL_URI_READ)
                    Log.i("GBProbe", "SUMBER drag (aplikasi aktif) startDragAndDrop=$ok")
                }
                true
            }
        }
        view.setOnDragListener { _, e ->
            when (e.action) {
                android.view.DragEvent.ACTION_DRAG_STARTED -> Log.i("GBProbe", "DRAG mulai, tipe=${e.clipDescription?.getMimeType(0)}")
                android.view.DragEvent.ACTION_DRAG_ENTERED -> Log.i("GBProbe", "DRAG masuk ke probe")
                android.view.DragEvent.ACTION_DRAG_LOCATION -> if (e.x.toInt() % 100 < 26) Log.i("GBProbe", "DRAG di ${e.x.toInt()},${e.y.toInt()}")
                android.view.DragEvent.ACTION_DROP -> Log.i("GBProbe", "DROP diterima: \"${e.clipData?.getItemAt(0)?.text}\" di ${e.x.toInt()},${e.y.toInt()}")
            }
            true
        }
        setContentView(view)
    }
}

private class ProbeView(context: Context) : View(context) {
    private var velocity: VelocityTracker? = null
    private var totalScale = 1f
    private val scaleDetector = ScaleGestureDetector(context, object : ScaleGestureDetector.SimpleOnScaleGestureListener() {
        override fun onScaleBegin(detector: ScaleGestureDetector): Boolean {
            totalScale = 1f
            Log.i(TAG, "ZOOM mulai (fokus ${detector.focusX.toInt()},${detector.focusY.toInt()})")
            return true
        }

        override fun onScale(detector: ScaleGestureDetector): Boolean {
            totalScale *= detector.scaleFactor
            return true
        }

        override fun onScaleEnd(detector: ScaleGestureDetector) {
            Log.i(TAG, "ZOOM selesai: skala total ${"%.2f".format(totalScale)}×")
        }
    })
    private val times = ArrayList<Long>()
    private val ys = ArrayList<Float>()
    private var lastSummary = "Cursoe touch probe — menunggu sentuhan"
    private val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        textSize = 16f * resources.displayMetrics.density
        color = 0xFF888888.toInt()
    }

    override fun onTouchEvent(e: MotionEvent): Boolean {
        scaleDetector.onTouchEvent(e)
        if (e.actionMasked == MotionEvent.ACTION_POINTER_DOWN) Log.i(TAG, "POINTER_DOWN, jari=${e.pointerCount}")
        if (e.actionMasked == MotionEvent.ACTION_DOWN) {
            velocity?.recycle()
            velocity = VelocityTracker.obtain()
        }
        velocity?.addMovement(e)
        when (e.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                times.clear()
                ys.clear()
                add(e.eventTime, e.y)
                Log.i(TAG, "DOWN t=${e.eventTime} y=${e.y.toInt()}")
            }
            MotionEvent.ACTION_MOVE -> {
                for (h in 0 until e.historySize) add(e.getHistoricalEventTime(h), e.getHistoricalY(h))
                add(e.eventTime, e.y)
            }
            MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                add(e.eventTime, e.y)
                summarize(if (e.actionMasked == MotionEvent.ACTION_UP) "UP" else "CANCEL")
            }
        }
        return true
    }

    private fun add(t: Long, y: Float) {
        times += t
        ys += y
    }

    private fun summarize(kind: String) {
        if (times.size < 2) return
        val gaps = (1 until times.size).map { times[it] - times[it - 1] }.sorted()
        val total = times.last() - times.first()
        // Hitung "macet": jeda antar-sampel > 24 ms saat jari seharusnya bergerak.
        val stalls = (1 until times.size).count { i ->
            times[i] - times[i - 1] > 24 && ys[i] != ys[i - 1]
        }
        lastSummary = "$kind: ${times.size} sampel, ${total} ms, dy=${(ys.last() - ys.first()).toInt()}, " +
            "jeda p50=${gaps[gaps.size / 2]} p95=${gaps[(gaps.size * 95) / 100]} max=${gaps.last()} ms, " +
            "macet(>24ms)=$stalls, kecepatan lepas=${releaseVelocity()} px/s"
        Log.i(TAG, lastSummary)
        val tail = (maxOf(1, times.size - 8) until times.size).joinToString(" ") { i ->
            "+${times[i] - times[i - 1]}ms:${(ys[i] - ys[i - 1]).toInt()}px"
        }
        Log.i(TAG, "  sampel terakhir: $tail")
        invalidate()
    }

    private fun releaseVelocity(): Int {
        val tracker = velocity ?: return 0
        tracker.computeCurrentVelocity(1000)
        return tracker.yVelocity.toInt()
    }

    override fun onDraw(canvas: Canvas) {
        canvas.drawText(lastSummary, 32f, height / 2f, paint)
    }

    private companion object {
        const val TAG = "GBProbe"
    }
}
