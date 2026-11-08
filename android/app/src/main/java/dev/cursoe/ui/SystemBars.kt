package dev.cursoe.ui

import android.app.Activity
import android.content.res.Configuration
import android.os.Build
import android.view.View
import android.view.WindowInsets
import android.view.WindowInsetsController

/**
 * Tampilan edge-to-edge: header sampai ke balik status bar, dan area bawah
 * (panel/scroll) sampai ke balik navigation bar. Warna ikon sistem ikut mode terang/gelap.
 */
object SystemBars {
    /**
     * @param header diberi padding atas setinggi status bar.
     * @param bottoms diberi padding bawah setinggi navigation bar.
     * @param fallbackNavColor warna navigation bar di Android 8–10 (belum edge-to-edge).
     */
    fun apply(activity: Activity, root: View, header: View, bottoms: List<View>, fallbackNavColor: Int) {
        val window = activity.window
        val night = (activity.resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK) ==
            Configuration.UI_MODE_NIGHT_YES
        if (Build.VERSION.SDK_INT >= 29) window.isNavigationBarContrastEnforced = false

        if (Build.VERSION.SDK_INT < 30) {
            @Suppress("DEPRECATION")
            run {
                window.statusBarColor = activity.getColor(dev.cursoe.R.color.gb_bg)
                window.navigationBarColor = fallbackNavColor
                val flags = window.decorView.systemUiVisibility
                window.decorView.systemUiVisibility = if (night) {
                    flags and View.SYSTEM_UI_FLAG_LIGHT_STATUS_BAR.inv()
                } else {
                    flags or View.SYSTEM_UI_FLAG_LIGHT_STATUS_BAR
                }
            }
            return
        }

        if (Build.VERSION.SDK_INT < 35) {
            @Suppress("DEPRECATION")
            window.setDecorFitsSystemWindows(false)
        }
        // Ikon gelap di mode terang (panel halaman utama kini kaca terang, bukan biru).
        val lightStatus = !night
        val lightNav = !night
        window.insetsController?.setSystemBarsAppearance(
            (if (lightStatus) WindowInsetsController.APPEARANCE_LIGHT_STATUS_BARS else 0) or
                (if (lightNav) WindowInsetsController.APPEARANCE_LIGHT_NAVIGATION_BARS else 0),
            WindowInsetsController.APPEARANCE_LIGHT_STATUS_BARS or WindowInsetsController.APPEARANCE_LIGHT_NAVIGATION_BARS,
        )

        val rootLeft = root.paddingLeft
        val rootRight = root.paddingRight
        val headerTop = header.paddingTop
        val bottomPads = bottoms.map { it.paddingBottom }
        root.setOnApplyWindowInsetsListener { _, insets ->
            val bars = insets.getInsets(WindowInsets.Type.systemBars() or WindowInsets.Type.displayCutout())
            root.setPadding(rootLeft + bars.left, root.paddingTop, rootRight + bars.right, root.paddingBottom)
            header.setPadding(header.paddingLeft, headerTop + bars.top, header.paddingRight, header.paddingBottom)
            bottoms.forEachIndexed { i, v ->
                v.setPadding(v.paddingLeft, v.paddingTop, v.paddingRight, bottomPads[i] + bars.bottom)
            }
            insets
        }
    }
}
