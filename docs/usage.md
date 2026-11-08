# Usage

The apps' interface is currently in Indonesian. Menu labels below are shown as they appear in the app, with an
English description.

## Moving the cursor

- **Mac → Android:** push the cursor past the edge of the Mac screen on the side where the device sits. Set the side
  in the Mac menu under **Posisi HP** (device position: right or left). You can also press **⌘⌥T**.
- **Android → Mac:** push the cursor past the edge of the Android screen that faces the Mac, or press **⌘⌥T**.
- **Safety:** the cursor always returns to the Mac when any of these happen:
  - you press ⌘⌥T, or Esc three times quickly;
  - the connection drops (after about 3.5 seconds);
  - the Android screen turns off;
  - the Mac sleeps or locks.
- **While the cursor is on Android:**
  - ⌘⇥ and Mission Control gestures on the Mac are paused;
  - Cursoe Keyboard is switched on automatically;
  - the Android screen stays awake.

## Trackpad and mouse

| On the Mac | On Android |
|---|---|
| Click | Tap |
| Click and hold | Long press |
| Click, hold and move | Drag (move icons, select text, sliders) |
| Right click | Long press |
| Two-finger scroll | Scroll with fling on release (follows the Mac's natural scrolling setting) |
| Pinch | Pinch to zoom around the cursor |
| Two-finger double tap | Double tap (smart zoom) |
| Three-finger swipe up/down | Recent apps; repeat to go back. Uses four fingers if "three finger drag" is on, like Mission Control |
| Mouse "back" button | Back |

## Keyboard

| On the Mac | On Android |
|---|---|
| Letters, numbers, symbols, ⇧/⌥ | Text, following the Mac keyboard layout |
| ⌫ / ⌥⌫ / ⌘⌫ | Delete character / word / to start of line |
| ↩ | Single-line fields: the field's action (Search, Send, Next). Multi-line fields: new line, except in WhatsApp where ↩ sends |
| ⇧↩ | New line (also in WhatsApp) |
| Arrows, with ⇧, ⌥ or ⌘ | Move the text cursor, select, by word, to line or document start/end |
| ⌘A ⌘C ⌘X ⌘V ⌘Z ⌘⇧Z | Select all, copy, cut, paste, undo, redo |
| Esc / ⌘H / ⌘⇥ | Back / Home / Recent apps |
| ⌘⇧S | Area screenshot: the screen freezes, drag to select (Enter = full screen, Esc = cancel). Saved to *Pictures/Screenshots* and copied to the clipboard, ready for ⌘V on the Mac. Android 11+; Android 9–10 captures the full screen |

## Clipboard

- **Mac → Android:** whatever you copy on the Mac (text or images) is available on Android right away.
- **Android → Mac:** copies made **while the Mac cursor is on Android** are sent to the Mac. The Android clipboard is
  also checked once more when the cursor returns to the Mac: copy on Android, move to the Mac, then ⌘V.
- **Not sent:** content marked as sensitive (for example by password managers) and files copied in Finder.

## Sending files and photos

**Mac → Android**
- Drag a file from Finder to the screen edge on the device's side. A blurred drop zone appears; drop the file there.
- Alternatives: the **Kirim file…** (send file) menu item, or Finder › *Open With › Cursoe*.
- Files are saved to **Download/Cursoe** on Android (photos and videos also appear in the gallery). The cursor moves to
  Android and a panel offers **Simpan** (save), apps that can open the file, or **Lainnya…** (more, the share sheet).
  **×** discards the file; tapping outside the panel or Back keeps it.

**Android → Mac**
- Long-press a photo in the gallery and drag it to the Android screen edge that faces the Mac until the blurred edge
  shows **Mac**, then release.
- Files are saved to **~/Downloads** on the Mac, and a panel near the cursor offers **Simpan** (save), Mac apps that
  can open the file, or **Finder**. **×** moves the file to the Trash; clicking outside, Esc or Return keeps it.
- From any app: **Share › Kirim ke Mac** (send to Mac).

## Settings

**Mac menu** (cursor icon in the menu bar)

| Item | What it does |
|---|---|
| Kendalikan HP (⌥⌘T) | Move the cursor to or from Android |
| Kecepatan | Cursor speed on Android, 0.25×–3× |
| Sinkron clipboard | Turn clipboard sync on or off |
| Kirim file… | Choose a file to send to Android |
| Posisi HP › Kanan / Kiri | Which side of the Mac the device is on |
| Koneksi › | Connection: Otomatis (automatic) / Kabel USB (USB cable) / Wi-Fi / hotspot, reconnect, connect by IP, cable status |
| Pengaturan › | Open at login, debug log, forget all pairings, version |

**Android app**
- The large power button turns Cursoe on or off. Turning it off only disconnects the Mac; the accessibility service
  stays enabled, so turning it back on is one tap.
- A **Cursoe** tile for Quick Settings does the same from the notification shade.
- Reminders appear when the accessibility service or Cursoe Keyboard is not enabled.
- ☰ **Pengaturan** (settings): keep the screen on while connected, permission status, USB connection status,
  paired Macs, debug log.

All settings are saved.

## Banking and security apps

Some banking apps refuse to run while an accessibility service from outside the Play Store is enabled. Turning
Cursoe off does not disable its accessibility service, so for those apps:

1. Open *Settings › Accessibility › Cursoe* and turn the service off.
2. Use the banking app.
3. Tap **Aktifkan** (enable) in the Cursoe app when you are done.

Some banking apps also refuse to run while USB debugging is on. Use USB tethering or a wireless connection instead.
