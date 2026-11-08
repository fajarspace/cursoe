package dev.cursoe.cursor

import android.accessibilityservice.AccessibilityService
import android.annotation.TargetApi
import android.content.ClipData
import android.content.ClipboardManager
import android.content.ContentValues
import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.PixelFormat
import android.graphics.Rect
import android.graphics.RectF
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import android.util.Log
import android.view.Display
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.view.WindowManager
import android.widget.Toast
import dev.cursoe.tr
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import kotlin.concurrent.thread
import kotlin.math.max
import kotlin.math.min

/**
 * ⌘⇧S dari Mac: screenshot pilih area (seperti Win+Shift+S / ⌘⇧4 di Mac).
 *
 * Layar "dibekukan" lewat AccessibilityService.takeScreenshot (Android 11+), lalu area dipilih
 * dengan klik-seret trackpad Mac (atau jari). Hasil disimpan ke Pictures/Screenshots dan
 * ditaruh di clipboard — sinkron clipboard ikut mengirimnya ke Mac. Esc membatalkan,
 * Enter menyimpan satu layar penuh.
 */
@TargetApi(30)
class ScreenSnip(private val service: AccessibilityService, private val onFinished: () -> Unit) {
    private val wm = service.getSystemService(WindowManager::class.java)
    private val main = Handler(Looper.getMainLooper())
    private var view: SnipView? = null
    private var capturing = false

    val isActive: Boolean get() = view != null || capturing

    /** @param hideCursor dipanggil sebelum layar diambil agar panah kursor tidak ikut terekam. */
    fun start(cursorX: Float, cursorY: Float, hideCursor: () -> Unit) {
        if (isActive) return
        capturing = true
        hideCursor()
        // Tunggu satu frame agar kursor benar-benar hilang dari layar sebelum diambil.
        main.postDelayed({
            service.takeScreenshot(Display.DEFAULT_DISPLAY, service.mainExecutor,
                object : AccessibilityService.TakeScreenshotCallback {
                    override fun onSuccess(result: AccessibilityService.ScreenshotResult) {
                        val buffer = result.hardwareBuffer
                        val frozen = Bitmap.wrapHardwareBuffer(buffer, result.colorSpace)
                            ?.copy(Bitmap.Config.ARGB_8888, false)
                        buffer.close()
                        capturing = false
                        if (frozen == null) return fail("gambar kosong")
                        show(frozen, cursorX, cursorY)
                    }

                    override fun onFailure(errorCode: Int) {
                        capturing = false
                        fail("kode $errorCode")
                    }
                })
        }, 60)
    }

    fun onMove(x: Float, y: Float) {
        view?.moveTo(x, y)
    }

    /** @param copy false: jangan taruh di clipboard (dipakai uji debug agar clipboard pengguna tidak tertimpa). */
    fun onButton(down: Boolean, x: Float, y: Float, copy: Boolean = true) {
        val v = view ?: return
        if (down) v.beginSelection(x, y) else v.endSelection(x, y)?.let { save(it, copy) }
    }

    /** Enter: simpan satu layar penuh. */
    fun captureFull() {
        val v = view ?: return
        save(v.fullRect())
    }

    fun cancel() {
        if (view == null && !capturing) return
        dismiss()
        onFinished()
    }

    private fun show(frozen: Bitmap, x: Float, y: Float) {
        val v = SnipView(service, frozen, x, y)
        val params = WindowManager.LayoutParams(
            WindowManager.LayoutParams.MATCH_PARENT,
            WindowManager.LayoutParams.MATCH_PARENT,
            WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN or
                WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS or
                WindowManager.LayoutParams.FLAG_HARDWARE_ACCELERATED,
            PixelFormat.TRANSLUCENT,
        ).apply {
            gravity = Gravity.TOP or Gravity.START
            title = "CursoeSnip"
            layoutInDisplayCutoutMode = WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_ALWAYS
            fitInsetsTypes = 0
        }
        // Pilih dengan jari juga bisa.
        v.onTouchSelection = { rect -> save(rect) }
        wm.addView(v, params)
        view = v
        Log.i(TAG, "Screenshot area: pilih area (${frozen.width}×${frozen.height})")
    }

    private fun save(rect: Rect, copy: Boolean = true) {
        val v = view ?: return
        val crop = Bitmap.createBitmap(v.frozen, rect.left, rect.top, rect.width(), rect.height())
        dismiss()
        onFinished()
        thread(name = "cursoe-snip") {
            val uri = try {
                store(crop)
            } catch (e: Exception) {
                Log.w(TAG, "Screenshot gagal disimpan", e)
                null
            }
            main.post {
                if (uri == null) {
                    toast(tr("Couldn't save the screenshot", "Screenshot gagal disimpan"))
                    return@post
                }
                // Clipboard HP → ikut dikirim ke Mac oleh sinkron clipboard.
                if (copy) runCatching {
                    service.getSystemService(ClipboardManager::class.java)
                        .setPrimaryClip(ClipData.newUri(service.contentResolver, "Screenshot", uri))
                }
                toast(if (copy) tr("Screenshot saved and copied", "Screenshot disimpan & disalin") else tr("Screenshot saved", "Screenshot disimpan"))
                Log.i(TAG, "Screenshot area ${rect.width()}×${rect.height()} disimpan: $uri")
            }
        }
    }

