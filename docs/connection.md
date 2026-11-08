# Connection

Cursoe connects the Mac and the Android device directly: over a USB cable, the device's hotspot, or a shared Wi-Fi
network. Choose the mode in the Mac menu under **Koneksi**:

| Mode | Behavior |
|---|---|
| **Otomatis** (automatic, default) | Uses the USB cable when the device is plugged in, otherwise Wi-Fi or hotspot. Unplugging switches to Wi-Fi or hotspot; plugging in switches back to the cable once the cursor is on the Mac. |
| **Kabel USB** (USB cable) | Always use the cable. |
| **Wi-Fi / hotspot** | Bonjour discovery, or a manual IP address. |

Measured round-trip times (Galaxy Z Fold6 and MacBook Pro):

| Path | Round trip |
|---|---|
| USB cable | 3–9 ms |
| Phone hotspot | 11–35 ms |
| Busy Wi-Fi with client isolation (different subnets, manual IP) | about 100 ms |

## USB cable

The Mac checks for a cable every 2 seconds and tries two paths. The current status is shown in the **Koneksi**
submenu.

### 1. USB tethering (preferred, no USB debugging needed)

- On Android, turn on **USB tethering**. The Cursoe settings screen has a shortcut (**Kabel USB ke Mac**). Android
  turns tethering off whenever the cable is unplugged.
- The Mac gets a wired network with the device as its gateway. It sends a `CURSOE?` UDP probe to the gateway, the
  device replies with its ID and name, and the Mac connects to `gateway:47800`.
- **Tethering must use NCM mode.** macOS has no RNDIS driver. The Cursoe settings screen shows which mode the device
  is using.
- Many Samsung devices use RNDIS by default. To switch to NCM, run this once from the Mac (USB debugging must be on
  for this step), then turn USB tethering off and on again:

  ```bash
  adb shell settings put global tether_force_usb_function 1   # 1 = NCM, 0 = RNDIS
  ```

  Not every device supports NCM. If the Mac still does not see a new network, set it back to `0`.
- Side effect: macOS may route internet traffic through this network, using mobile data. Put Wi-Fi first in
  *System Settings › Network › ⋯ › Set Service Order*.

### 2. USB debugging (fallback)

- The Mac runs `adb forward tcp:47801 tcp:47800` and connects to `127.0.0.1:47801`.
- Requires `adb` (`brew install --cask android-platform-tools`) and **USB debugging** enabled. The first time, accept
  "Allow USB debugging" for this Mac on the device.
- Some banking apps refuse to run while USB debugging is on. Prefer USB tethering or a wireless connection.

Charging the device over the same cable is a bonus.

## Wi-Fi and hotspot

- **Discovery:** the Android app advertises `_cursoe._tcp` on port **47800**, and the Mac finds it with Bonjour.
- **Best option: connect the Mac to the device's hotspot.** Latency is low, usually under 30 ms.
- **Home Wi-Fi** usually works well.
- **Office or campus Wi-Fi** often isolates clients on different subnets or blocks multicast. Bonjour cannot find
  the device there and latency can reach about 100 ms. Use **Hubungkan lewat IP…** (connect by IP) in the Mac menu
  with the address shown in the Android app, for example `10.100.3.145:47800`.

## Automatic reconnection

Cursoe reconnects:
- after the connection drops, including when the Mac wakes from sleep;
- immediately when the network path changes;
- after the Android app is updated or the device restarts (Android restarts the accessibility service, which starts
  the network service again if Cursoe was on).
