# Cursoe

**One cursor for your Mac and your Android phone or tablet.**

Push the cursor past the edge of your Mac screen and it continues on your Android device. You keep using your
Mac's trackpad and keyboard. There is no screen mirroring: your phone or tablet keeps showing its own screen and
runs its own apps.

![Cursoe: a Mac and an Android tablet sharing one cursor](docs/images/cursoe.jpg)

Cursoe is made of two small apps that talk to each other over your local network or a USB cable:

- **macOS**: a menu bar app (Swift/AppKit) that captures input when the cursor leaves the screen.
- **Android**: an app (Kotlin, no third-party libraries) that draws the cursor and turns your input into taps,
  gestures and keystrokes.

> **Status:** v1.0, experimental. Developed and tested on a MacBook Pro (Apple Silicon) with a Galaxy Z Fold6.
> The apps' user interface is currently in **Indonesian**.

## Features

- **Cross the screen edge in both directions.** The cursor appears at the matching height. <kbd>⌘</kbd><kbd>⌥</kbd><kbd>T</kbd> also switches.
- **Trackpad gestures.** Click, long press, drag, two-finger scroll with native fling, pinch to zoom, smart zoom,
  and a three-finger swipe for recent apps.
- **Mac keyboard on Android.** Type with your Mac keyboard through a bundled input method, including text navigation,
  selection and shortcuts (Esc = Back, ⌘H = Home, ⌘⇥ = Recents).
- **Clipboard sync.** Text and images, in both directions.
- **Drag and drop files.** Drag from Finder to the screen edge to send a file to Android, or drag a photo from the
  Android gallery to the Mac. Share sheets work too.
- **Area screenshots.** Press ⌘⇧S on the Mac to capture part of the Android screen. The result is saved on the
  device and copied to the clipboard.
- **USB cable, hotspot or Wi-Fi.** Over USB tethering the round trip is 3–9 ms.
- **Private by design.** Devices connect directly. There are no accounts or servers. Pairing uses a 6-digit PIN
  and all traffic is end-to-end encrypted (ECDH P-256 + AES-256-GCM).
- **Safe fallbacks.** The cursor always returns to the Mac on ⌘⌥T, Esc ×3, a lost connection, the Android screen
  turning off, or the Mac going to sleep.

## Requirements

| | |
|---|---|
| Mac | Apple Silicon, macOS 14 or later |
| Android | Android 8.0 or later, phone or tablet (Android 11+ recommended) |
| Connection | USB cable (USB tethering in NCM mode, or USB debugging), the phone's hotspot, or the same Wi-Fi network |

## Install

1. Download the latest `Cursoe-<version>.dmg` (Mac) and `Cursoe-<version>.apk` (Android) from
   [Releases](https://github.com/fajarspace/cursoe/releases).
2. **Mac:** open the DMG and drag Cursoe into Applications. The app is not notarized yet. If macOS blocks it,
   open *System Settings › Privacy & Security* and click **Open Anyway**.
3. **Android:** open the APK and allow your browser to install apps.

### First run

**On the Mac**
1. Grant **Accessibility** access when asked (*System Settings › Privacy & Security › Accessibility*).
2. Allow **Local Network** access so the Mac can find your device.

**On Android** (open the Cursoe app)
1. Allow the requested permissions: nearby devices on the local network, notifications, and photos.
2. Turn on the **Cursoe** accessibility service. If the switch is disabled (Android 13+, apps installed from a
   browser), open *App info › ⋮ › Allow restricted settings* first.
3. Enable **Cursoe Keyboard** in the keyboard list. It does not need to be your default keyboard.

**Pairing:** the Mac finds the device automatically and the device shows a 6-digit PIN. Type the PIN on the Mac.
Later connections reconnect automatically.

See [docs/usage.md](docs/usage.md) for the full list of gestures, shortcuts and settings.

## Build from source

You need the Xcode Command Line Tools (Xcode itself is not required), JDK 21 and the Android SDK.

```bash
brew install openjdk@21
brew install --cask android-commandlinetools android-platform-tools
yes | sdkmanager --licenses
sdkmanager "platforms;android-37.0" "build-tools;37.0.0"
```

With the Android device connected over USB (USB debugging on):

```bash
./dev.sh            # build and install both apps (debug)
./dev.sh mac        # Mac only, runs from mac/build/
./dev.sh android    # Android only
```

`./prod.sh` builds release versions and installs the Mac app to `/Applications`. `./release.sh` builds the DMG and
APK for a GitHub release. See [docs/development.md](docs/development.md) for signing, debugging tools and the release
process.

## Repository layout

```
mac/                 macOS menu bar app (Swift Package Manager)
  Sources/cursoe/    app source
  Resources/         app and disk image icons
  build-app.sh       build and sign Cursoe.app
  make-dmg.sh        package the app into a DMG
android/             Android app (Kotlin, Gradle)
  app/src/main/      app source
  app/src/debug/     debug-only measurement tools
scripts/
  common.sh          shared helpers (JDK, Android SDK, adb)
  brand/             logo generator (single source for all icons)
  demo-video/        tools that record and compose the demo videos
docs/                documentation
dev.sh               build and run debug versions of both apps
prod.sh              build and install release versions
release.sh           build the DMG and APK for a GitHub release
```

## Documentation

- [Usage](docs/usage.md): moving the cursor, gestures, keyboard, clipboard, files and settings
- [Connection](docs/connection.md): USB tethering, USB debugging, hotspot and Wi-Fi
- [Architecture](docs/architecture.md): components, protocol and security model
- [Development](docs/development.md): building, signing, debugging and releasing
- [Troubleshooting](docs/troubleshooting.md): known limitations and common problems

## Contributing

Issues and pull requests are welcome. Please read [CONTRIBUTING.md](CONTRIBUTING.md) first, and report security
issues privately as described in [SECURITY.md](SECURITY.md).

## License

[MIT](LICENSE)
