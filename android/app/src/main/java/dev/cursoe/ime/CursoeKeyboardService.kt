package dev.cursoe.ime

import android.inputmethodservice.InputMethodService
import android.os.Build
import android.os.SystemClock
import android.text.InputType
import android.util.Log
import android.util.TypedValue
import android.view.Gravity
import android.view.KeyCharacterMap
import android.view.KeyEvent
import android.view.View
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputConnection
import android.view.inputmethod.InputMethodManager
import android.widget.Button
import android.widget.LinearLayout
import android.widget.TextView
import dev.cursoe.cursor.InputRouter
import dev.cursoe.tr

/**
 * "Cursoe Keyboard": IME minimal yang menerima teks & tombol dari keyboard Mac
 * dan memasukkannya ke kolom teks yang sedang fokus lewat InputConnection.
 * Tampilannya hanya strip kecil; mengetik dilakukan dari Mac.
 */
class CursoeKeyboardService : InputMethodService() {

    override fun onCreate() {
        super.onCreate()
        InputRouter.attachKeyboard(this)
        Log.i(TAG, "Cursoe Keyboard aktif")
    }

    override fun onDestroy() {
        InputRouter.detachKeyboard(this)
        super.onDestroy()
    }

    override fun onEvaluateFullscreenMode(): Boolean = false

