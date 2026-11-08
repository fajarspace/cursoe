package dev.cursoe.clip

import android.content.ContentProvider
import android.content.ContentValues
import android.database.Cursor
import android.database.MatrixCursor
import android.net.Uri
import android.os.ParcelFileDescriptor
import android.provider.OpenableColumns
import java.io.File
import java.io.FileNotFoundException

/**
 * Menyajikan gambar clipboard dari Mac (cache/clip/…) ke aplikasi lain yang menempelnya.
 * Tidak di-export; akses diberikan per-URI oleh sistem clipboard (grantUriPermissions).
 * Pengganti FileProvider tanpa dependency AndroidX.
 */
class ClipImageProvider : ContentProvider() {

    override fun onCreate(): Boolean = true

    private fun fileFor(uri: Uri): File {
        val name = uri.lastPathSegment ?: throw FileNotFoundException("URI tanpa nama file")
        if (!NAME_PATTERN.matches(name)) throw FileNotFoundException("Nama file tidak valid")
        val file = File(dir(context!!.cacheDir), name)
        if (!file.isFile) throw FileNotFoundException(name)
        return file
    }

    override fun getType(uri: Uri): String =
        if (uri.lastPathSegment?.endsWith(".jpg") == true) "image/jpeg" else "image/png"

    override fun openFile(uri: Uri, mode: String): ParcelFileDescriptor {
        if (mode != "r") throw SecurityException("Hanya baca")
        return ParcelFileDescriptor.open(fileFor(uri), ParcelFileDescriptor.MODE_READ_ONLY)
    }

    override fun query(
        uri: Uri, projection: Array<out String>?, selection: String?,
        selectionArgs: Array<out String>?, sortOrder: String?,
    ): Cursor {
        val file = fileFor(uri)
        val columns = projection ?: arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE)
        return MatrixCursor(columns, 1).apply {
            addRow(columns.map { column ->
                when (column) {
                    OpenableColumns.DISPLAY_NAME -> file.name
                    OpenableColumns.SIZE -> file.length()
                    else -> null
                }
            })
        }
    }

    override fun insert(uri: Uri, values: ContentValues?): Uri? = null
    override fun update(uri: Uri, values: ContentValues?, selection: String?, selectionArgs: Array<out String>?) = 0
    override fun delete(uri: Uri, selection: String?, selectionArgs: Array<out String>?) = 0

    companion object {
        const val AUTHORITY = "dev.cursoe.clip"
        private val NAME_PATTERN = Regex("""mac-\d+\.(png|jpg)""")

        fun dir(cacheDir: File) = File(cacheDir, "clip")
        fun uriFor(file: File): Uri = Uri.parse("content://$AUTHORITY/${file.name}")
    }
}
