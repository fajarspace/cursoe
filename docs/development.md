# Development

Everything builds from the command line. Xcode and Android Studio are not required.

## Toolchain

| | |
|---|---|
| Mac | Xcode Command Line Tools (Swift 6.x) |
| Android | JDK 21, Android SDK platform 37 and build-tools 37, `adb` |

```bash
xcode-select --install
brew install openjdk@21
brew install --cask android-commandlinetools android-platform-tools
yes | sdkmanager --licenses
sdkmanager "platforms;android-37.0" "build-tools;37.0.0"
```

The scripts in this repository find the Homebrew JDK and Android SDK on their own (see `scripts/common.sh`), so you
do not need to change your shell profile. Gradle reads the SDK location from `android/local.properties`
(`sdk.dir=…`), which is not committed.

## Build and run

Connect the Android device over USB with USB debugging on, then from the repository root:

| Command | What it does |
|---|---|
| `./dev.sh` | Debug build of both apps. Installs the APK and runs the Mac app from `mac/build/`. |
| `./dev.sh mac` / `./dev.sh android` | One app only. |
| `./prod.sh` | Release build of both apps. Installs the Mac app to `/Applications`. |
| `./prod.sh mac` / `./prod.sh android` | One app only. |
| `./release.sh` | Builds `Cursoe-<version>.dmg` and `Cursoe-<version>.apk` into `dist/release/`. |

Switching between dev and prod builds does not require uninstalling: both are signed with the same keys, so pairing,
permissions and settings are kept.

### Mac app

```bash
cd mac
./make-dev-cert.sh   # once (recommended); asks for your macOS password
./build-app.sh       # swift build → build/Cursoe.app, signed
./install.sh         # build, install to /Applications and launch
```

macOS ties the Accessibility permission to the app's code signature. An ad-hoc signature (`codesign -s -`) changes
on every build, so the permission is lost each time. `make-dev-cert.sh` creates a local "cursoe-dev" signing
certificate in your keychain; `build-app.sh` uses it automatically when it exists, and the permission survives
rebuilds.

### Android app

```bash
cd android
./gradlew assembleDebug
adb install -r app/build/outputs/apk/debug/app-debug.apk

# Optional: lets Cursoe enable its own accessibility service without opening Settings
adb shell pm grant dev.cursoe android.permission.WRITE_SECURE_SETTINGS
```

Release builds are currently signed with the debug keystore (`~/.android/debug.keystore`). Keep that file: Android
only installs an update over an existing app when both are signed with the same key.

## Identifiers

| | |
|---|---|
| Android package | `dev.cursoe` |
| Mac bundle ID | `dev.cursoe.mac` |
| Bonjour service | `_cursoe._tcp`, port 47800 |
| Crypto labels | `cursoe/v1/*` |
| Log tags | `Cursoe`, `CursoeDbg` (Android); subsystem `dev.cursoe.mac` (Mac) |

## Logs and debugging

```bash
# Mac
log stream --info --predicate 'subsystem == "dev.cursoe.mac"'
tail -f ~/Library/Logs/Cursoe/cursoe.log          # when "Log debug" is on in the menu

# Android
adb logcat -s Cursoe CursoeDbg
```

Debug builds of the Android app include measurement tools:

```bash
adb shell am broadcast -a dev.cursoe.debug.LOG --ez on true      # verbose logging
adb shell am start -n dev.cursoe/.debug.TouchProbeActivity       # measure touch smoothness
adb shell am broadcast -a dev.cursoe.debug.SCROLL --ei jitter 40 # synthetic scroll
adb shell am broadcast -a dev.cursoe.debug.PINCH                 # synthetic pinch
adb shell am broadcast -a dev.cursoe.debug.EDGE                  # leave through the screen edge
adb logcat -s GBProbe                                            # probe results: gaps, speed, zoom scale
```

The probe only receives touches while the device is unlocked.

## Releasing

1. Set the same version in `mac/build-app.sh` (`VERSION`) and `android/app/build.gradle.kts` (`versionName`).
2. Run `./release.sh`. It builds the DMG (with the Cursoe disk icon, via `mac/make-dmg.sh`) and the APK into
   `dist/release/`.
3. Publish the files as a GitHub release:

   ```bash
   gh release create v1.0.0 dist/release/Cursoe-1.0.0.dmg dist/release/Cursoe-1.0.0.apk
   ```

Limitations of the current releases:
- **The Mac app is not notarized.** macOS blocks it on first launch until the user clicks *Open Anyway* in
  *System Settings › Privacy & Security*. Notarization requires a paid Apple Developer Program membership.
- **APKs installed from a browser are affected by "restricted settings" on Android 13+.** The accessibility switch
  stays disabled until the user opens *App info › ⋮ › Allow restricted settings*.

## Website

The project website is maintained in a separate repository. When it is checked out at `web/` (ignored by this
repository), `release.sh` also copies the release files to `web/public/downloads/` and writes their sizes and
SHA-256 hashes to `web/src/release.json`; the logo generator and the demo video tools below also write into it.

## Brand assets

The logo is defined once in `scripts/brand/make-logo.py`, which writes the Android launcher and notification icons,
the Mac geometry and, when `web/` exists, the website's logo component, favicon and SVGs. Regenerate everything with:

```bash
python3 scripts/brand/make-logo.py && swift mac/make-icon.swift
```

`mac/make-icon.swift` writes `mac/Resources/AppIcon.icns` (app icon) and `mac/Resources/DiskIcon.icns` (DMG icon).

## Demo videos

The website's demo videos are generated by the tools in `scripts/demo-video/` (they write into `web/`):

- `render.sh`: the animated "How it works" clips (`DemoVideo.swift`).
- `record-real.sh`: the hero video, a real screen recording of a Mac and an Android tablet. `DemoDriver.swift` moves
  the Mac cursor through a scripted story, both screens are recorded, and `ComposeReal.swift` composes them with
  automatic zoom. It needs a connected device and Accessibility and Screen Recording permission for the terminal.
  Raw recordings are stored in `scripts/demo-video/real/` and are never committed, because they contain real screen
  content. The composer masks the Google account picture in Chrome.
