package dev.cursoe.files

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import android.provider.OpenableColumns
import android.util.Log
import dev.cursoe.R
import dev.cursoe.net.Session
import dev.cursoe.tr
import java.io.File
import java.io.FileOutputStream
import java.io.InputStream
import java.io.OutputStream
import java.nio.ByteBuffer
import java.security.MessageDigest
import java.util.UUID
import java.util.concurrent.LinkedBlockingQueue
import kotlin.concurrent.thread
import org.json.JSONObject

/** Akses global (satu proses) ke transfer file yang dimiliki BridgeService. */
object FileBridge {
    @Volatile var transfer: FileTransfer? = null

    /** Mac → HP: semua file kiriman tersimpan → tampilkan pilihan "Buka dengan…/Simpan" (main thread). */
    @Volatile var onShare: ((uris: List<Uri>, mime: String, names: List<String>) -> Unit)? = null
}

/**
 * Kirim/terima file HP ↔ Mac. Protokol sama dengan FileTransfer.swift:
 * FILE_BEGIN {id, name, size, mime, index, count} → biner [0x01][16 byte UUID][data]
 * → FILE_END {id, sha256} → (penerima) FILE_RESULT {id, ok, message}.
 * File dari Mac disimpan lewat MediaStore ke Download/Cursoe (foto/video ikut tampil di Galeri).
 */
