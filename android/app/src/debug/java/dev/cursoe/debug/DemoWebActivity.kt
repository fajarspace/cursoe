package dev.cursoe.debug

import android.annotation.SuppressLint
import android.app.Activity
import android.graphics.Color
import android.os.Build
import android.os.Bundle
import android.view.WindowInsets
import android.view.WindowInsetsController
import android.webkit.WebView
import android.webkit.WebViewClient

/**
 * Hanya build debug: halaman web layar penuh (tanpa bilah tab/alamat) untuk rekaman video demo.
 * URL dari data intent, mis. website Cursoe yang disajikan Mac lewat `adb reverse tcp:5317 tcp:5317`:
 *   adb shell am start -n dev.cursoe/.debug.DemoWebActivity -d "http://localhost:5317/#cara-kerja"
 * Bila URL punya #anchor, halaman digulir ke sana setelah selesai dimuat (situs React).
 */
class DemoWebActivity : Activity() {
    @SuppressLint("SetJavaScriptEnabled")
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val url = intent.dataString ?: "http://localhost:5317/"
        val anchor = url.substringAfter('#', "")
        val web = WebView(this).apply {
            setBackgroundColor(Color.BLACK)
            settings.javaScriptEnabled = true
            settings.domStorageEnabled = true
            settings.mediaPlaybackRequiresUserGesture = false
            webViewClient = object : WebViewClient() {
                override fun onPageFinished(view: WebView, loaded: String) {
                    if (anchor.isNotEmpty()) view.postDelayed({
                        view.evaluateJavascript(
                            "document.getElementById('$anchor')?.scrollIntoView({behavior:'instant'})", null,
                        )
                    }, 900)
                }
            }
            loadUrl(url)
        }
        setContentView(web)
        if (Build.VERSION.SDK_INT >= 30) {
            window.insetsController?.apply {
                hide(WindowInsets.Type.statusBars())
                systemBarsBehavior = WindowInsetsController.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
            }
        }
    }
}
