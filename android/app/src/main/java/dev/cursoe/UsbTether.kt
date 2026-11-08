package dev.cursoe

import java.net.Inet4Address
import java.net.NetworkInterface

/**
 * Status Tethering USB dari antarmuka jaringan HP: `ncm0` (dikenali macOS tanpa driver),
 * `rndis0`/`usb0` (RNDIS — tidak dikenali macOS). Hanya membaca, tidak mengubah apa pun.
 */
object UsbTether {
    enum class Mode { OFF, NCM, RNDIS }

    fun mode(): Mode {
        val names = runCatching {
            NetworkInterface.getNetworkInterfaces()?.toList().orEmpty()
                .filter { iface -> iface.isUp && iface.inetAddresses.toList().any { it is Inet4Address } }
                .map { it.name }
        }.getOrDefault(emptyList())
        return when {
            names.any { it.startsWith("ncm") } -> Mode.NCM
            names.any { it.startsWith("rndis") || it.matches(Regex("usb\\d+")) } -> Mode.RNDIS
            else -> Mode.OFF
        }
    }
}
