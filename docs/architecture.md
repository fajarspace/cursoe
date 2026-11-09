# Architecture

Cursoe has two apps. The Mac app captures input and sends it; the Android app receives it and acts on it. They speak
a small, encrypted, length-prefixed protocol over TCP.

```
Mac (menu bar app)                                   Android
┌───────────────────────────┐   TCP :47800   ┌──────────────────────────────┐
│ InputCapture (event tap)  │ ─────────────▶ │ BridgeService (server, NSD)   │
│ RemoteController          │   encrypted    │   ├─ CursorService            │
│ BridgeClient + UsbLink    │ ◀───────────── │   │   (AccessibilityService)  │
│ ClipboardSync, FileTransfer│               │   └─ CursoeKeyboardService    │
└───────────────────────────┘                │       (input method)          │
                                             └──────────────────────────────┘
```

## Mac

A menu bar app (Swift, AppKit, Swift Package Manager, no Xcode project).

- `InputCapture`: a global `CGEventTap` for mouse, scroll, trackpad gestures and keyboard. Requires Accessibility
  permission.
- `RemoteController`: local/remote mode, screen-edge crossing, speed, and the safety rules (⌘⌥T, Esc ×3, sleep,
  disconnect).
- `BridgeClient`: Bonjour discovery (`NWBrowser`), TCP (`NWConnection`, `noDelay`), handshake, keep-alive and
  reconnection. `UsbLink` finds a USB-tethered device or falls back to `adb forward`.
- `SecureChannel`: encryption with CryptoKit. `Keychain`: stores pairing tokens.
- `ClipboardSync`, `FileTransfer`, `DropZone` (the blurred drop zone at the screen edge), `ReceivedPanel`.
- `CursorControl`: hides and releases the Mac cursor and temporarily disables system hotkeys while the cursor is on
  Android.

## Android

One app (Kotlin, no third-party libraries).

- **`BridgeService`** (foreground service, type `connectedDevice`): TCP server on port 47800, NSD advertisement,
  UDP probe responder for USB tethering, pairing PIN notification, clipboard and file transfer, keeping the screen
  awake while connected.
- **`CursorService`** (`AccessibilityService`):
  - draws the cursor as a `TYPE_ACCESSIBILITY_OVERLAY` window that does not receive touches;
  - `GestureController` turns input into gestures with `dispatchGesture`: tap, drag, scroll, pinch, using chained
    stroke segments;
  - Back, Home and Recents;
  - switches to Cursoe Keyboard automatically while the cursor is on the device;
  - the drop strip for dragging files to the Mac, and area screenshots.
- **`CursoeKeyboardService`** (input method): types text from the Mac keyboard with `commitText` and `sendKeyEvent`.
- `MainActivity`, the Quick Settings tile `CursoeTileService`, `ShareToMacActivity` and `ClipImageProvider`.

`CursoeSwitch` turns Cursoe on and off. Turning it off stops the network service only; the accessibility service
stays enabled. With `WRITE_SECURE_SETTINGS` (granted manually over adb), the app can also enable its own
accessibility service without opening Settings.

## Protocol

**Framing:** `[length: uint32 big-endian][payload]`. After the handshake, every payload is AES-256-GCM encrypted. It
contains either JSON (`{"t": "TYPE", …}`) or a binary file chunk `[0x01][16-byte UUID][data]`.

**Handshake and authentication**
1. `HELLO` (plaintext) carries a nonce and an *ephemeral* ECDH P-256 public key.
2. Session keys = HKDF-SHA256(ECDH secret, nonces, hash of both `HELLO`s), one key per direction. Nonces are
   counters, so replayed messages are rejected.
3. First pairing: `PAIR_REQUEST` → the device shows a PIN → `PAIR {pin}` → `PAIR_OK {32-byte token}`. The token is
   stored in the Keychain on the Mac and in app-private storage on Android.
4. Later connections: `AUTH` / `AUTH_OK` = HMAC(token, transcript). The token is never sent again.

**Messages**

| Group | Messages |
|---|---|
| Status | `SCREEN_INFO {w,h,density,rotation,cursor,ime}`, `PING` / `PONG` (every 1–2 s) |
| Mode | `ENTER {yRatio, from, macEdge}`, `EXIT`, `LEAVE {yRatio}` |
| Input | `MOVE {dx,dy,ts}`, `BUTTON {button,down}`, `SCROLL {dx,dy,ts,end}`, `PINCH {mag,ts,end}`, `SMART_ZOOM`, `KEY {key,mods}`, `TEXT {text}` |
| Clipboard | `CLIPBOARD {text}`, `CLIP_IMAGE_BEGIN` / `DATA` / `END` |
| Files | `FILE_BEGIN {id,name,size,mime,index,count,share}` → binary chunks → `FILE_END {sha256}` → `FILE_RESULT` |
| Port forwarding | `FORWARD {ports}`, `TUNNEL_OPEN {id,port}` → binary data `[0x02][UInt32 id][data]` both ways → `TUNNEL_EOF {id}` (half-close) / `TUNNEL_CLOSE {id}` (abort) |

**Why JSON?** Movement and scroll events are coalesced to at most about 120 messages per second, a few KB/s. JSON
parsing takes microseconds, far below network latency, and is easy to debug. Only file contents are binary.

**Smooth gestures on Android**
- Stroke segments are chained: the next segment is scheduled behind the one in progress.
- Segment durations come from the Mac's timestamps, with a 24 ms jitter buffer and at most about 48 ms queued.
- Coordinates are rounded to whole pixels; otherwise the system rejects stroke continuations.
- Near the screen edge, the virtual finger is lifted with `ACTION_CANCEL` and placed again, so no stray fling occurs.

## Port forwarding

`PortForwarder` (Mac) and `net/PortForwarder` (Android) tunnel TCP connections from `localhost:PORT` on Android to
`localhost:PORT` on the Mac through the encrypted session.

- The Mac sends `FORWARD {ports}` after authentication and whenever the list changes. Android opens a server socket on
  `127.0.0.1` and `::1` for each port, and closes them when the session ends.
- Each accepted connection becomes a stream: `TUNNEL_OPEN {id, port}`, data frames in both directions, and
  `TUNNEL_EOF` when one side finishes sending, so TCP half-close behaves as on a direct connection. `TUNNEL_CLOSE`
  aborts a stream.
- The Mac connects to `localhost` (not `127.0.0.1`), so servers that listen only on IPv6 `::1`, such as recent
  Node.js and Vite versions, are reachable.
- Flow control: each side sends the next 32 KB chunk only after the previous one was handed to the network (Mac) or
  while the session queue is short (Android), so cursor messages are not stuck behind large downloads.
- The Mac refuses ports that the user did not add.

## Security model

- Traffic stays on the local network or USB link. There are no accounts, servers or analytics.
- Pairing is protected against passive eavesdroppers. An *active* attacker on the same network, during pairing, could
  in theory try to guess the PIN. Pair on a network you trust.
- The accessibility service only draws the cursor and performs the gestures and keys you send. It does not read
  screen content. Screenshots are taken only when you press ⌘⇧S and are saved on the device.
- The Mac app uses two private macOS APIs (`SetsCursorInBackground`, `CGSSetSymbolicHotKeyEnabled`), as Synergy and
  AltTab do, to hide the cursor and pause ⌘⇥. If Apple removes them, only those features stop working.