    override fun onCreateInputView(): View {
        val density = resources.displayMetrics.density
        val strip = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setBackgroundColor(0xFF1F2024.toInt())
            val pad = (12 * density).toInt()
            setPadding(pad, 0, pad / 2, 0)
            minimumHeight = (44 * density).toInt()
        }
        val label = TextView(this).apply {
            text = tr("⌨︎  Typing from your Mac keyboard — Cursoe", "⌨︎  Mengetik dari keyboard Mac — Cursoe")
            setTextColor(0xFFE8EAED.toInt())
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 14f)
        }
        val switchButton = Button(this, null, android.R.attr.borderlessButtonStyle).apply {
            text = tr("Switch keyboard", "Ganti keyboard")
            setTextColor(0xFF8AB4F8.toInt())
            setOnClickListener { switchAway() }
        }
        strip.addView(label, LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f))
        strip.addView(switchButton)
        return strip
    }

    private fun switchAway() {
        if (Build.VERSION.SDK_INT >= 28 && switchToPreviousInputMethod()) return
        getSystemService(InputMethodManager::class.java).showInputMethodPicker()
    }

    // region Dari Mac (main thread)

    fun commitText(text: String) {
        currentInputConnection?.commitText(text, 1)
    }

    /** @return false bila tombol tidak dikenal. */
    fun key(name: String, mods: Set<String>): Boolean {
        val ic = currentInputConnection ?: return false
        val shift = "shift" in mods
        val alt = "alt" in mods
        val cmd = "cmd" in mods || "ctrl" in mods
        val shiftMeta = if (shift) SHIFT else 0

        if (cmd) {
            when (name) {
                "a" -> return ic.performContextMenuAction(android.R.id.selectAll)
                "c" -> return ic.performContextMenuAction(android.R.id.copy)
                "x" -> return ic.performContextMenuAction(android.R.id.cut)
                "v" -> return ic.performContextMenuAction(android.R.id.paste)
                "z" -> return sendKey(ic, KeyEvent.KEYCODE_Z, CTRL or shiftMeta) // ⌘⇧Z = redo
            }
        }
        return when (name) {
            // ⌥⌫ hapus kata, ⌘⌫ hapus sampai awal baris (perilaku keyboard fisik Android)
            "backspace" -> sendKey(ic, KeyEvent.KEYCODE_DEL, if ("cmd" in mods) ALT else if (alt) CTRL else 0)
            "delete" -> sendKey(ic, KeyEvent.KEYCODE_FORWARD_DEL, if (alt) CTRL else 0)
            "enter" -> enter(ic, shift)
            "tab" -> sendKey(ic, KeyEvent.KEYCODE_TAB, shiftMeta)
            "left", "right" -> {
                val left = name == "left"
                when {
                    "cmd" in mods -> sendKey(ic, if (left) KeyEvent.KEYCODE_MOVE_HOME else KeyEvent.KEYCODE_MOVE_END, shiftMeta)
                    alt -> sendKey(ic, if (left) KeyEvent.KEYCODE_DPAD_LEFT else KeyEvent.KEYCODE_DPAD_RIGHT, CTRL or shiftMeta)
                    else -> sendKey(ic, if (left) KeyEvent.KEYCODE_DPAD_LEFT else KeyEvent.KEYCODE_DPAD_RIGHT, shiftMeta)
                }
            }
            "up", "down" -> {
                val up = name == "up"
                if ("cmd" in mods) {
                    sendKey(ic, if (up) KeyEvent.KEYCODE_MOVE_HOME else KeyEvent.KEYCODE_MOVE_END, CTRL or shiftMeta)
                } else {
                    sendKey(ic, if (up) KeyEvent.KEYCODE_DPAD_UP else KeyEvent.KEYCODE_DPAD_DOWN, shiftMeta)
                }
            }
            "home" -> sendKey(ic, KeyEvent.KEYCODE_MOVE_HOME, shiftMeta)
            "end" -> sendKey(ic, KeyEvent.KEYCODE_MOVE_END, shiftMeta)
            "pageup" -> sendKey(ic, KeyEvent.KEYCODE_PAGE_UP, shiftMeta)
            "pagedown" -> sendKey(ic, KeyEvent.KEYCODE_PAGE_DOWN, shiftMeta)
            else -> false
        }
    }

    // endregion

    /**
     * Enter seperti di Mac:
     * - kolom satu baris: jalankan aksi IME (Cari/Kirim/Lanjut…);
     * - kolom multi-baris: ⇧Enter selalu baris baru; Enter = baris baru, kecuali di aplikasi chat
     *   yang mengirim pesan lewat ⇧Enter (WhatsApp) — di sana Enter = kirim.
     */
    private fun enter(ic: InputConnection, shift: Boolean): Boolean {
        val info = currentInputEditorInfo
        val action = info.imeOptions and EditorInfo.IME_MASK_ACTION
        val multiLine = info.inputType and InputType.TYPE_TEXT_FLAG_MULTI_LINE != 0
        val noEnterAction = info.imeOptions and EditorInfo.IME_FLAG_NO_ENTER_ACTION != 0
        val hasAction = action != EditorInfo.IME_ACTION_NONE && action != EditorInfo.IME_ACTION_UNSPECIFIED

        if (!multiLine) {
            return if (!shift && !noEnterAction && hasAction) {
                ic.performEditorAction(action)
            } else {
                sendKey(ic, KeyEvent.KEYCODE_ENTER, if (shift) SHIFT else 0)
            }
        }
        // Teks "\n" langsung masuk ke kolom tanpa lewat pendengar tombol aplikasi,
        // jadi tidak pernah memicu "kirim".
        if (shift) return ic.commitText("\n", 1)
        val sendMeta = if (info.packageName in SHIFT_ENTER_SENDS) SHIFT else 0
        return sendKey(ic, KeyEvent.KEYCODE_ENTER, sendMeta)
    }

    private fun sendKey(ic: InputConnection, code: Int, meta: Int): Boolean {
        val now = SystemClock.uptimeMillis()
        val flags = KeyEvent.FLAG_SOFT_KEYBOARD or KeyEvent.FLAG_KEEP_TOUCH_MODE
        val down = KeyEvent(now, now, KeyEvent.ACTION_DOWN, code, 0, meta, KeyCharacterMap.VIRTUAL_KEYBOARD, 0, flags)
        val up = KeyEvent(now, now, KeyEvent.ACTION_UP, code, 0, meta, KeyCharacterMap.VIRTUAL_KEYBOARD, 0, flags)
        return ic.sendKeyEvent(down) && ic.sendKeyEvent(up)
    }

    private companion object {
        const val TAG = "Cursoe"
        const val SHIFT = KeyEvent.META_SHIFT_ON or KeyEvent.META_SHIFT_LEFT_ON
        const val CTRL = KeyEvent.META_CTRL_ON or KeyEvent.META_CTRL_LEFT_ON
        const val ALT = KeyEvent.META_ALT_ON or KeyEvent.META_ALT_LEFT_ON

        /**
         * Aplikasi yang (dengan setelan bawaannya, "Enter untuk kirim" mati) mengirim pesan saat
         * menerima ⇧Enter dari keyboard fisik dan membuat baris baru saat Enter biasa.
         */
        val SHIFT_ENTER_SENDS = setOf("com.whatsapp", "com.whatsapp.w4b")
    }
}
