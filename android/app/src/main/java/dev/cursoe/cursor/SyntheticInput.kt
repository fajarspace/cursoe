package dev.cursoe.cursor

import android.os.SystemClock
import android.util.Log
import org.json.JSONObject
import kotlin.concurrent.thread
import kotlin.random.Random

/**
 * Alat debug (hanya build debug): meniru rangkaian pesan SCROLL dari Mac — percepatan,
 * gerak stabil, lalu momentum — termasuk jitter jaringan, lewat jalur yang sama dengan
 * pesan sungguhan (InputRouter dari thread non-UI).
 */
object SyntheticInput {
    private const val TAG = "CursoeDbg"
    private const val FRAME_MS = 8.33

    /** Masuk dari tepi kiri, geser sedikit ke kanan, lalu dorong balik ke kiri → harus LEAVE. */
    fun edgeLeave() {
        thread(name = "gb-synthetic", isDaemon = true) {
            InputRouter.handle("ENTER", JSONObject().put("yRatio", 0.3).put("from", "left").put("macEdge", "left"))
            Thread.sleep(400)
            repeat(10) {
                InputRouter.handle("MOVE", JSONObject().put("dx", 2).put("dy", 0).put("ts", 0))
                Thread.sleep(8)
            }
            repeat(40) {
                InputRouter.handle("MOVE", JSONObject().put("dx", -3).put("dy", 0).put("ts", 0))
                Thread.sleep(8)
            }
            Log.d(TAG, "synthetic: edgeLeave selesai kirim")
        }
    }

    /** Pinch-out lalu angkat: total skala ≈ 1,03^40 ≈ 3,3×. */
    fun pinch() {
        thread(name = "gb-synthetic", isDaemon = true) {
            InputRouter.handle("ENTER", JSONObject().put("yRatio", 0.5).put("from", "center"))
            Thread.sleep(400)
            val start = SystemClock.uptimeMillis()
            repeat(40) { i ->
                InputRouter.handle("PINCH", JSONObject().put("mag", 0.03).put("ts", start + (i * FRAME_MS).toLong()))
                Thread.sleep(8)
            }
            InputRouter.handle("PINCH", JSONObject().put("mag", 0).put("end", true))
            Log.d(TAG, "synthetic: pinch selesai kirim (harapan skala ≈ ${"%.2f".format(Math.pow(1.03, 40.0))}×, terbatas lebar layar)")
            Thread.sleep(1000)
            InputRouter.handle("EXIT", JSONObject())
        }
    }

    fun scroll(jitterMs: Int, scale: Float, seed: Int) {
        thread(name = "gb-synthetic", isDaemon = true) {
            val random = Random(seed)
            val deltas = buildList {
                for (i in 1..12) add(-1.6f * i)          // jari mulai bergerak
                repeat(36) { add(-20f) }                  // gerak stabil ±300 ms
                // Momentum tidak dikirim Mac lagi: HP melakukan fling sendiri setelah "end".
            }
            InputRouter.handle("ENTER", JSONObject().put("yRatio", 0.5).put("from", "center"))
            Thread.sleep(400)

            val start = SystemClock.uptimeMillis() + 20
            var lastDelivery = 0L
            deltas.forEachIndexed { i, dy ->
                val sentAt = start + (i * FRAME_MS).toLong()
                val deliverAt = maxOf(lastDelivery, sentAt + random.nextInt(jitterMs + 1))
                lastDelivery = deliverAt
                val wait = deliverAt - SystemClock.uptimeMillis()
                if (wait > 0) Thread.sleep(wait)
                InputRouter.handle(
                    "SCROLL",
                    JSONObject().put("dx", 0).put("dy", (dy * scale).toDouble()).put("ts", sentAt),
                )
            }
            InputRouter.handle("SCROLL", JSONObject().put("dx", 0).put("dy", 0).put("end", true)
                .put("ts", SystemClock.uptimeMillis()))
            Log.d(TAG, "synthetic: ${deltas.size} SCROLL + end, total dy=${deltas.sum() * scale}, " +
                "jitter≤${jitterMs}ms, mulai t=$start, selesai kirim t=${SystemClock.uptimeMillis()}")
            Thread.sleep(1000)
            InputRouter.handle("EXIT", JSONObject())
        }
    }
}
