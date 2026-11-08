package dev.cursoe.files

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.widget.LinearLayout
import android.widget.ProgressBar
import android.widget.TextView
import android.widget.Toast
import dev.cursoe.BridgeState

/**
 * Tujuan "Bagikan" → "Kirim ke Mac". Selalu berhasil membaca file karena sistem memberi izin
 * URI ke activity penerima. Activity tetap terbuka sampai pengiriman selesai (izin URI berlaku
 * selama activity hidup).
 */
class ShareToMacActivity : Activity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val transfer = FileBridge.transfer
        if (transfer == null || !BridgeState.current.connected) {
            Toast.makeText(this, "Mac belum terhubung ke Cursoe", Toast.LENGTH_LONG).show()
            finish()
            return
        }
        val uris = streamUris(intent)
        if (uris.isEmpty()) {
            Toast.makeText(this, "Tidak ada file untuk dikirim", Toast.LENGTH_SHORT).show()
            finish()
            return
        }

        val density = resources.displayMetrics.density
        val label = TextView(this).apply { text = "Mengirim ${uris.size} file ke Mac…" }
        val progress = ProgressBar(this, null, android.R.attr.progressBarStyleHorizontal).apply { isIndeterminate = true }
        setContentView(LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            val pad = (24 * density).toInt()
            setPadding(pad, pad, pad, pad)
            addView(label)
            addView(progress)
        })
        setFinishOnTouchOutside(false)

        transfer.send(
            FileTransfer.Batch(
                uris, intent.type,
                onProgress = { text -> runOnUiThread { label.text = text } },
                onDone = { ok, message ->
                    runOnUiThread {
                        Toast.makeText(this, message, if (ok) Toast.LENGTH_SHORT else Toast.LENGTH_LONG).show()
                        finish()
                    }
                },
            )
        )
    }

    private fun streamUris(intent: Intent): List<Uri> = when (intent.action) {
        Intent.ACTION_SEND -> listOfNotNull(
            if (Build.VERSION.SDK_INT >= 33) intent.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
            else @Suppress("DEPRECATION") intent.getParcelableExtra(Intent.EXTRA_STREAM)
        )
        Intent.ACTION_SEND_MULTIPLE ->
            (if (Build.VERSION.SDK_INT >= 33) intent.getParcelableArrayListExtra(Intent.EXTRA_STREAM, Uri::class.java)
            else @Suppress("DEPRECATION") intent.getParcelableArrayListExtra(Intent.EXTRA_STREAM)) ?: emptyList()
        else -> emptyList()
    }
}
