# Troubleshooting

## Common problems

| Symptom | What to do |
|---|---|
| The Mac menu shows "⚠︎ Beri izin Aksesibilitas…" (grant Accessibility) | Enable Cursoe in *System Settings › Privacy & Security › Accessibility*. After rebuilding without a stable signing certificate, remove and re-add it, or run `tccutil reset Accessibility dev.cursoe.mac`. Running `mac/make-dev-cert.sh` once avoids this. |
| The Mac keeps showing "Mencari HP…" (searching) | Make sure both devices are on the same network, and that Local Network access is allowed on the Mac and the local network permission on Android. Try the device's hotspot, or **Hubungkan lewat IP…** (connect by IP). |
| ⌘⌥T only beeps | Read the *Mode:* line in the Mac menu. Usually the Android accessibility service is off, or macOS Secure Input is active (the cursor is in a password field). |
| The accessibility service is on but "not working" | Android marks a service as crashed after the app crashes. Tap **Perbaiki** (fix) in the Cursoe app, or turn the service off and on again in Settings. |
| Typing does nothing on Android | Enable **Cursoe Keyboard** in the keyboard list. The Mac menu shows a reminder while it is off. |
| A gallery photo is rejected when dragged to the Mac | Allow *Photos and videos › Allow all* for Cursoe, or use *Share › Kirim ke Mac*. |
| The Mac does not see the USB-tethered device | Check the mode in the Cursoe settings screen. macOS needs NCM, not RNDIS; see [Connection](connection.md#usb-cable). |
| A banking app refuses to open | Turn off the Cursoe accessibility service in Android Settings while using it, and turn off USB debugging. See [Usage](usage.md#banking-and-security-apps). |
| Scrolling stutters | Use the USB cable or the device's hotspot. Turn on the debug log and check `adb logcat -s CursoeDbg`. |

## Known limitations

These cannot be avoided with the permissions available to regular apps.

- **No hover.** Accessibility gestures only simulate touch, so tooltips and hover effects in Android apps do not
  appear.
- **Banking and some security apps** refuse to run while a non-Play Store accessibility service is enabled, or
  reject injected input and overlays.
- **Some password fields** reject third-party keyboards.
- **Dead keys and input methods for composed text** (for example ⌥E then E for "é", or Japanese input) are not
  supported.
- **The Android clipboard can only be read while the Mac cursor is on Android.** Android does not allow apps to read
  the clipboard in the background.
- **Files dropped on Android cannot go straight into a specific app** (for example a WhatsApp chat). Android only
  delivers a drop to an app when the drag started in the app in the foreground. Cursoe saves the file and offers to
  open it in an app instead.
- **Dragging from Android to the Mac** works only from apps that support drag and drop and provide a photo or video
  URI (Gallery, Google Photos). For other apps, use *Share › Kirim ke Mac*.
- **Esc ×3** (the safety shortcut) also sends Back to Android for the first two presses.
- **Hiding the Mac cursor and pausing ⌘⇥** use private macOS APIs. If Apple removes them, only these features stop
  working.
- **Pairing** is safe from passive eavesdroppers, but an active attacker on the same network during pairing could in
  theory try to guess the PIN. Pair on a network you trust.
- **Every click takes a few milliseconds** for Android to inject, in addition to network latency.
