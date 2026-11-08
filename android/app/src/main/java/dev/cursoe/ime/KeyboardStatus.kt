package dev.cursoe.ime

import android.content.Context
import android.os.Build
import android.provider.Settings
import android.view.inputmethod.InputMethodManager

object KeyboardStatus {
    /** ID "Cursoe Keyboard" bila sudah diaktifkan pengguna di Settings, selain itu null. */
    fun ourImeId(context: Context): String? =
        context.getSystemService(InputMethodManager::class.java)
            .enabledInputMethodList
            .firstOrNull { it.packageName == context.packageName }
            ?.id

    fun isEnabled(context: Context): Boolean = ourImeId(context) != null

    /** ID keyboard yang sedang dipakai sistem. */
    fun currentImeId(context: Context): String? =
        if (Build.VERSION.SDK_INT >= 34) {
            context.getSystemService(InputMethodManager::class.java).currentInputMethodInfo?.id
        } else {
            Settings.Secure.getString(context.contentResolver, Settings.Secure.DEFAULT_INPUT_METHOD)
        }
}
