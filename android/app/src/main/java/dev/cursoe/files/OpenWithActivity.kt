package dev.cursoe.files

import android.animation.ValueAnimator
import android.annotation.TargetApi
import android.app.Activity
import android.content.ClipData
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ResolveInfo
import android.content.res.ColorStateList
import android.content.res.Configuration
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.Drawable
import android.graphics.drawable.GradientDrawable
import android.graphics.drawable.RippleDrawable
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.OpenableColumns
import android.text.TextUtils
import android.text.format.Formatter
import android.util.Log
import android.util.Size
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.view.ViewGroup
import android.view.WindowInsets
import android.view.WindowManager
import android.view.animation.DecelerateInterpolator
import android.view.animation.OvershootInterpolator
import android.view.animation.AccelerateInterpolator
import android.webkit.MimeTypeMap
import android.widget.FrameLayout
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import android.widget.Toast
import android.window.OnBackInvokedDispatcher
import dev.cursoe.R
import kotlin.concurrent.thread

/**
 * Mac → HP: file sudah tersimpan di Download/Cursoe, lalu pengguna memilih
 * "Simpan" (tutup), buka dengan aplikasi yang cocok dengan jenis file, atau "Lainnya…" (Bagikan).
 * × = jangan simpan (file dihapus). Ketuk di luar / Back = simpan.
 *
 * Responsif: bottom sheet di HP, kartu di tengah pada layar lebar (layar lipat terbuka, tablet).
 * Kolom ikon menyesuaikan lebar (4–6). Gaya kaca bersih seperti Luma: layar di belakang diburamkan
 * (Android 12+, bila perangkat mengizinkan blur), panel sedikit tembus pandang, aksen monokrom
 * (hitam di mode terang, putih di mode gelap). Tanpa bayangan; animasi masuk/keluar & tekan.
 */
class OpenWithActivity : Activity() {

    private lateinit var uris: ArrayList<Uri>
    private lateinit var names: ArrayList<String>
    private lateinit var mime: String
    private lateinit var scrim: View
    private lateinit var sheet: LinearLayout
    private val cells = mutableListOf<View>()
    private var asSheet = true
    private var closing = false
    /** Radius blur layar di belakang panel; 0 = blur tidak tersedia (panel dibuat buram penuh). */
    private var blurRadius = 0
    private val night get() =
        (resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK) == Configuration.UI_MODE_NIGHT_YES

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        @Suppress("DEPRECATION")
        uris = intent.getParcelableArrayListExtra(EXTRA_URIS) ?: arrayListOf()
        names = intent.getStringArrayListExtra(EXTRA_NAMES) ?: arrayListOf()
        mime = resolveMime(intent.getStringExtra(EXTRA_MIME), names)
        if (uris.isEmpty()) return finish()

        // Layar sempit (HP) → bottom sheet; layar lebar (lipat terbuka, tablet) → kartu di tengah.
        asSheet = intent.getBooleanExtra(EXTRA_FORCE_SHEET, false) || resources.configuration.screenWidthDp < 600
        setUpWindow()
        val root = buildRoot()
        setContentView(root)
        sheet.visibility = View.INVISIBLE
        root.post { animateIn() }

