package dev.cursoe.cursor

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.GestureDescription
import android.accessibilityservice.GestureDescription.StrokeDescription
import android.graphics.Path
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Log
import android.view.ViewConfiguration
import dev.cursoe.DebugLog
import kotlin.math.hypot

/**
 * Menerjemahkan tombol mouse & scroll dari Mac menjadi gesture sentuh (dispatchGesture).
 *
 * - Klik kiri cepat → tap. Tombol kiri ditahan/digeser → satu "jari" yang turun dan mengikuti
 *   kursor sebagai stroke berkelanjutan (willContinue): drag & long-press terasa alami.
 * - Klik kanan → long press di posisi kursor.
 * - Scroll → jari virtual yang digeser sesuai delta trackpad (termasuk momentum dari Mac).
 *
 * Kelancaran: segmen lanjutan sebuah stroke dikirim BERANTAI tanpa menunggu segmen sebelumnya
 * selesai. MotionEventInjector milik sistem menjadwalkan lanjutan tepat di belakang segmen yang
 * sedang berjalan, jadi jari tidak pernah berhenti. Durasi tiap segmen diambil dari timestamp Mac
 * (`ts`), sehingga gerakan mengikuti ritme asli trackpad walau paket datang bergerombol (jitter
 * Wi-Fi). Ada buffer kecil di awal stroke dan batas antrean agar lag tidak menumpuk.
 *
 * Tap/long-press tetap dikirim satu per satu (gesture baru membatalkan gesture yang berjalan).
 * Semua method dipanggil di main thread.
 */
