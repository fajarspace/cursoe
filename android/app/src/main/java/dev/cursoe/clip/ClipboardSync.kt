package dev.cursoe.clip

import android.content.ClipData
import android.content.ClipDescription
import android.content.ClipboardManager
import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import dev.cursoe.net.Session
import dev.cursoe.net.Wire
import dev.cursoe.tr
import java.io.ByteArrayOutputStream
import java.io.File
import java.security.MessageDigest
import kotlin.concurrent.thread
import org.json.JSONObject

/**
 * Sinkron clipboard HP ↔ Mac: teks dan gambar.
 *
 * Android 10+ hanya mengizinkan keyboard (IME) aktif atau aplikasi di depan membaca clipboard.
 * Cursoe Keyboard aktif selama kursor Mac di HP, jadi:
 * - perubahan clipboard saat mode remote langsung dikirim ke Mac;
 * - saat kursor kembali ke Mac, clipboard dibaca sekali lagi SEBELUM keyboard dikembalikan.
 * Menulis clipboard (dari Mac) selalu diizinkan.
 */
class ClipboardSync(
    private val context: Context,
    private val session: () -> Session?,
) {
    private val clipboard = context.getSystemService(ClipboardManager::class.java)
    private val main = Handler(Looper.getMainLooper())

    /** Isi terakhir yang dikirim/diterima ("t:"+sha / "i:"+sha) — mencegah gema bolak-balik. */
    @Volatile private var lastSyncedKey: String? = null
    /** URI+timestamp clip gambar terakhir yang sudah diperiksa (hindari membaca ulang file besar). */
    @Volatile private var lastSeenImageClip: String? = null

    private var incoming: Incoming? = null // hanya disentuh thread pembaca jaringan

    private class Incoming(val id: String, val mime: String, val size: Int, val sha256: String) {
        val data = ByteArrayOutputStream(size)
    }

    private val listener = ClipboardManager.OnPrimaryClipChangedListener { pushCurrent("clipboard HP berubah") }

    fun start() = clipboard.addPrimaryClipChangedListener(listener)

    fun stop() = clipboard.removePrimaryClipChangedListener(listener)

    // region HP → Mac

    /** Baca clipboard HP dan kirim bila berubah. Diam-diam gagal bila Android menolak akses. */
    fun pushCurrent(reason: String) {
        val s = session()?.takeIf { it.authenticated } ?: return
        val clip = try {
            clipboard.primaryClip
        } catch (e: SecurityException) {
            null
        } ?: return
        if (clip.itemCount == 0) return
        val description = clip.description
        if (isSensitive(description)) {
            Log.i(TAG, "Clipboard HP ditandai sensitif — tidak disinkronkan")
            return
        }
        val item = clip.getItemAt(0)
        val text = item.text?.toString()
        if (!text.isNullOrEmpty()) {
            sendText(s, text, reason)
            return
        }
        val uri = item.uri ?: return
        val mime = (0 until description.mimeTypeCount).map { description.getMimeType(it) }
            .firstOrNull { it.startsWith("image/") }
            ?: context.contentResolver.getType(uri)?.takeIf { it.startsWith("image/") }
            ?: return
        val clipKey = "$uri@${description.timestamp}"
        if (clipKey == lastSeenImageClip) return
        lastSeenImageClip = clipKey
        thread(name = "gb-clip-send", isDaemon = true) { sendImage(s, uri, mime, reason) }
    }

    private fun sendText(s: Session, text: String, reason: String) {
        val key = "t:" + sha256(text.toByteArray())
        if (key == lastSyncedKey) return
        if (text.toByteArray().size > MAX_TEXT_BYTES) {
            Log.i(TAG, "Teks clipboard HP terlalu besar — tidak disinkronkan")
            return
        }
        lastSyncedKey = key
        s.sendIfReady(JSONObject().put("t", "CLIPBOARD").put("text", text))
        Log.i(TAG, "Clipboard HP → Mac: teks ${text.length} karakter ($reason)")
    }

    private fun sendImage(s: Session, uri: Uri, mime: String, reason: String) {
        try {
            var bytes = context.contentResolver.openInputStream(uri)?.use { input ->
                val out = ByteArrayOutputStream()
                val buffer = ByteArray(64 * 1024)
                while (true) {
                    val n = input.read(buffer)
                    if (n < 0) break
                    out.write(buffer, 0, n)
                    if (out.size() > MAX_IMAGE_BYTES) {
                        Log.i(TAG, "Gambar clipboard HP terlalu besar — tidak disinkronkan")
                        return
                    }
                }
                out.toByteArray()
            } ?: return
            var outMime = mime
            if (mime != "image/png" && mime != "image/jpeg") { // mis. webp/heic → PNG agar terbaca Mac
                val bitmap = BitmapFactory.decodeByteArray(bytes, 0, bytes.size) ?: return
                bytes = ByteArrayOutputStream().also { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }.toByteArray()
                outMime = "image/png"
            }
            val sha = sha256(bytes)
            if ("i:$sha" == lastSyncedKey) return
            lastSyncedKey = "i:$sha"

            val id = java.util.UUID.randomUUID().toString()
            s.sendIfReady(
                JSONObject().put("t", "CLIP_IMAGE_BEGIN").put("id", id).put("mime", outMime)
                    .put("size", bytes.size).put("sha256", sha)
            )
            var offset = 0
            var seq = 0
            while (offset < bytes.size) {
                if (!s.authenticated || s !== session()) return // koneksi berganti
                // Tunggu antrean kirim kosong dulu supaya PONG/LEAVE tidak tertahan di belakang gambar.
                while (s.pendingOutgoing > 0 && s.authenticated) Thread.sleep(2)
                val end = minOf(offset + CHUNK_BYTES, bytes.size)
                s.sendIfReady(
                    JSONObject().put("t", "CLIP_IMAGE_DATA").put("id", id).put("seq", seq++)
                        .put("data", Wire.b64(bytes.copyOfRange(offset, end)))
                )
                offset = end
            }
            s.sendIfReady(JSONObject().put("t", "CLIP_IMAGE_END").put("id", id))
            Log.i(TAG, "Clipboard HP → Mac: gambar $outMime ${bytes.size / 1024} KB ($reason)")
        } catch (e: Exception) {
            Log.w(TAG, "Gagal membaca gambar clipboard HP: ${e.message}")
        }
    }

    private fun isSensitive(description: ClipDescription): Boolean {
        val key = if (Build.VERSION.SDK_INT >= 33) ClipDescription.EXTRA_IS_SENSITIVE else "android.content.extra.IS_SENSITIVE"
        return description.extras?.getBoolean(key) == true
    }

    // endregion

    // region Mac → HP (dipanggil dari thread pembaca jaringan)

    fun handle(type: String, m: JSONObject) {
        when (type) {
            "CLIPBOARD" -> {
                val text = m.optString("text")
                if (text.isEmpty()) return
                lastSyncedKey = "t:" + sha256(text.toByteArray())
                main.post {
                    clipboard.setPrimaryClip(ClipData.newPlainText("Cursoe", text))
                    Log.i(TAG, "Clipboard Mac → HP: teks ${text.length} karakter")
                }
            }
            "CLIP_IMAGE_BEGIN" -> {
                val size = m.optInt("size")
                incoming = if (size in 1..MAX_IMAGE_BYTES) {
                    Incoming(m.optString("id"), m.optString("mime", "image/png"), size, m.optString("sha256"))
                } else {
                    null
                }
            }
            "CLIP_IMAGE_DATA" -> {
                val image = incoming ?: return
                if (m.optString("id") != image.id) return
                val chunk = Wire.unb64(m.optString("data"))
                image.data.write(chunk)
                if (image.data.size() > image.size) incoming = null
            }
            "CLIP_IMAGE_END" -> {
                val image = incoming ?: return
                incoming = null
                if (m.optString("id") != image.id) return
                val bytes = image.data.toByteArray()
                if (bytes.size != image.size || sha256(bytes) != image.sha256) {
                    Log.w(TAG, "Gambar dari Mac rusak/tidak lengkap — dibuang")
                    return
                }
                lastSyncedKey = "i:${image.sha256}"
                setImage(bytes, image.mime)
            }
        }
    }

    private fun setImage(bytes: ByteArray, mime: String) {
        val dir = ClipImageProvider.dir(context.cacheDir).apply { mkdirs() }
        dir.listFiles()?.forEach { it.delete() } // simpan hanya gambar terakhir
        val extension = if (mime == "image/jpeg") "jpg" else "png"
        val file = File(dir, "mac-${System.currentTimeMillis()}.$extension")
        file.writeBytes(bytes)
        val uri = ClipImageProvider.uriFor(file)
        main.post {
            val clip = ClipData.newUri(context.contentResolver, tr("Image from Mac", "Gambar dari Mac"), uri)
            lastSeenImageClip = null
            clipboard.setPrimaryClip(clip)
            Log.i(TAG, "Clipboard Mac → HP: gambar ${bytes.size / 1024} KB")
        }
    }

    // endregion

    private companion object {
        const val TAG = "Cursoe"
        const val MAX_TEXT_BYTES = 256 * 1024
        const val MAX_IMAGE_BYTES = 20 * 1024 * 1024
        const val CHUNK_BYTES = 48 * 1024

        fun sha256(bytes: ByteArray): String =
            MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }
    }
}