        if (Build.VERSION.SDK_INT >= 33) {
            onBackInvokedDispatcher.registerOnBackInvokedCallback(OnBackInvokedDispatcher.PRIORITY_DEFAULT) { dismiss(saved = true) }
        }
    }

    @Deprecated("Android 12 ke bawah")
    @Suppress("DEPRECATION")
    override fun onBackPressed() = dismiss(saved = true)

    override fun finish() {
        super.finish()
        if (Build.VERSION.SDK_INT >= 34) {
            overrideActivityTransition(OVERRIDE_TRANSITION_CLOSE, 0, 0)
        } else {
            @Suppress("DEPRECATION")
            overridePendingTransition(0, 0)
        }
    }

    // region Jendela & tata letak

    private fun setUpWindow() {
        if (Build.VERSION.SDK_INT in 30..34) {
            @Suppress("DEPRECATION")
            window.setDecorFitsSystemWindows(false)
        }
        if (Build.VERSION.SDK_INT >= 29) window.isNavigationBarContrastEnforced = false
        // Blur isi layar di belakang panel (dimatikan sistem saat hemat daya / pada perangkat lemah).
        if (Build.VERSION.SDK_INT >= 31 && windowManager.isCrossWindowBlurEnabled) {
            @Suppress("DEPRECATION")
            window.addFlags(WindowManager.LayoutParams.FLAG_BLUR_BEHIND)
            blurRadius = dp(30)
            setBlur(0)
        }
    }

    @TargetApi(31)
    private fun setBlur(radius: Int) {
        window.attributes = window.attributes.apply { blurBehindRadius = radius }
    }

    /** Blur naik/turun bersama animasi panel. */
    private fun animateBlur(to: Int, duration: Long) {
        if (blurRadius == 0 || Build.VERSION.SDK_INT < 31) return
        ValueAnimator.ofInt(window.attributes.blurBehindRadius, to).apply {
            this.duration = duration
            addUpdateListener { setBlur(it.animatedValue as Int) }
            start()
        }
    }

    private fun buildRoot(): View {
        val root = FrameLayout(this)
        scrim = View(this).apply {
            setBackgroundColor(Color.BLACK)
            alpha = 0f
            setOnClickListener { dismiss(saved = true) }
        }
        root.addView(scrim, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))

        val screenWidth = resources.displayMetrics.widthPixels
        val sheetWidth = if (asSheet) screenWidth else minOf(dp(480), screenWidth - dp(48))
        sheet = buildSheet(sheetWidth)
        root.addView(sheet, FrameLayout.LayoutParams(
            if (asSheet) ViewGroup.LayoutParams.MATCH_PARENT else sheetWidth,
            ViewGroup.LayoutParams.WRAP_CONTENT,
            if (asSheet) Gravity.BOTTOM else Gravity.CENTER,
        ))

        // Edge-to-edge: bottom sheet sampai ke balik navigation bar, isinya tetap di atasnya.
        val baseBottom = sheet.paddingBottom
        root.setOnApplyWindowInsetsListener { _, insets ->
            val bottom = if (Build.VERSION.SDK_INT >= 30) {
                insets.getInsets(WindowInsets.Type.systemBars()).bottom
            } else {
                @Suppress("DEPRECATION")
                insets.systemWindowInsetBottom
            }
            if (asSheet) sheet.setPadding(sheet.paddingLeft, sheet.paddingTop, sheet.paddingRight, baseBottom + bottom)
            insets
        }
        return root
    }

    private fun buildSheet(width: Int): LinearLayout {
        val radius = dp(24).toFloat()
        val background = GradientDrawable().apply {
            // Kaca: tembus pandang di atas layar yang sudah diburamkan; tanpa blur → buram penuh.
            setColor(getColor(if (blurRadius > 0) R.color.gb_glass else R.color.gb_bg))
            setStroke(dp(1), getColor(R.color.gb_border))
            cornerRadii = if (asSheet) floatArrayOf(radius, radius, radius, radius, 0f, 0f, 0f, 0f) else FloatArray(8) { radius }
        }
        val column = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            this.background = background
            setPadding(dp(20), dp(if (asSheet) 10 else 20), dp(20), dp(14))
            isClickable = true // klik di dalam panel tidak menutup panel
        }
        if (asSheet) {
            column.addView(View(this).apply {
                this.background = GradientDrawable().apply {
                    setColor(getColor(R.color.gb_text_secondary)); alpha = 90; cornerRadius = dp(2).toFloat()
                }
            }, LinearLayout.LayoutParams(dp(36), dp(4)).apply {
                gravity = Gravity.CENTER_HORIZONTAL
                bottomMargin = dp(14)
            })
        }
        column.addView(buildHeader())
        column.addView(buildGrid(width - dp(40)), LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT,
        ).apply { topMargin = dp(14) })
        return column
    }

    /** Thumbnail · nama & ukuran · tombol tutup. */
    private fun buildHeader(): View = LinearLayout(this).apply {
        orientation = LinearLayout.HORIZONTAL
        gravity = Gravity.CENTER_VERTICAL

        addView(buildThumbnail(), LinearLayout.LayoutParams(dp(48), dp(48)))

        val texts = LinearLayout(this@OpenWithActivity).apply { orientation = LinearLayout.VERTICAL }
        val subtitle = label("Download/Cursoe", 12.5f, R.color.gb_text_secondary)
        texts.addView(label(
            if (uris.size == 1) names.firstOrNull() ?: "File dari Mac" else "${uris.size} file dari Mac",
            16f, R.color.gb_text, bold = true,
        ).apply { maxLines = 1; ellipsize = TextUtils.TruncateAt.MIDDLE })
        texts.addView(subtitle.apply { setPadding(0, dp(2), 0, 0) })
        addView(texts, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f).apply {
            marginStart = dp(14); marginEnd = dp(8)
        })
        // Ukuran file dibaca di latar belakang agar panel langsung tampil.
        thread(name = "cursoe-openwith-size", isDaemon = true) {
            val total = uris.sumOf { uri ->
                runCatching {
                    contentResolver.query(uri, arrayOf(OpenableColumns.SIZE), null, null, null)?.use { c ->
                        if (c.moveToFirst() && !c.isNull(0)) c.getLong(0) else 0L
                    } ?: 0L
                }.getOrDefault(0L)
            }
            if (total > 0) runOnUiThread {
                subtitle.text = "Download/Cursoe · ${Formatter.formatShortFileSize(this@OpenWithActivity, total)}"
            }
        }

        addView(ImageView(this@OpenWithActivity).apply {
            setImageResource(R.drawable.ic_close)
            imageTintList = ColorStateList.valueOf(getColor(R.color.gb_text_secondary))
            scaleType = ImageView.ScaleType.CENTER_INSIDE
            setPadding(dp(8), dp(8), dp(8), dp(8))
            background = RippleDrawable(
                ColorStateList.valueOf(getColor(R.color.gb_text) and 0x22FFFFFF),
                GradientDrawable().apply { shape = GradientDrawable.OVAL; setColor(getColor(R.color.gb_glass_chip)) },
                null,
            )
            contentDescription = "Jangan simpan"
            setOnClickListener { dismiss(saved = false) } // × = file dihapus
            addPressEffect(this)
        }, LinearLayout.LayoutParams(dp(38), dp(38)))
    }

    /** Pratinjau asli untuk foto/video; selain itu label jenis file (PDF, ZIP, …) atau jumlah file. */
    private fun buildThumbnail(): View {
        val frame = FrameLayout(this).apply {
            background = GradientDrawable().apply { setColor(getColor(R.color.gb_glass_chip)); cornerRadius = dp(12).toFloat() }
            clipToOutline = true
        }
        val badge = label(
            if (uris.size > 1) "${uris.size}" else names.firstOrNull()?.substringAfterLast('.', "")?.uppercase()?.take(4)
                ?.ifEmpty { null } ?: "FILE",
            if (uris.size > 1) 17f else 12f, R.color.gb_text, bold = true,
        ).apply { gravity = Gravity.CENTER }
        frame.addView(badge, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))

        val visual = uris.size == 1 && (mime.startsWith("image/") || mime.startsWith("video/"))
        if (visual && Build.VERSION.SDK_INT >= 29) {
            val image = ImageView(this).apply { scaleType = ImageView.ScaleType.CENTER_CROP; alpha = 0f }
            frame.addView(image, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
            thread(name = "cursoe-openwith-thumb", isDaemon = true) {
                val bitmap = runCatching { contentResolver.loadThumbnail(uris[0], Size(dp(96), dp(96)), null) }.getOrNull()
                if (bitmap != null) runOnUiThread {
                    image.setImageBitmap(bitmap)
                    image.animate().alpha(1f).setDuration(180).start()
                }
            }
        }
        return frame
    }

    /** "Simpan" · aplikasi yang cocok · "Lainnya…". Kolom 4–6 sesuai lebar; maks ±3 baris lalu scroll. */
    private fun buildGrid(contentWidth: Int): View {
        val columns = (contentWidth / dp(84)).coerceIn(4, 6)
        val items = mutableListOf<View>()
        items += cell(circleIcon(R.drawable.ic_save, filled = true), "Simpan") { dismiss(saved = true) }
        matchingApps().forEach { info ->
            val icon = ImageView(this).apply { setImageDrawable(info.loadIcon(packageManager)) }
            items += cell(icon, info.loadLabel(packageManager).toString()) { launch(info) }
        }
        items += cell(circleIcon(R.drawable.ic_share, filled = false), "Lainnya…") {
            openShareSheet(this, uris, mime)
            finish()
        }
        cells += items

        val grid = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        items.chunked(columns).forEach { rowItems ->
            val row = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL }
            rowItems.forEach { row.addView(it, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f)) }
            repeat(columns - rowItems.size) { row.addView(View(this), LinearLayout.LayoutParams(0, 1, 1f)) }
            grid.addView(row)
        }
        val rows = (items.size + columns - 1) / columns
        val scroll = ScrollView(this).apply {
            isVerticalScrollBarEnabled = false
            overScrollMode = View.OVER_SCROLL_NEVER
            addView(grid)
        }
        // Lebih dari 3 baris: tampilkan 3,4 baris agar terlihat bisa di-scroll, panel tetap ringkas.
        if (rows > 3) scroll.layoutParams = LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, (dp(CELL_HEIGHT) * 3.4f).toInt())
        return scroll
    }

    private fun cell(icon: View, title: String, onClick: () -> Unit): View = LinearLayout(this).apply {
        orientation = LinearLayout.VERTICAL
        gravity = Gravity.CENTER_HORIZONTAL
        minimumHeight = dp(CELL_HEIGHT)
        setPadding(dp(2), dp(8), dp(2), dp(6))
        background = ripple(GradientDrawable().apply { cornerRadius = dp(16).toFloat(); setColor(Color.WHITE) })
        addView(icon, LinearLayout.LayoutParams(dp(48), dp(48)))
        addView(label(title, 12f, R.color.gb_text).apply {
            gravity = Gravity.CENTER
            maxLines = 1
            ellipsize = TextUtils.TruncateAt.END
            setPadding(dp(2), dp(7), dp(2), 0)
        }, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT))
        contentDescription = title
        setOnClickListener { onClick() }
        addPressEffect(this)
    }

    private fun circleIcon(res: Int, filled: Boolean): View = FrameLayout(this).apply {
        background = GradientDrawable().apply {
            shape = GradientDrawable.OVAL
            setColor(getColor(if (filled) R.color.gb_ink else R.color.gb_glass_chip))
        }
        addView(ImageView(this@OpenWithActivity).apply {
            setImageResource(res)
            imageTintList = ColorStateList.valueOf(getColor(if (filled) R.color.gb_on_ink else R.color.gb_text))
        }, FrameLayout.LayoutParams(dp(22), dp(22), Gravity.CENTER))
    }

    private fun label(value: String, size: Float, color: Int, bold: Boolean = false) = TextView(this).apply {
        text = value
        textSize = size
        setTextColor(getColor(color))
        if (bold) setTypeface(typeface, Typeface.BOLD)
    }

    private fun ripple(mask: Drawable) =
        RippleDrawable(ColorStateList.valueOf(getColor(R.color.gb_text) and 0x22FFFFFF), null, mask)

    private fun dp(value: Int) = (value * resources.displayMetrics.density).toInt()

    // endregion

    // region Animasi

    private fun animateIn() {
        // Dengan blur cukup redup tipis; tanpa blur perlu lebih gelap agar panel menonjol.
        val dim = when {
            blurRadius > 0 -> if (night) 0.35f else 0.12f
            else -> 0.45f
        }
        scrim.animate().alpha(dim).setDuration(220).start()
        animateBlur(blurRadius, 260)
        sheet.visibility = View.VISIBLE
        if (asSheet) {
            sheet.translationY = sheet.height.toFloat()
            sheet.animate().translationY(0f).setDuration(320).setInterpolator(DecelerateInterpolator(2.4f)).start()
        } else {
            sheet.alpha = 0f
            sheet.scaleX = 0.94f
            sheet.scaleY = 0.94f
            sheet.animate().alpha(1f).scaleX(1f).scaleY(1f).setDuration(260)
                .setInterpolator(OvershootInterpolator(0.8f)).start()
        }
        // Ikon muncul berurutan.
        cells.forEachIndexed { i, cell ->
            cell.alpha = 0f
            cell.translationY = dp(10).toFloat()
            cell.animate().alpha(1f).translationY(0f).setStartDelay(90L + i * 22L).setDuration(240)
                .setInterpolator(DecelerateInterpolator()).start()
        }
    }

    /**
     * Tutup dengan animasi. [saved] = file tetap tersimpan (Simpan / ketuk di luar / Back);
     * false = tombol ×: file yang baru diterima dihapus.
     */
    private fun dismiss(saved: Boolean) {
        if (closing) return
        closing = true
        if (saved) {
            Toast.makeText(this, "Tersimpan di Download/Cursoe", Toast.LENGTH_SHORT).show()
        } else {
            val deleted = uris.count { uri -> runCatching { contentResolver.delete(uri, null, null) > 0 }.getOrDefault(false) }
            Log.i(TAG, "File dari Mac tidak disimpan: $deleted/${uris.size} dihapus")
            Toast.makeText(this, "File tidak disimpan", Toast.LENGTH_SHORT).show()
        }
        scrim.animate().alpha(0f).setDuration(180).start()
        animateBlur(0, 180)
        val out = if (asSheet) {
            sheet.animate().translationY(sheet.height.toFloat()).setDuration(200).setInterpolator(AccelerateInterpolator(1.6f))
        } else {
            sheet.animate().alpha(0f).scaleX(0.96f).scaleY(0.96f).setDuration(160)
        }
        out.withEndAction { finish() }.start()
    }

    /** Mengecil sedikit saat ditekan, memantul kembali saat dilepas. */
    private fun addPressEffect(view: View) {
        view.setOnTouchListener { v, event ->
            when (event.actionMasked) {
                MotionEvent.ACTION_DOWN -> v.animate().scaleX(0.92f).scaleY(0.92f).setDuration(90).start()
                MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL ->
                    v.animate().scaleX(1f).scaleY(1f).setDuration(220).setInterpolator(OvershootInterpolator(3f)).start()
            }
            false // klik & ripple tetap berjalan
        }
    }

    // endregion

    // region Aplikasi

    /** Satu file: aplikasi yang bisa MEMBUKA-nya. Beberapa file: aplikasi yang bisa MENERIMA semuanya. */
    private fun baseIntent(): Intent = if (uris.size == 1) {
        Intent(Intent.ACTION_VIEW).setDataAndType(uris[0], mime)
    } else {
        Intent(Intent.ACTION_SEND_MULTIPLE).setType(mime).putParcelableArrayListExtra(Intent.EXTRA_STREAM, uris)
    }.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)

    private fun matchingApps(): List<ResolveInfo> {
        val pm = packageManager
        val found = if (Build.VERSION.SDK_INT >= 33) {
            pm.queryIntentActivities(baseIntent(), PackageManager.ResolveInfoFlags.of(PackageManager.MATCH_DEFAULT_ONLY.toLong()))
        } else {
            @Suppress("DEPRECATION")
            pm.queryIntentActivities(baseIntent(), PackageManager.MATCH_DEFAULT_ONLY)
        }
        return found
            .filter { it.activityInfo.packageName != packageName }
            .distinctBy { it.activityInfo.packageName + "/" + it.activityInfo.name }
            .sortedBy { it.loadLabel(pm).toString().lowercase() }
    }

    private fun launch(info: ResolveInfo) {
        val intent = baseIntent()
            .setClassName(info.activityInfo.packageName, info.activityInfo.name)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        if (uris.size > 1) intent.clipData = clipOf(this, uris)
        try {
            startActivity(intent)
        } catch (e: RuntimeException) {
            Log.w(TAG, "Tidak bisa membuka ${info.activityInfo.packageName}: ${e.message}")
            Toast.makeText(this, "Aplikasi tidak bisa membuka file ini", Toast.LENGTH_SHORT).show()
        }
        finish()
    }

    // endregion

    companion object {
        private const val TAG = "Cursoe"
        private const val CELL_HEIGHT = 86
        private const val EXTRA_URIS = "uris"
        private const val EXTRA_NAMES = "names"
        private const val EXTRA_MIME = "mime"
        /** Hanya untuk uji debug: paksa tampilan bottom sheet. */
        const val EXTRA_FORCE_SHEET = "forceSheet"

        /** Dipanggil (main thread) setelah semua file kiriman Mac tersimpan. */
        fun show(context: Context, uris: List<Uri>, mime: String, names: List<String>, forceSheet: Boolean = false) {
            if (uris.isEmpty()) return
            val intent = Intent(context, OpenWithActivity::class.java)
                .putParcelableArrayListExtra(EXTRA_URIS, ArrayList(uris))
                .putStringArrayListExtra(EXTRA_NAMES, ArrayList(names))
                .putExtra(EXTRA_MIME, mime)
                .putExtra(EXTRA_FORCE_SHEET, forceSheet)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_NO_ANIMATION)
            try {
                context.startActivity(intent)
            } catch (e: RuntimeException) {
                Log.w(TAG, "Tidak bisa menampilkan pilihan aplikasi: ${e.message}")
            }
        }

        fun openShareSheet(context: Context, uris: List<Uri>, mime: String) {
            val send = if (uris.size == 1) {
                Intent(Intent.ACTION_SEND).putExtra(Intent.EXTRA_STREAM, uris[0])
            } else {
                Intent(Intent.ACTION_SEND_MULTIPLE).putParcelableArrayListExtra(Intent.EXTRA_STREAM, ArrayList(uris))
            }
            send.type = mime
            send.clipData = clipOf(context, uris)
            send.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            val chooser = Intent.createChooser(send, "Kirim file dari Mac ke…")
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_GRANT_READ_URI_PERMISSION)
            try {
                context.startActivity(chooser)
            } catch (e: RuntimeException) {
                Log.w(TAG, "Tidak bisa membuka menu Bagikan: ${e.message}")
            }
        }

        private fun clipOf(context: Context, uris: List<Uri>) =
            ClipData.newUri(context.contentResolver, "Cursoe", uris[0]).apply {
                uris.drop(1).forEach { addItem(ClipData.Item(it)) }
            }

        /** MIME dari Mac; bila umum/kosong, tebak dari ekstensi nama file agar daftar aplikasinya tepat. */
        private fun resolveMime(given: String?, names: List<String>): String {
            if (!given.isNullOrBlank() && given != "application/octet-stream" && given != "*/*") return given
            val guessed = names.map { name ->
                MimeTypeMap.getSingleton().getMimeTypeFromExtension(name.substringAfterLast('.', "").lowercase())
            }.distinct()
            return guessed.singleOrNull() ?: given?.takeIf { it.isNotBlank() } ?: "*/*"
        }
    }
}