class GestureController(
    private val service: AccessibilityService,
    private val cursor: () -> Pair<Float, Float>,
    private val screen: () -> Pair<Int, Int>,
) {
    private enum class Kind { DRAG, SCROLL }

    private sealed class Job

    private class Tap(val x: Float, val y: Float, val durationMs: Long) : Job()

    private class Stroke(val kind: Kind, val startX: Float, val startY: Float) : Job() {
        var desc: StrokeDescription? = null
        var endX = startX    // posisi jari di akhir segmen terakhir yang dikirim
        var endY = startY
        var targetX = startX // posisi jari yang diinginkan sekarang
        var targetY = startY
        var ending = false   // angkat jari (UP) setelah gerakan tersisa
        var abandon = false  // biarkan jari "dibatalkan" (CANCEL) oleh stroke berikutnya
        var flick = false    // angkat jari dengan kecepatannya → fling bawaan Android
        var lastVx = 0f      // kecepatan segmen bergerak terakhir (px/ms), untuk flick
        var lastVy = 0f
        var finished = false // tidak ada segmen lagi yang akan dikirim
        var dead = false     // dibatalkan sistem
        var outstanding = 0  // segmen terkirim yang belum selesai
        var scheduledUntil = 0L // perkiraan kapan antrean injeksi stroke ini habis
        var lastMacTs = 0L
        var segments = 0
        // khusus scroll
        var slopX = 0f
        var slopY = 0f
        var totalX = 0f
        var totalY = 0f
    }

    /** Pinch dua jari horizontal di sekitar (cx, cy); jarak setengah = r. */
    private class Pinch(val cx: Float, val cy: Float, r0: Float) : Job() {
        var d1: StrokeDescription? = null
        var d2: StrokeDescription? = null
        var r = r0        // jarak setengah yang sudah dikirim
        var targetR = r0  // jarak setengah yang diinginkan sekarang
        var ending = false
        var finished = false
        var dead = false
        var outstanding = 0
        var scheduledUntil = 0L
        var lastMacTs = 0L
    }

    private val main = Handler(Looper.getMainLooper())
    private val jobs = ArrayDeque<Job>()
    private var currentPinch: Pinch? = null
    private var tapInFlight = false
    private var currentDrag: Stroke? = null
    private var currentScroll: Stroke? = null

    // Status tombol kiri
    private var pressed = false
    private var pressX = 0f
    private var pressY = 0f
    private var pressAt = 0L

    /** true saat drag (tombol kiri ditahan) dimulai, false saat dilepas/dibatalkan. */
    var onDragActive: ((Boolean) -> Unit)? = null

    /** Tombol kiri sedang ditahan / drag berlangsung. */
    val isBusy: Boolean get() = pressed || currentDrag != null

    private val density get() = service.resources.displayMetrics.density
    private val touchSlop get() = ViewConfiguration.get(service).scaledTouchSlop.toFloat()

    private val holdRunnable = Runnable { if (pressed && currentDrag == null) startDrag(0L) }
    private val scrollIdleRunnable = Runnable { endScroll() }
    private val pinchIdleRunnable = Runnable { endPinch() }

    // region Input dari Mac

    fun button(button: Int, down: Boolean) {
        when (button) {
            0 -> if (down) leftDown() else leftUp()
            1 -> if (down) {
                endScroll()
                val (x, y) = cursor()
                enqueue(Tap(x, y, ViewConfiguration.getLongPressTimeout() + LONG_PRESS_EXTRA_MS))
            }
            3 -> if (down) service.performGlobalAction(AccessibilityService.GLOBAL_ACTION_BACK) // tombol "back" mouse
        }
    }

    /** Dipanggil CursorService setiap posisi kursor berubah. [macTs] = timestamp Mac (ms) atau 0. */
    fun onCursorMoved(macTs: Long) {
        if (!pressed) return
        val (x, y) = cursor()
        val drag = currentDrag
        if (drag != null) {
            drag.targetX = x
            drag.targetY = y
            pump(macTs)
        } else if (hypot(x - pressX, y - pressY) > touchSlop / 2) {
            startDrag(macTs)
        }
    }

    /**
     * [end] = jari diangkat dari trackpad Mac: angkat jari virtual tanpa jeda sehingga Android
     * menghitung kecepatannya dan menjalankan fling sendiri (inersia lokal, mulus).
     */
    fun scroll(macDx: Float, macDy: Float, macTs: Long, end: Boolean = false) {
        if (end) {
            flickScroll()
            return
        }
        if (pressed) return
        val dx = macDx * density * SCROLL_FACTOR
        val dy = macDy * density * SCROLL_FACTOR
        if (dx == 0f && dy == 0f) return

        var remainingX = dx
        var remainingY = dy
        // Bila jari virtual hampir keluar area aman, "pegang ulang": jari lama dibiarkan dibatalkan
        // (ACTION_CANCEL → tanpa fling) oleh stroke baru yang meneruskan sisa delta.
        for (attempt in 0 until MAX_REGRIPS_PER_EVENT) {
            val s = currentScroll ?: newScrollStroke() ?: return
            val (overX, overY) = applyScroll(s, remainingX, remainingY)
            if (overX == 0f && overY == 0f) break
            DebugLog.d { "scroll: pegang ulang, sisa (${overX.toInt()},${overY.toInt()})" }
            s.abandon = true
            currentScroll = null
            remainingX = overX
            remainingY = overY
            pump(macTs)
        }
        main.removeCallbacks(scrollIdleRunnable)
        main.postDelayed(scrollIdleRunnable, SCROLL_IDLE_MS)
        pump(macTs)
    }

    /**
     * Pinch trackpad: [magnification] = (skala baru / skala lama) − 1. Dua jari virtual di sekitar
     * kursor menjauh/mendekat; skala zoom aplikasi mengikuti rasio jarak jari.
     */
    fun pinch(magnification: Float, macTs: Long, end: Boolean) {
        if (end) {
            endPinch()
            return
        }
        if (pressed || magnification == 0f) return
        endScroll()
        val p = currentPinch ?: newPinch() ?: return
        p.targetR = (p.targetR * (1 + magnification)).coerceIn(minPinchR(), maxPinchR(p))
        main.removeCallbacks(pinchIdleRunnable)
        main.postDelayed(pinchIdleRunnable, PINCH_IDLE_MS)
        pump(macTs)
    }

    /** Ketuk ganda dua jari di trackpad (smart zoom) → ketuk ganda di posisi kursor. */
    fun smartZoom() {
        if (pressed) return
        endScroll()
        endPinch()
        val (x, y) = cursor()
        enqueue(Tap(x, y, 1))
        enqueue(Tap(x, y, 1))
    }

    private fun newPinch(): Pinch? {
        val (w, h) = screen()
        if (w <= 0 || h <= 0) return null
        val (cx, cy) = cursor()
        val x = Math.round(cx.coerceIn(w * ANCHOR_MIN, w * (1 - ANCHOR_MIN))).toFloat()
        val y = Math.round(cy.coerceIn(h * ANCHOR_MIN, h * (1 - ANCHOR_MIN))).toFloat()
        val p = Pinch(x, y, 0f)
        val r0 = Math.round((PINCH_START_DP * density).coerceIn(minPinchR(), maxPinchR(p))).toFloat()
        p.r = r0
        p.targetR = r0
        currentPinch = p
        jobs.addLast(p)
        return p
    }

    private fun minPinchR() = touchSlop * 1.5f

    private fun maxPinchR(p: Pinch): Float {
        val (w, _) = screen()
        val margin = w * SAFE_SIDE
        return maxOf(minPinchR(), minOf(p.cx - margin, w - margin - p.cx))
    }

    private fun endPinch() {
        main.removeCallbacks(pinchIdleRunnable)
        val p = currentPinch ?: return
        p.ending = true
        currentPinch = null
        pump(0L)
    }

    /** Keluar dari mode remote / koneksi putus / layar berubah: angkat jari, buang antrean. */
    fun cancelAll() {
        main.removeCallbacks(holdRunnable)
        main.removeCallbacks(scrollIdleRunnable)
        main.removeCallbacks(pinchIdleRunnable)
        currentPinch = null
        if (currentDrag != null) onDragActive?.invoke(false)
        pressed = false
        currentDrag = null
        currentScroll = null
        val head = jobs.firstOrNull()
        jobs.clear()
        when {
            head is Tap && tapInFlight -> jobs.addLast(head) // dibuang saat callback datang
            head is Stroke && head.desc != null && !head.dead -> {
                if (!head.finished || head.abandon) {
                    head.targetX = head.endX
                    head.targetY = head.endY
                    head.abandon = false
                    head.finished = false
                    head.ending = true // tetap kirim segmen "angkat jari"
                }
                jobs.addLast(head)
            }
            head is Pinch && head.d1 != null && !head.dead -> {
                head.targetR = head.r
                head.ending = true
                head.finished = false
                jobs.addLast(head) // tetap angkat kedua jari
            }
        }
        pump(0L)
    }

    // endregion

    // region Tombol kiri

    private fun leftDown() {
        endScroll()
        val (x, y) = cursor()
        pressed = true
        pressX = x
        pressY = y
        pressAt = SystemClock.uptimeMillis()
        main.postDelayed(holdRunnable, HOLD_MS)
    }

    private fun leftUp() {
        main.removeCallbacks(holdRunnable)
        if (!pressed) return
        pressed = false
        val drag = currentDrag
        if (drag != null) {
            val (x, y) = cursor()
            drag.targetX = x
            drag.targetY = y
            drag.ending = true
            currentDrag = null
            pump(0L)
            onDragActive?.invoke(false)
        } else {
            val duration = (SystemClock.uptimeMillis() - pressAt).coerceIn(1L, MAX_TAP_MS)
            enqueue(Tap(pressX, pressY, duration))
        }
    }

    private fun startDrag(macTs: Long) {
        main.removeCallbacks(holdRunnable)
        val (x, y) = cursor()
        val s = Stroke(Kind.DRAG, Math.round(pressX).toFloat(), Math.round(pressY).toFloat()).apply {
            targetX = x
            targetY = y
            lastMacTs = macTs
        }
        currentDrag = s
        enqueue(s)
        onDragActive?.invoke(true)
    }

    // endregion

    // region Scroll

    private fun newScrollStroke(): Stroke? {
        val (w, h) = screen()
        if (w <= 0 || h <= 0) return null
        val (cx, cy) = cursor()
        // Titik awal dijauhkan dari tepi supaya tidak memicu gesture sistem (back/home/notifikasi).
        val ax = Math.round(cx.coerceIn(w * ANCHOR_MIN, w * (1 - ANCHOR_MIN))).toFloat()
        val ay = Math.round(cy.coerceIn(h * ANCHOR_MIN, h * (1 - ANCHOR_MIN))).toFloat()
        return Stroke(Kind.SCROLL, ax, ay).also {
            currentScroll = it
            jobs.addLast(it)
        }
    }

    /** Tambahkan delta ke stroke scroll. Mengembalikan delta yang tidak muat (perlu pegang ulang). */
    private fun applyScroll(s: Stroke, dx: Float, dy: Float): Pair<Float, Float> {
        if (s.slopX == 0f && s.slopY == 0f) {
            // Kompensasi touch slop: View baru mulai scroll setelah jari bergerak sejauh slop.
            val len = hypot(dx, dy)
            s.slopX = dx / len * touchSlop
            s.slopY = dy / len * touchSlop
        }
        val (w, h) = screen()
        val wantX = s.startX + s.slopX + s.totalX + dx
        val wantY = s.startY + s.slopY + s.totalY + dy
        val x = wantX.coerceIn(w * SAFE_SIDE, w * (1 - SAFE_SIDE))
        val y = wantY.coerceIn(h * SAFE_TOP, h * (1 - SAFE_BOTTOM))
        s.totalX += dx - (wantX - x)
        s.totalY += dy - (wantY - y)
        s.targetX = x
        s.targetY = y
        return (wantX - x) to (wantY - y)
    }

    private fun flickScroll() {
        main.removeCallbacks(scrollIdleRunnable)
        val s = currentScroll ?: return
        s.flick = true
        s.ending = true
        currentScroll = null
        DebugLog.d { "scroll: jari diangkat → fling" }
        pump(0L)
    }

    private fun endScroll() {
        main.removeCallbacks(scrollIdleRunnable)
        val s = currentScroll ?: return
        s.ending = true
        currentScroll = null
        pump(0L)
    }

    // endregion

    // region Antrean & pengiriman

    private fun enqueue(job: Job) {
        jobs.addLast(job)
        pump(0L)
    }

    private fun pump(macTs: Long) {
        when (val head = jobs.firstOrNull() ?: return) {
            is Tap -> if (!tapInFlight) dispatchTap(head)
            is Stroke -> when {
                head.finished -> Unit // menunggu segmen terakhir selesai
                head.abandon && head.desc != null && head.targetX == head.endX && head.targetY == head.endY -> {
                    head.finished = true
                    finishIfDone(head)
                }
                else -> dispatchSegment(head, macTs)
            }
            is Pinch -> if (!head.finished) dispatchPinchSegment(head, macTs)
        }
    }

    private fun dispatchPinchSegment(p: Pinch, macTs: Long) {
        val now = SystemClock.uptimeMillis()
        val first = p.d1 == null
        val newR = Math.round(p.targetR).toFloat()
        val moved = newR != p.r
        if (!first && !moved && !p.ending) return
        val last = p.ending && !moved
        var duration = when {
            last -> 1L
            first -> DRAG_FIRST_SEGMENT_MS
            macTs > 0 && p.lastMacTs > 0 -> (macTs - p.lastMacTs).coerceIn(SEGMENT_MIN_MS, SEGMENT_MAX_MS)
            else -> SEGMENT_DEFAULT_MS
        }
        if (macTs > 0) p.lastMacTs = macTs
        val queueStart = maxOf(now, p.scheduledUntil)
        val lead = queueStart - now
        if (!last && lead > MAX_LEAD_MS) duration = maxOf(SEGMENT_MIN_MS, duration - (lead - MAX_LEAD_MS))
        p.scheduledUntil = queueStart + duration

        val left = Path().apply {
            moveTo(p.cx - p.r, p.cy)
            if (moved) lineTo(p.cx - newR, p.cy)
        }
        val right = Path().apply {
            moveTo(p.cx + p.r, p.cy)
            if (moved) lineTo(p.cx + newR, p.cy)
        }
        val d1 = p.d1?.continueStroke(left, 0, duration, !last) ?: StrokeDescription(left, 0, duration, !last)
        val d2 = p.d2?.continueStroke(right, 0, duration, !last) ?: StrokeDescription(right, 0, duration, !last)
        DebugLog.d { "pinch ${if (first) "awal" else if (last) "akhir" else "lanjut"} r=${p.r.toInt()}→${newR.toInt()} dur=$duration" }
        p.d1 = d1
        p.d2 = d2
        p.r = newR
        p.finished = last
        p.outstanding++
        sendGesture(GestureDescription.Builder().addStroke(d1).addStroke(d2).build()) { ok ->
            p.outstanding--
            if (p.dead) return@sendGesture
            if (!ok) {
                Log.w(TAG, "Pinch dibatalkan sistem")
                p.dead = true
                jobs.remove(p)
                if (currentPinch === p) currentPinch = null
                pump(0L)
            } else if (p.finished && p.outstanding == 0) {
                jobs.remove(p)
                pump(0L)
            }
        }
    }

    private fun dispatchTap(tap: Tap) {
        tapInFlight = true
        val path = Path().apply { moveTo(tap.x, tap.y) }
        send(StrokeDescription(path, 0, tap.durationMs)) { _ ->
            tapInFlight = false
            jobs.remove(tap)
            pump(0L)
        }
    }

    private fun dispatchSegment(s: Stroke, macTs: Long) {
        val (w, h) = screen()
        if (w > 0 && h > 0) { // jangan pernah keluar layar
            s.targetX = s.targetX.coerceIn(0f, w - 1f)
            s.targetY = s.targetY.coerceIn(0f, h - 1f)
        }
        // Titik stroke selalu piksel bulat: sistem mewajibkan awal lanjutan stroke PERSIS sama
        // dengan akhir segmen sebelumnya (dihitung ulang via PathMeasure). Dengan koordinat
        // pecahan, galat float kecil membuat lanjutan ditolak dan seluruh stroke dibatalkan.
        s.targetX = Math.round(s.targetX).toFloat()
        s.targetY = Math.round(s.targetY).toFloat()
        val now = SystemClock.uptimeMillis()
        val first = s.desc == null
        var moved = s.targetX != s.endX || s.targetY != s.endY
        if (!first && !moved && !s.ending) return

        // Flick: jari diangkat TANPA sampel diam di akhir (VelocityTracker akan menghitung kecepatan
        // terlalu rendah). Bila gerakan sudah habis, teruskan arah terakhir selama FLICK_TAIL_MS.
        if (s.flick && s.ending && !moved && !first && (s.lastVx != 0f || s.lastVy != 0f)) {
            s.targetX = Math.round((s.endX + s.lastVx * FLICK_TAIL_MS).coerceIn(0f, w - 1f)).toFloat()
            s.targetY = Math.round((s.endY + s.lastVy * FLICK_TAIL_MS).coerceIn(0f, h - 1f)).toFloat()
            moved = s.targetX != s.endX || s.targetY != s.endY
        }
        val last = s.ending && (!moved || s.flick)
        var duration = when {
            last && s.kind == Kind.SCROLL && !s.flick -> SCROLL_RELEASE_HOLD_MS // diam ≥40 ms → tanpa fling
            last && s.flick && moved -> FLICK_TAIL_MS
            last -> 1L
            first -> if (s.kind == Kind.SCROLL) SCROLL_JITTER_BUFFER_MS else DRAG_FIRST_SEGMENT_MS
            macTs > 0 && s.lastMacTs > 0 -> (macTs - s.lastMacTs).coerceIn(SEGMENT_MIN_MS, SEGMENT_MAX_MS)
            else -> SEGMENT_DEFAULT_MS
        }
        if (macTs > 0) s.lastMacTs = macTs

        // Batasi lag: bila antrean injeksi sudah jauh di depan, persingkat segmen ini.
        val queueStart = maxOf(now, s.scheduledUntil)
        val lead = queueStart - now
        if (!last && lead > MAX_LEAD_MS) {
            duration = maxOf(SEGMENT_MIN_MS, duration - (lead - MAX_LEAD_MS))
        }
        s.scheduledUntil = queueStart + duration

        val path = Path().apply {
            moveTo(s.endX, s.endY)
            if (moved) lineTo(s.targetX, s.targetY)
        }
        DebugLog.d {
            "seg ${s.kind}#${s.segments} ${if (first) "awal" else if (last) "akhir" else "lanjut"} " +
                "dur=$duration d=(${(s.targetX - s.endX).toInt()},${(s.targetY - s.endY).toInt()}) " +
                "antre=${lead}ms out=${s.outstanding}"
        }
        if (moved && duration > 0) {
            s.lastVx = (s.targetX - s.endX) / duration
            s.lastVy = (s.targetY - s.endY) / duration
        }
        val desc = s.desc?.continueStroke(path, 0, duration, !last)
            ?: StrokeDescription(path, 0, duration, !last)
        s.desc = desc
        s.endX = s.targetX
        s.endY = s.targetY
        s.finished = last
        s.segments++
        s.outstanding++
        send(desc) { ok -> onSegmentDone(s, ok) }
    }

    private fun onSegmentDone(s: Stroke, ok: Boolean) {
        s.outstanding--
        if (s.dead) return
        if (!ok) {
            Log.w(TAG, "Gesture ${s.kind} dibatalkan sistem setelah ${s.segments} segmen")
            s.dead = true
            if (s === currentDrag) pressed = false
            jobs.remove(s)
            forget(s)
            pump(0L)
            return
        }
        // Stroke yang ditinggalkan: begitu semua gerakannya terinjeksi, mulai stroke berikutnya
        // (yang otomatis mengirim ACTION_CANCEL untuk jari lama).
        if (s.abandon && s.targetX == s.endX && s.targetY == s.endY) s.finished = true
        finishIfDone(s)
    }

    private fun finishIfDone(s: Stroke) {
        if (!s.finished || s.outstanding > 0) return
        DebugLog.d { "stroke ${s.kind} selesai: ${s.segments} segmen${if (s.abandon) " (pegang ulang)" else ""}" }
        jobs.remove(s)
        forget(s)
        pump(0L)
    }

    private fun send(stroke: StrokeDescription, onDone: (Boolean) -> Unit) =
        sendGesture(GestureDescription.Builder().addStroke(stroke).build(), onDone)

    private fun sendGesture(gesture: GestureDescription, onDone: (Boolean) -> Unit) {
        val callback = object : AccessibilityService.GestureResultCallback() {
            override fun onCompleted(gestureDescription: GestureDescription?) = onDone(true)
            override fun onCancelled(gestureDescription: GestureDescription?) = onDone(false)
        }
        if (!service.dispatchGesture(gesture, callback, main)) {
            Log.w(TAG, "dispatchGesture ditolak")
            main.post { onDone(false) }
        }
    }

    private fun forget(s: Stroke) {
        if (currentDrag === s) currentDrag = null
        if (currentScroll === s) currentScroll = null
    }

    // endregion

    private companion object {
        const val TAG = "Cursoe"
        const val HOLD_MS = 180L                // tombol kiri ditahan diam selama ini → jari turun
        const val MAX_TAP_MS = 120L
        const val LONG_PRESS_EXTRA_MS = 150L
        const val SCROLL_JITTER_BUFFER_MS = 24L // segmen pertama scroll: penyangga jitter jaringan
        const val DRAG_FIRST_SEGMENT_MS = 16L
        const val SEGMENT_MIN_MS = 4L
        const val SEGMENT_MAX_MS = 60L
        const val SEGMENT_DEFAULT_MS = 8L
        const val MAX_LEAD_MS = 48L             // lag maksimum antrean injeksi
        const val SCROLL_RELEASE_HOLD_MS = 50L  // > 40 ms: VelocityTracker menganggap jari berhenti
        const val FLICK_TAIL_MS = 8L
        const val SCROLL_IDLE_MS = 160L
        const val SCROLL_FACTOR = 1f
        const val MAX_REGRIPS_PER_EVENT = 4
        const val ANCHOR_MIN = 0.15f
        const val SAFE_SIDE = 0.06f
        const val SAFE_TOP = 0.06f
        const val SAFE_BOTTOM = 0.08f
        const val PINCH_START_DP = 70f   // jarak setengah awal kedua jari
        const val PINCH_IDLE_MS = 250L
    }
}