class FileTransfer(
    private val context: Context,
    private val session: () -> Session?,
) {
    /** Satu kiriman (beberapa file). Callback dipanggil dari thread pekerja. */
    class Batch(
        val uris: List<Uri>,
        val mimeHint: String?,
        val onProgress: ((String) -> Unit)? = null,
        val onDone: ((ok: Boolean, message: String) -> Unit)? = null,
    )

    private val shareBatches = HashMap<String, MutableList<Triple<Uri, String, String>>>() // thread pembaca: uri, mime, nama

    private val resolver = context.contentResolver
    private val notifications = context.getSystemService(NotificationManager::class.java)
    private val batches = LinkedBlockingQueue<Batch>()
    @Volatile private var running = true
    private val worker: Thread

    private val incoming = HashMap<UUID, Incoming>() // hanya thread pembaca jaringan

    private class Incoming(
        val name: String,
        val size: Long,
        val mime: String,
        val uri: Uri?,
        val file: File?,
        val out: OutputStream,
        val shareBatch: String? = null,
        val batchCount: Int = 1,
    ) {
        var received = 0L
        val digest: MessageDigest = MessageDigest.getInstance("SHA-256")
        var lastNotified = 0L
    }

    init {
        notifications.createNotificationChannel(
            NotificationChannel(CHANNEL, tr("File transfer", "Transfer file"), NotificationManager.IMPORTANCE_DEFAULT)
        )
        worker = thread(name = "gb-files", isDaemon = true) { workerLoop() }
    }

    fun shutdown() {
        running = false
        worker.interrupt()
        abortIncoming()
    }

    // region HP → Mac

    fun send(batch: Batch) {
        batches.offer(batch)
    }

    private fun workerLoop() {
        while (running) {
            val batch = try {
                batches.take()
            } catch (_: InterruptedException) {
                return
            }
            var ok = true
            var message = tr("${batch.uris.size} files sent to Mac", "${batch.uris.size} file terkirim ke Mac")
            batch.uris.forEachIndexed { index, uri ->
                val result = sendOne(uri, batch.mimeHint, index + 1, batch.uris.size, batch.onProgress)
                if (result != null) {
                    ok = false
                    message = result
                }
            }
            batch.onDone?.invoke(ok, message)
            notifyDone(if (ok) tr("Sent to Mac", "Terkirim ke Mac") else tr("Couldn't send to Mac", "Gagal mengirim ke Mac"), message, null, null)
        }
    }

    /** @return null bila berhasil, atau pesan kesalahan. */
    private fun sendOne(uri: Uri, mimeHint: String?, index: Int, count: Int, onProgress: ((String) -> Unit)?): String? {
        val s = session()?.takeIf { it.authenticated } ?: return tr("Mac not connected", "Mac tidak terhubung")
        var temp: File? = null
        try {
            var (name, size) = queryNameAndSize(uri)
            val mime = resolver.getType(uri) ?: mimeHint?.takeIf { !it.contains('*') } ?: "application/octet-stream"
            var input: InputStream = resolver.openInputStream(uri) ?: return tr("Can't open $name", "Tidak bisa membuka $name")
            if (size < 0) { // ukuran tak diketahui: salin ke cache dulu
                temp = File.createTempFile("send", null, context.cacheDir)
                input.use { src -> FileOutputStream(temp).use { src.copyTo(it) } }
                size = temp.length()
                input = temp.inputStream()
            }

            val id = UUID.randomUUID()
            val header = ByteBuffer.allocate(17).put(Session.BINARY_MARKER)
                .putLong(id.mostSignificantBits).putLong(id.leastSignificantBits).array()
            s.sendIfReady(
                JSONObject().put("t", "FILE_BEGIN").put("id", id.toString()).put("name", name)
                    .put("size", size).put("mime", mime).put("index", index).put("count", count)
            )
            val digest = MessageDigest.getInstance("SHA-256")
            val buffer = ByteArray(CHUNK_BYTES)
            var sent = 0L
            var lastProgress = 0L
            input.use { src ->
                while (true) {
                    val n = src.read(buffer)
                    if (n < 0) break
                    if (n == 0) continue
                    if (!s.authenticated || s !== session()) return tr("Connection to Mac lost", "Koneksi ke Mac terputus")
                    // Tahan laju: tunggu antrean kirim hampir kosong agar PONG/LEAVE tidak tertahan.
                    while (s.pendingOutgoing > 2 && s.authenticated) Thread.sleep(1)
                    digest.update(buffer, 0, n)
                    s.sendBinaryIfReady(header + buffer.copyOf(n))
                    sent += n
                    val now = System.currentTimeMillis()
                    if (now - lastProgress > 300) {
                        lastProgress = now
                        val label = tr("Sending $name ($index/$count) — ${if (size > 0) sent * 100 / size else 100}%", "Mengirim $name ($index/$count) — ${if (size > 0) sent * 100 / size else 100}%")
                        onProgress?.invoke(label)
                        notifyProgress(NOTIF_SEND, tr("Sending to Mac", "Mengirim ke Mac"), label, sent, size)
                    }
                }
            }
            if (sent != size) return tr("$name changed size while sending", "Ukuran $name berubah saat dikirim")
            s.sendIfReady(JSONObject().put("t", "FILE_END").put("id", id.toString()).put("sha256", hex(digest.digest())))
            Log.i(TAG, "Terkirim ke Mac: $name (${size / 1024} KB)")
            return null
        } catch (e: SecurityException) {
            Log.w(TAG, "Tidak diizinkan membaca $uri: ${e.message}")
            return tr(
                "The source app doesn't allow this file to be read. Allow Cursoe to access photos and videos, " +
                    "or use Share › Send to Mac.",
                "Aplikasi sumber tidak mengizinkan file ini dibaca. Izinkan akses Foto & video untuk " +
                    "Cursoe, atau gunakan Bagikan › Kirim ke Mac.",
            )
        } catch (e: Exception) {
            Log.w(TAG, "Gagal mengirim $uri", e)
            return tr("Send failed: ${e.message}", "Gagal mengirim: ${e.message}")
        } finally {
            temp?.delete()
        }
    }

    private fun queryNameAndSize(uri: Uri): Pair<String, Long> {
        var name = uri.lastPathSegment ?: "file"
        var size = -1L
        resolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE), null, null, null)?.use { c ->
            if (c.moveToFirst()) {
                c.getColumnIndex(OpenableColumns.DISPLAY_NAME).takeIf { it >= 0 && !c.isNull(it) }?.let { name = c.getString(it) }
                c.getColumnIndex(OpenableColumns.SIZE).takeIf { it >= 0 && !c.isNull(it) }?.let { size = c.getLong(it) }
            }
        }
        return safeName(name) to size
    }

    // endregion

    // region Mac → HP (thread pembaca jaringan)

    fun handle(type: String, m: JSONObject) {
        when (type) {
            "FILE_BEGIN" -> begin(m)
            "FILE_END" -> end(m)
            "FILE_CANCEL" -> runCatching { UUID.fromString(m.optString("id")) }.getOrNull()?.let { cancel(it) }
            "FILE_RESULT" -> {
                val ok = m.optBoolean("ok")
                Log.i(TAG, "Mac: ${if (ok) "file diterima" else "gagal"} — ${m.optString("message")}")
                if (!ok) notifyDone(tr("The Mac couldn't save the file", "Mac gagal menyimpan file"), m.optString("message"), null, null)
            }
        }
    }

    fun onChunk(frame: ByteArray) {
        if (frame.size <= 17) return
        val buffer = ByteBuffer.wrap(frame, 1, 16)
        val id = UUID(buffer.long, buffer.long)
        val item = incoming[id] ?: return
        try {
            item.out.write(frame, 17, frame.size - 17)
        } catch (e: Exception) {
            reply(id, false, tr("This device couldn't write the file: ${e.message}", "HP tidak bisa menulis file: ${e.message}"))
            cancel(id)
            return
        }
        item.digest.update(frame, 17, frame.size - 17)
        item.received += frame.size - 17
        if (item.received > item.size) {
            cancel(id)
            return
        }
        val now = System.currentTimeMillis()
        if (now - item.lastNotified > 400) {
            item.lastNotified = now
            notifyProgress(NOTIF_RECEIVE, tr("Receiving from Mac", "Menerima dari Mac"), item.name, item.received, item.size)
        }
    }

    private fun begin(m: JSONObject) {
        val id = runCatching { UUID.fromString(m.optString("id")) }.getOrNull() ?: return
        val name = safeName(m.optString("name", "file"))
        val size = m.optLong("size", -1)
        val mime = m.optString("mime", "application/octet-stream")
        if (size < 0) return
        try {
            val item = if (Build.VERSION.SDK_INT >= 29) {
                val values = ContentValues().apply {
                    put(MediaStore.Downloads.DISPLAY_NAME, name)
                    put(MediaStore.Downloads.MIME_TYPE, mime)
                    put(MediaStore.Downloads.RELATIVE_PATH, "${Environment.DIRECTORY_DOWNLOADS}/$FOLDER")
                    put(MediaStore.Downloads.IS_PENDING, 1)
                }
                val uri = resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
                    ?: throw IllegalStateException("MediaStore menolak")
                Incoming(
                    name, size, mime, uri, null, resolver.openOutputStream(uri) ?: throw IllegalStateException("stream null"),
                    shareBatch = if (m.optBoolean("share")) m.optString("batch") else null,
                    batchCount = m.optInt("count", 1),
                )
            } else {
                val dir = File(context.getExternalFilesDir(Environment.DIRECTORY_DOWNLOADS), FOLDER).apply { mkdirs() }
                val file = uniqueFile(dir, name)
                Incoming(name, size, mime, null, file, FileOutputStream(file))
            }
            incoming[id] = item
            Log.i(TAG, "Menerima $name (${size / 1024} KB) dari Mac")
        } catch (e: Exception) {
            Log.w(TAG, "Tidak bisa menyiapkan file $name", e)
            reply(id, false, tr("This device couldn't save the file: ${e.message}", "HP tidak bisa menyimpan file: ${e.message}"))
        }
    }

    private fun end(m: JSONObject) {
        val id = runCatching { UUID.fromString(m.optString("id")) }.getOrNull() ?: return
        val item = incoming.remove(id) ?: return
        runCatching { item.out.close() }
        val sha = hex(item.digest.digest())
        if (item.received != item.size || sha != m.optString("sha256")) {
            discard(item)
            reply(id, false, tr("file corrupted or incomplete", "file rusak/tidak lengkap"))
            notifyDone(tr("Couldn't receive ${item.name}", "Gagal menerima ${item.name}"), tr("The file is corrupted or incomplete", "File rusak atau tidak lengkap"), null, null)
            return
        }
        item.uri?.let { uri ->
            resolver.update(uri, ContentValues().apply { put(MediaStore.Downloads.IS_PENDING, 0) }, null, null)
        }
        reply(id, true, tr("Saved to Download/$FOLDER", "Tersimpan di Download/$FOLDER"))
        Log.i(TAG, "File dari Mac tersimpan: ${item.name}")
        val batch = item.shareBatch
        if (batch != null && item.uri != null) {
            val done = shareBatches.getOrPut(batch) { mutableListOf() }.apply { add(Triple(item.uri, item.mime, item.name)) }
            if (done.size >= item.batchCount) {
                shareBatches.remove(batch)
                val mimes = done.map { it.second }.distinct()
                val mime = mimes.singleOrNull()
                    ?: mimes.map { it.substringBefore('/') }.distinct().singleOrNull()?.let { "$it/*" }
                    ?: "*/*"
                val uris = done.map { it.first }
                val names = done.map { it.third }
                android.os.Handler(android.os.Looper.getMainLooper()).post { FileBridge.onShare?.invoke(uris, mime, names) }
            }
            notifications.cancel(NOTIF_RECEIVE)
        } else {
            notifyDone(tr("File from Mac", "File dari Mac"), "${item.name} — Download/$FOLDER", item.uri, item.mime)
        }
    }

    private fun cancel(id: UUID) {
        incoming.remove(id)?.let { discard(it) }
        notifications.cancel(NOTIF_RECEIVE)
    }

    fun abortIncoming() {
        incoming.values.forEach { discard(it) }
        incoming.clear()
    }

    private fun discard(item: Incoming) {
        runCatching { item.out.close() }
        item.uri?.let { runCatching { resolver.delete(it, null, null) } }
        item.file?.delete()
    }

    private fun reply(id: UUID, ok: Boolean, message: String) {
        session()?.sendIfReady(
            JSONObject().put("t", "FILE_RESULT").put("id", id.toString()).put("ok", ok).put("message", message)
        )
    }

    // endregion

    // region Notifikasi

    private fun notifyProgress(id: Int, title: String, text: String, done: Long, total: Long) {
        val percent = if (total > 0) (done * 100 / total).toInt() else 100
        val notification = Notification.Builder(context, CHANNEL)
            .setSmallIcon(R.drawable.ic_stat_cursoe)
            .setContentTitle(title)
            .setContentText(text)
            .setProgress(100, percent, false)
            .setOnlyAlertOnce(true)
            .setOngoing(true)
            .build()
        notifications.notify(id, notification)
    }

    private fun notifyDone(title: String, text: String, uri: Uri?, mime: String?) {
        notifications.cancel(NOTIF_SEND)
        notifications.cancel(NOTIF_RECEIVE)
        val builder = Notification.Builder(context, CHANNEL)
            .setSmallIcon(R.drawable.ic_stat_cursoe)
            .setContentTitle(title)
            .setContentText(text)
            .setAutoCancel(true)
        if (uri != null) {
            val open = Intent(Intent.ACTION_VIEW).setDataAndType(uri, mime)
                .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
            builder.setContentIntent(
                PendingIntent.getActivity(context, uri.hashCode(), open, PendingIntent.FLAG_IMMUTABLE)
            )
        }
        notifications.notify(NOTIF_DONE_BASE + (System.currentTimeMillis() % 1000).toInt(), builder.build())
    }

    // endregion

    companion object {
        private const val TAG = "Cursoe"
        private const val CHANNEL = "files"
        private const val FOLDER = "Cursoe"
        private const val CHUNK_BYTES = 64 * 1024
        private const val NOTIF_SEND = 20
        private const val NOTIF_RECEIVE = 21
        private const val NOTIF_DONE_BASE = 1000

        fun hex(bytes: ByteArray) = bytes.joinToString("") { "%02x".format(it) }

        fun safeName(name: String): String {
            val cleaned = name.replace('/', '_').replace('\\', '_').trim().trimStart('.')
            return cleaned.ifEmpty { "file" }.take(200)
        }

        private fun uniqueFile(dir: File, name: String): File {
            var file = File(dir, name)
            var n = 1
            while (file.exists()) {
                file = File(dir, "${name.substringBeforeLast('.')} ($n)" +
                    if (name.contains('.')) ".${name.substringAfterLast('.')}" else "")
                n++
            }
            return file
        }
    }
}
