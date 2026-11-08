package dev.cursoe

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.net.ConnectivityManager
import android.os.Build
import java.net.Inet4Address

object Permissions {
    /** Android 17+ (API 37): akses ke perangkat di jaringan lokal adalah izin runtime. */
    fun hasLocalNetwork(context: Context): Boolean =
        Build.VERSION.SDK_INT < 37 ||
            context.checkSelfPermission(Manifest.permission.ACCESS_LOCAL_NETWORK) == PackageManager.PERMISSION_GRANTED

    fun runtimeWanted(context: Context): List<String> = buildList {
        if (Build.VERSION.SDK_INT >= 33) add(Manifest.permission.POST_NOTIFICATIONS)
        if (Build.VERSION.SDK_INT >= 37) add(Manifest.permission.ACCESS_LOCAL_NETWORK)
        // Membaca foto/video yang di-drag dari Galeri ke tepi Mac.
        if (Build.VERSION.SDK_INT >= 33) {
            add(Manifest.permission.READ_MEDIA_IMAGES)
            add(Manifest.permission.READ_MEDIA_VIDEO)
        }
    }.filter { context.checkSelfPermission(it) != PackageManager.PERMISSION_GRANTED }

    /** IPv4 HP di jaringan aktif (untuk koneksi manual dari Mac). */
    fun localIpv4(context: Context): String? {
        val cm = context.getSystemService(ConnectivityManager::class.java)
        val props = cm.getLinkProperties(cm.activeNetwork) ?: return null
        return props.linkAddresses.map { it.address }.firstOrNull { it is Inet4Address }?.hostAddress
    }
}