    private fun store(bitmap: Bitmap): android.net.Uri? {
        val name = "Screenshot_" + SimpleDateFormat("yyyyMMdd-HHmmss", Locale.US).format(Date()) + "_Cursoe.png"
        val values = ContentValues().apply {
            put(MediaStore.Images.Media.DISPLAY_NAME, name)
            put(MediaStore.Images.Media.MIME_TYPE, "image/png")
            put(MediaStore.Images.Media.RELATIVE_PATH, Environment.DIRECTORY_PICTURES + "/Screenshots")
            put(MediaStore.Images.Media.IS_PENDING, 1)
        }
        val resolver = service.contentResolver
        val uri = resolver.insert(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, values) ?: return null
        resolver.openOutputStream(uri)?.use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
        values.clear()
        values.put(MediaStore.Images.Media.IS_PENDING, 0)
        resolver.update(uri, values, null, null)
        return uri
    }

    private fun fail(reason: String) {
        Log.w(TAG, "Screenshot tidak bisa diambil: $reason")
        toast(tr("Screenshots aren't available on this screen", "Screenshot tidak bisa diambil di layar ini"))
        dismiss()
        onFinished()
    }

    private fun dismiss() {
        val v = view ?: return
        view = null
        runCatching { wm.removeViewImmediate(v) }
    }

    private fun toast(text: String) = Toast.makeText(service, text, Toast.LENGTH_SHORT).show()

    /** Layar beku + area pilihan + crosshair. Koordinat = piksel layar (sama dengan kursor). */
    private class SnipView(context: Context, val frozen: Bitmap, x: Float, y: Float) : View(context) {
        var onTouchSelection: ((Rect) -> Unit)? = null
        private val density = resources.displayMetrics.density
        private var cursorX = x
        private var cursorY = y
        private var anchor: Pair<Float, Float>? = null

        private val scrim = Paint().apply { color = Color.argb(115, 0, 0, 0) }
        private val border = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            style = Paint.Style.STROKE; strokeWidth = 1.5f * density; color = Color.WHITE
        }
        private val crossDark = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            style = Paint.Style.STROKE; strokeWidth = 3.5f * density; color = Color.argb(160, 0, 0, 0)
        }
        private val crossLight = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            style = Paint.Style.STROKE; strokeWidth = 1.5f * density; color = Color.WHITE
        }
        private val pill = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Color.argb(220, 24, 24, 27) }
        private val label = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = Color.WHITE; textSize = 13f * density; textAlign = Paint.Align.CENTER
        }

        fun moveTo(x: Float, y: Float) {
            cursorX = x
            cursorY = y
            invalidate()
        }

        fun beginSelection(x: Float, y: Float) {
            anchor = x to y
            moveTo(x, y)
        }

        /** @return area terpilih (piksel bitmap), atau null bila terlalu kecil (klik tanpa seret). */
        fun endSelection(x: Float, y: Float): Rect? {
            moveTo(x, y)
            val rect = selection() ?: return null
            anchor = null
            return if (rect.width() < 8 || rect.height() < 8) {
                invalidate()
                null
            } else rect
        }

        fun fullRect() = Rect(0, 0, frozen.width, frozen.height)

        private fun selection(): Rect? {
            val (ax, ay) = anchor ?: return null
            val r = Rect(min(ax, cursorX).toInt(), min(ay, cursorY).toInt(), max(ax, cursorX).toInt(), max(ay, cursorY).toInt())
            return if (r.intersect(0, 0, frozen.width, frozen.height)) r else null
        }

        override fun onTouchEvent(event: MotionEvent): Boolean {
            when (event.actionMasked) {
                MotionEvent.ACTION_DOWN -> beginSelection(event.x, event.y)
                MotionEvent.ACTION_MOVE -> moveTo(event.x, event.y)
                MotionEvent.ACTION_UP -> endSelection(event.x, event.y)?.let { onTouchSelection?.invoke(it) }
            }
            return true
        }

        override fun onDraw(canvas: Canvas) {
            canvas.drawBitmap(frozen, 0f, 0f, null)
            val sel = selection()
            if (sel == null) {
                canvas.drawRect(0f, 0f, width.toFloat(), height.toFloat(), scrim)
                drawPill(canvas, tr("Drag to select an area · Enter = full screen · Esc = cancel", "Seret untuk memilih area · Enter = layar penuh · Esc = batal"), width / 2f, 64f * density)
            } else {
                // Redupkan semua kecuali area terpilih.
                canvas.drawRect(0f, 0f, width.toFloat(), sel.top.toFloat(), scrim)
                canvas.drawRect(0f, sel.bottom.toFloat(), width.toFloat(), height.toFloat(), scrim)
                canvas.drawRect(0f, sel.top.toFloat(), sel.left.toFloat(), sel.bottom.toFloat(), scrim)
                canvas.drawRect(sel.right.toFloat(), sel.top.toFloat(), width.toFloat(), sel.bottom.toFloat(), scrim)
                canvas.drawRect(RectF(sel), border)
                val below = sel.bottom + 28f * density < height
                drawPill(canvas, "${sel.width()} × ${sel.height()}", sel.exactCenterX(),
                    if (below) sel.bottom + 20f * density else sel.top - 20f * density)
            }
            // Crosshair di posisi kursor
            val arm = 14f * density
            for (p in listOf(crossDark, crossLight)) {
                canvas.drawLine(cursorX - arm, cursorY, cursorX + arm, cursorY, p)
                canvas.drawLine(cursorX, cursorY - arm, cursorX, cursorY + arm, p)
            }
        }

        private fun drawPill(canvas: Canvas, text: String, cx: Float, cy: Float) {
            val w = label.measureText(text) + 24f * density
            val h = 28f * density
            val r = RectF(cx - w / 2, cy - h / 2, cx + w / 2, cy + h / 2)
            canvas.drawRoundRect(r, h / 2, h / 2, pill)
            canvas.drawText(text, cx, cy - (label.ascent() + label.descent()) / 2, label)
        }
    }

    private companion object {
        const val TAG = "Cursoe"
    }
}
