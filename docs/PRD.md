# Tether — Product Requirements Document (v0.1)

> **Working title:** "Tether". Rename with a project-wide find/replace (`Tether`, `tether`, `_tether._tcp`).
> **Companion file:** `DESIGN.md` (visual and interaction guidelines). Read both before writing code.
> **Audience:** this document is written to be given directly to an AI coding agent (Cursor). It is explicit on purpose. When something is ambiguous, follow the "Decisions" in each section; do not invent alternatives.

---

## 0. How to use this with Cursor

1. Create the repo and put `PRD.md` and `DESIGN.md` in `/docs`.
2. Add the rules file from **Appendix A** at `.cursor/rules/tether.mdc`.
3. Build in the order of **Section 18 (Milestones)**. Do not start M1 until M0's acceptance criteria pass.
4. Use the starter prompts in **Appendix B**, one milestone at a time.
5. Keep all protocol, crypto, and path-safety logic in the shared Swift package so it can be unit tested without UI.

---

## 1. Summary

Tether lets an iPhone browse, preview, download, and upload files on a Mac over the local Wi-Fi network, with no internet, no cloud, no IP addresses, and no credentials to type.

- **macOS app (Host):** a menu-bar app. The user picks which folders to share. It advertises itself on the local network and approves pairing requests.
- **iOS app (Client):** discovers Macs automatically, pairs once by scanning a QR code, then offers two interfaces to the same connection: a **GUI file browser** and a **virtual terminal** for power users.
- **Preview:** files open in the native iOS QuickLook viewer (images, video, audio, PDF, Office documents, and so on).

Windows and Android hosts are explicitly **out of scope** until the Swift pair works well (Section 3).

---

## 2. Problem and positioning

### 2.1 Problem
Moving a file from a Mac to an iPhone, or opening a file that lives on a Mac while holding the phone, is awkward:

- AirDrop is push-only. You cannot browse the Mac from the phone.
- iCloud Drive needs the cloud, storage quota, and sync delays, and only covers synced folders.
- macOS File Sharing (SMB) works with the iOS Files app, but needs the IP or hostname, credentials, and manual setup.
- SSH apps give a terminal and file transfer, but need Remote Login enabled, key or password setup, and offer weak previews.

### 2.2 Honest competitive note
This capability category already exists (SMB in the Files app, SFTP clients, SSH apps for iOS). Do not claim novelty. The differentiators are:

1. **Zero-config:** automatic discovery plus a one-time QR pairing.
2. **One app, two modes:** a clean GUI and a terminal in the same connection.
3. **Safe by design:** only folders the user explicitly shares are reachable. No shell on the Mac.
4. **Native preview:** QuickLook for everything QuickLook supports.
5. **Local only:** nothing leaves the local network.

### 2.3 One-line pitch
"Open your Mac's files from your iPhone in two taps. No setup, no cloud."

---

## 3. Goals and non-goals

### Goals
- G1. Discover a Mac on the same network and connect in under 5 seconds after pairing.
- G2. Pair a new iPhone in under 30 seconds by scanning a QR code.
- G3. Browse shared folders and preview a typical file (5 MB PDF or photo) in under 3 seconds on 5 GHz Wi-Fi.
- G4. Transfer large files at 30 MB/s or better on 5 GHz Wi-Fi.
- G5. Provide a terminal with common read-oriented commands that looks and feels real.
- G6. Be secure by default: encrypted, authenticated, user-approved, scoped to shared folders.
- G7. A shippable, demoable build within the meetup deadline (see Milestone M0).

### Non-goals (for v1)
- N1. No Windows, Android, or Linux host or client.
- N2. No general-purpose remote shell. Everyday commands are a virtual interpreter inside shared folders. A paired iPhone may open a live pseudo-terminal only for known coding agents (`claude`, `agent`, `codex`, and the rest of the list in Section 13.5).
- N3. No internet or remote (outside-LAN) access, relay servers, or accounts.
- N4. No browsing of the whole disk from the file browser, and no launching Mac GUI apps. The coding-agent session in Section 13.5 is the exception: that process runs as the Mac user.
- N5. No promised full background transfers while the iOS app is suspended (Section 14.4). Live Activities may show last-known or paused transfer state after background time expires; they do not keep chunk transfers running indefinitely.
- N6. No iPad-specific layout work beyond what SwiftUI gives for free.
- N7. No CloudKit or ActivityKit push-to-update. Local Live Activities (v2.3) update from the app process only; on-device Island QA needs a standard Apple Developer team (same as shipping the iOS app).

---

## 4. Users and scenarios

| Persona | Need | Primary mode |
|---|---|---|
| Casual user | Grab a PDF or photo from the Mac without cables or cloud | GUI |
| Developer | Check a log, `cat` a config, pull a build artifact from the Mac | Terminal |
| Presenter or student | Open slides or videos stored on the Mac from the phone | GUI |

Key scenarios:
- S1. First run: install the Mac app, choose a folder to share, scan the QR code on the iPhone, browse files.
- S2. Everyday: open the iOS app, tap the Mac, browse, tap a PDF to preview.
- S3. Upload: pick photos on the iPhone and send them to the Mac's "Received" folder.
- S4. Power user: run `ls`, `cd`, `cat`, `get`, `open` in the terminal tab.
- S5. Security: the user revokes a phone from the Mac app, and the phone can no longer connect.

---

## 5. Release scope

| Release | Contents |
|---|---|
| **M0 (Meetup slice)** | Discovery, QR pairing, encrypted channel, list folders, download file, QuickLook preview, basic Mac menu-bar app with share-folder selection and pairing approval |
| **M1** | Polished GUI (grid and list, breadcrumbs, thumbnails, sort), uploads, transfers sheet with progress |
| **M2** | Virtual terminal |
| **M3** | Settings, device management and revoke, error states, demo mode, polish |
| **Stretch** | Streaming video through `AVAssetResourceLoader`, iOS Share Extension ("Send to Mac"), Save to Photos, rename/delete/mkdir with confirmations |
| **Later** | Windows host, Android client (the wire protocol is documented so it is portable) |

---

## 6. Platforms and tech stack

- **Language:** Swift 6 (use strict concurrency; fall back to Swift 5 language mode only if a dependency forces it).
- **UI:** SwiftUI on both platforms. AppKit only where required (menu bar item, open panels, window management).
- **Minimum OS:** iOS 17, macOS 14 (for `@Observable`, SwiftData, modern SwiftUI).
- **Networking:** `Network.framework` (`NWListener`, `NWBrowser`, `NWConnection`) for discovery and transport.
- **Crypto:** `CryptoKit` (`ChaChaPoly`, `HKDF<SHA256>`, `SymmetricKey`, `HMAC<SHA256>`, `Curve25519` if needed). No third-party crypto.
- **Persistence:** SwiftData for non-secret metadata (paired devices, recents). **Keychain** for all keys and secrets.
- **Preview:** `QuickLook` / `QLPreviewController` (iOS), `QuickLookThumbnailing` (`QLThumbnailGenerator`) on the Mac for thumbnails.
- **QR:** `CoreImage` (`CIQRCodeGenerator`) on the Mac; `AVFoundation` metadata capture or `VisionKit DataScannerViewController` on iOS.
- **Dependencies:** none required. If one is added, it must be justified in a comment in `Package.swift`.
- **Project structure:** one Xcode workspace, a local Swift package for shared code, and two app targets.

---

## 7. Architecture

### 7.1 Repository layout

```
Tether/
├── docs/                        PRD.md, DESIGN.md
├── Packages/
│   └── TetherCore/              shared Swift package (no UI)
│       ├── Sources/TetherCore/
│       │   ├── Protocol/        message types, codec, error codes
│       │   ├── Transport/       framing, NWConnection wrapper, secure channel
│       │   ├── Security/        key derivation, pairing, Keychain helpers
│       │   ├── Discovery/       Bonjour advertise and browse wrappers
│       │   ├── FileSystem/      virtual root, path sanitizer, share registry
│       │   └── Terminal/        command parser and virtual commands
│       └── Tests/TetherCoreTests/
├── TetherHost/                  macOS app (menu bar)
└── TetherClient/                iOS app
```

### 7.2 Layering rules
- `TetherCore` has **no UIKit, AppKit, or SwiftUI imports**. It must compile and test on macOS from the command line (`swift test`).
- The Host app depends on `TetherCore` and implements a `FileProvider` that maps virtual paths to real URLs.
- The Client app depends on `TetherCore` and implements a `RemoteSession` that sends requests and exposes `async` methods (`list`, `read`, `write`, `exec`).
- UI state uses `@Observable` view models. No business logic in views.
- Every network operation is `async/await`, cancellable, and has a timeout.

### 7.3 Connection model
- One long-lived TCP connection per paired host, carrying multiplexed request/response messages identified by a `requestId`.
- File transfers use the same connection, chunked, with flow control via request/response (client pulls chunks with `read`, client pushes chunks with `write.chunk` and waits for the ack).
- Heartbeat: `ping` every 10 seconds; treat 25 seconds of silence as disconnected and auto-retry with backoff (1, 2, 4, 8 s, capped at 15 s).

---

## 8. Discovery

**Decision:** Bonjour service type `_tether._tcp` over `Network.framework`.

- **Host:** `NWListener` on an ephemeral TCP port, advertising `NWListener.Service(name: <hostName>, type: "_tether._tcp", txtRecord: ...)`.
- **TXT record keys:** `v` (protocol version, `1`), `id` (short host ID, 8 hex chars), `name` (display name). **No** file names, paths, user names, or device models.
- **Client:** `NWBrowser` for `_tether._tcp` in the `local` domain. Show results as a list of Macs, marking those already paired.
- **Interfaces:** allow Wi-Fi and wired Ethernet. Do not restrict to Wi-Fi only. Include peer-to-peer (`includePeerToPeer = true`) as an optimization attempt, but the app must work without it.
- **iOS requirements:** `NSLocalNetworkUsageDescription` and `NSBonjourServices = ["_tether._tcp"]` in Info.plist. The first browse triggers the system Local Network prompt; show a pre-prompt explanation screen before it (copy in `DESIGN.md`).

---

## 9. Pairing and security

### 9.1 Threat model
Protect against other devices on the same Wi-Fi (eavesdropping, spoofing, brute force, replay). Out of scope: a compromised Mac or iPhone.

### 9.2 Pairing flow (one-time)
1. On the Mac, the user clicks **Pair new iPhone**. The Host generates a **one-time pairing secret `P`** (32 random bytes), valid for **120 seconds**, single use.
2. The Host shows a **QR code** encoding `tether://pair?v=1&id=<hostId>&p=<base64url(P)>&n=<hostName>` and, as a fallback, a **manual code**: `P` encoded as 16 Crockford-Base32 characters grouped `XXXX-XXXX-XXXX-XXXX` (this is the first 10 bytes of `P`; for manual mode the Host derives the session secret from those 10 bytes only; document this clearly in code).
3. The iPhone scans the QR code (or the user types the code), connects to the Host (Bonjour first, then fallback by hostId match), and opens a secure channel using `P` as the shared secret (Section 9.3).
4. The iPhone sends `pair.request {deviceId, deviceName}`.
5. The Host shows an **Approve / Deny** dialog: "Allow *<deviceName>* to access your shared folders?" Pairing **always requires explicit approval on the Mac**.
6. On approval, the Host generates a fresh **long-term device key `K`** (32 random bytes), stores it in the Keychain keyed by `deviceId`, and sends `pair.complete {hostId, hostName, K}` over the encrypted channel. The iPhone stores `K` in its Keychain. `P` is discarded.
7. Failure modes: wrong or expired `P` closes the connection; more than **5 failed attempts in 60 seconds** locks pairing for 5 minutes.

### 9.3 Secure channel (used for pairing with `P` and for normal sessions with `K`)
All traffic after the first two plaintext hello frames is encrypted and authenticated.

1. Client sends `ClientHello {v, deviceId, nonceC (32 random bytes), mode: "pair"|"session"}` (plaintext).
2. Host replies `HostHello {v, hostId, nonceH (32 random bytes)}` (plaintext). In `session` mode the Host first checks that `deviceId` is paired; otherwise it closes the connection.
3. Both sides derive two keys with HKDF-SHA256:
   - `secret` = `P` (pair mode) or `K` (session mode)
   - `salt` = `nonceC || nonceH`
   - `keyC2H = HKDF(secret, salt, info: "tether/v1/c2h")`, `keyH2C = HKDF(secret, salt, info: "tether/v1/h2c")`
4. Every subsequent frame is sealed with `ChaChaPoly` using the direction's key and a **96-bit nonce built from a per-direction monotonically increasing 64-bit counter** (zero-padded). The receiver enforces the exact expected counter (reject out-of-order or replayed frames).
5. The client's first encrypted frame is `auth {}`. If the Host cannot decrypt it, it closes the connection immediately (this is the authentication step). The Host replies `auth.ok`.

### 9.4 Rules
- Never log keys, secrets, or file contents. Redact paths in release logs.
- Keychain items: `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, not synced.
- Rate limit failed handshakes per remote address (5 per minute).
- The user can **revoke** a device from the Mac at any time; revocation deletes `K` and drops any active connection for that device.
- The Host refuses connections from unpaired devices except in an active pairing window.
- A visible indicator in the Mac menu bar shows when a device is connected.

---

## 10. Wire protocol (v1)

### 10.1 Framing
Over the TCP stream, each message is a frame:

```
[ UInt32 big-endian: length of the sealed payload ][ sealed payload ]
```

Plaintext inside the sealed payload:

```
[ UInt8 kind ][ UInt32 big-endian headerLength ][ header: UTF-8 JSON ][ body: raw bytes (may be empty) ]
```

- `kind`: `0x01` request, `0x02` response, `0x03` event (host-initiated, for example, share list changed).
- Max sealed payload: **1 MiB**. File chunks are **256 KiB** by default.
- Every request has a `requestId` (UInt64). Responses echo it. Responses carry either `ok: true` or an `error` object.

### 10.2 Virtual filesystem
- Paths are POSIX-style and start with `/`.
- `/` lists the **shares** (the folders the user chose, by display name).
- `/<ShareName>/sub/dir/file.ext` maps to the real folder behind that share.
- The Host **must**: canonicalize paths, reject `..` segments, resolve symlinks and reject any result outside the share root, and never expose absolute real paths to the client.

### 10.3 Requests

| Op | Request header fields | Response |
|---|---|---|
| `ping` | none | `{ok}` |
| `shares` | none | `{shares:[{name, writable}]}` |
| `list` | `path` | `{entries:[{name, kind:"file"\|"dir"\|"link", size, mtime, uti?}]}` |
| `stat` | `path` | `{entry}` |
| `thumb` | `path`, `maxPixel` | body = JPEG bytes (cap 256 KB), header `{ok}` |
| `read` | `path`, `offset`, `length` | body = bytes; header `{ok, eof, totalSize}` |
| `write.begin` | `path`, `size`, `overwrite` | `{uploadId}` |
| `write.chunk` | `uploadId`, `offset` (body = bytes) | `{ok, received}` |
| `write.commit` | `uploadId` | `{ok}` (host writes to a temp file and moves into place atomically) |
| `write.abort` | `uploadId` | `{ok}` |
| `mkdir` | `path` | `{ok}` (Stretch) |
| `rename` | `from`, `to` | `{ok}` (Stretch) |
| `delete` | `path` | `{ok}` (Stretch; off by default, requires per-share toggle) |
| `term.exec` | `cwd`, `line` | `{stdout, stderr, cwd, exit, action?}` |
| `term.open` | `cwd`, `line`, `columns`, `rows` | `{session}` for a live coding-agent terminal |
| `term.input` | `session` (body = raw bytes) | `{ok}` |
| `term.resize` | `session`, `columns`, `rows` | `{ok}` |
| `term.close` | `session` | `{ok}` |
| `term.data` | event: `session` (body = raw bytes) | host → phone |
| `term.exit` | event: `session`, `exit` | host → phone |

### 10.4 Error codes
`unauthorized`, `notFound`, `denied`, `outsideShare`, `readOnly`, `tooLarge`, `badRequest`, `busy`, `internal`. Responses: `{ok:false, error:{code, message}}`. Messages are user-readable and never contain real absolute paths.

### 10.5 Limits
- Max concurrent requests per connection: 8.
- Directory listing cap: 5,000 entries per call; provide `offset`/`limit` paging fields in `list` (default limit 1,000).
- `term.exec` output cap: 256 KB; commands time out after 15 seconds.
- `cat` refuses files over 1 MB and binary files.

---

## 11. macOS Host app requirements

### 11.1 Shape
Menu bar app (`LSUIElement = true`, no Dock icon by default). Built with SwiftUI `MenuBarExtra` (window style) plus separate windows for pairing and settings. App Sandbox **on**.

### 11.2 Entitlements and sandbox
- `com.apple.security.app-sandbox`
- `com.apple.security.network.server` (listening) and `com.apple.security.network.client`
- `com.apple.security.files.user-selected.read-write` for shared folders, persisted with **security-scoped bookmarks** (re-resolve on launch; show an alert when a bookmark goes stale)
- Info.plist `NSBonjourServices = ["_tether._tcp"]`

### 11.3 Features
- **Menu bar popover:** status (listening, device connected), connected devices, shares list, buttons for *Pair new iPhone*, *Settings*, *Quit*.
- **Share management:** add folder (open panel), remove, per-share *Read only / Allow uploads* toggle (default read-only; uploads allowed only where enabled), optional custom display name.
- **Pairing window:** QR code, manual code, countdown (120 s), live status. Closes automatically on success.
- **Approval dialog:** modal alert on pairing request; also shown for first connection from a device if *Require approval on every new session* is enabled in Settings (default off).
- **Activity log:** last 100 events (connect, list, read, write, denied) with timestamps. Filenames shown in the log are stored in memory only and cleared on quit.
- **Settings:** Mac display name, launch at login (`SMAppService.mainApp`), paired devices list with *Revoke*, *Require approval each session*, *Stop sharing* master switch.
- **Thumbnails:** `QLThumbnailGenerator` with an in-memory LRU cache (100 items).
- **Power:** when *Prevent sleep while active* is on (default), hold a `ProcessInfo.beginActivity` assertion while an iPhone is connected or a coding agent is still running so the Mac does not sleep mid-session.

### 11.4 Acceptance criteria (Host)
- Starts listening on launch if at least one share exists; advertises via Bonjour (verify with `dns-sd -B _tether._tcp`).
- Rejects any path escaping a share (unit tested with `..`, symlink, and encoded-path cases).
- Revoked device cannot reconnect and an active connection is dropped within 2 seconds.
- Quitting the app stops advertising immediately.

---

## 12. iOS Client app requirements

### 12.1 Shape
SwiftUI app, portrait-first, supports landscape and iPad via adaptive layout. Root is a **host list**; after connecting, a `TabView` with **Files**, **Terminal**, **Transfers**.

### 12.2 Screens
1. **Welcome / permission primer:** explains Local Network access before the system prompt (copy in `DESIGN.md`).
2. **Hosts:** discovered Macs (live), paired Macs (with connection state), *Pair new Mac* button. Swipe to forget a Mac.
3. **Pair:** camera QR scanner plus *Enter code instead*. States: scanning, connecting, waiting for approval on Mac, success, failed.
4. **Files:** navigation stack of folders. List and grid toggle, breadcrumb title menu (jump to any ancestor), sort (name, date, size, kind), pull to refresh, global filename search across shares (live walk, same caps as terminal `find`), thumbnails in grid mode, context menu (Download, Preview, Share, Get Info).
5. **Preview:** download to a cache, then present `QLPreviewController`. Show progress for larger files with a cancel button. Provide a Share button (system share sheet) and *Save to Files*.
6. **Upload:** `PhotosPicker` and `fileImporter`. Destination is the current folder if writable, otherwise a prompt to choose a writable share.
7. **Transfers:** active and recent transfers, progress rings, speed and ETA, retry on failure, clear completed.
8. **Terminal:** see Section 13.
9. **Settings:** device name, cache size and *Clear cache*, forget all Macs, about, demo mode toggle.

### 12.3 Behavior
- Reconnect automatically when returning to the foreground.
- Cache downloaded files in `Caches/` keyed by host, path, size, and mtime; evict by LRU past a configurable limit (default 1 GB).
- Saved files go to the app's `Documents/Tether Downloads/`, which is exposed in the Files app (`UIFileSharingEnabled`, `LSSupportsOpeningDocumentsInPlace`).
- All UI strings in a `Localizable.xcstrings` catalog (English only for v1).

### 12.4 Background and lifecycle
Transfers run while the app is active. On backgrounding, request extra time with `UIApplication.beginBackgroundTask` and pause or fail gracefully if it expires; show "Keep Tether open while transferring" in the Transfers tab. Do not promise background transfers.

### 12.4.1 Live Activities (v2.3)
While a transfer is active or a live coding agent is running, the iOS client may start ActivityKit Live Activities (Dynamic Island + Lock Screen) via the `TetherWidgets` extension.

- **Transfers:** primary file name, direction, percent, bytes, speed, ETA; batch count as `+N` when multiple. Tap opens Transfers (`tether://transfers`).
- **Agents:** program display name; live status chip (`Thinking` / `Working` / `Running` / `Editing` / `Needs you` / `Waiting` / …) from bottom-up keyword scrape of the PTY screen tail + OSC title + idle time (transcript itself is never shown). When the agent asks for permission, plan approval, or other input, update with an ActivityKit alert so the Dynamic Island expands (or Lock Screen banners) and the chip reads **Needs you**. Coarse phase drives glyph animation only. Tap opens Terminal (`tether://terminal`).
- **Updates:** opportunistic while the app is active or still in a background task. After expiry, freeze or show paused copy until the user returns. No push updates.
- **Motion:** per-agent SF Symbol brand marks and system content transitions / symbol pulses — not GIF or video.
- **Priority:** when both run, agent uses higher `relevanceScore` so it owns the compact Island; transfer may appear minimal.

### 12.5 Permissions (Info.plist)
`NSLocalNetworkUsageDescription`, `NSBonjourServices`, `NSCameraUsageDescription` (QR scan), `NSPhotoLibraryAddUsageDescription` (Save to Photos, Stretch), `NSPhotoLibraryUsageDescription` only if needed by the picker flow.

### 12.6 Acceptance criteria (Client)
- Pairs with a Mac by QR in under 30 seconds on a clean install.
- Lists a 1,000-file folder in under 500 ms on local Wi-Fi.
- Previews a PDF, a JPEG, an MP4 (downloaded), and a DOCX via QuickLook.
- Survives Wi-Fi drop and reconnect without crashing; shows a clear offline state.

---

## 13. Virtual terminal

### 13.1 Principle
The terminal looks like a shell but is a **command interpreter implemented in `TetherCore`**, executed by the Host inside the virtual filesystem. It never spawns `/bin/sh` and never touches paths outside shares.

### 13.2 Client UI behavior
- Prompt: `mac-name:/Share/dir $` with the path in the directory color (see `DESIGN.md`).
- Scrollback of 2,000 lines, text selection and copy, command history (up/down via on-screen keys and hardware keyboard), Tab completion for paths and commands, live suggestion dropdown for the same matches (tap to insert), `Ctrl-C` cancels a running command, `Ctrl-L` clears.
- Suggestions list the folder named by the path head on demand from the Host (short phone-side TTL cache); there is no background full-tree index. New files and folders appear on the next suggestion fetch for that directory.
- `help` opens a scrollable tappable catalog that shows each command’s typed syntax (flags and placeholders) and inserts a starter line (for example `get ` or `cd `). The scrollback gets a short tip instead of dumping the full list again. Path and command suggestions use the same scrollable menu height.
- Accessory key row above the software keyboard: keyboard show/hide, `Tab`, `Esc`, `Ctrl`, `↑`, `↓`, `/`, `~`, `-`, `|`. Hiding the keyboard returns that space to the transcript. Esc dismisses the suggestion or help menu first.
- Output of `open` and `preview` presents the QuickLook sheet over the terminal.
- **Terminal slots (v2.4):** up to three reorderable slots inside the Terminal tab. Each slot is a virtual shell, a live coding agent, the system Monitor (`htop` / `btop`), or a pinned `fetch` snapshot. Only one slot is interactive at a time; inactive slots keep their state. `htop` / `btop` and `fetch` / `neofetch` open or focus their slot (they do not use a full-screen cover that hides other slots). Soft cap three; refuse with a clear message when full.

### 13.3 Commands (v1)

| Command | Behavior |
|---|---|
| `help` | List commands (also opens a tappable catalog on the phone) |
| `pwd`, `cd <dir>`, `cd ..`, `cd /` | Navigation (`~` maps to `/`) |
| `ls [-l] [-a] [path]` | List; `-l` shows size, date, kind; `-a` shows dotfiles (hidden by default) |
| `cat <file>` | Print text files up to 1 MB |
| `head -n N <file>`, `tail -n N <file>` | First and last lines (cap N at 1,000) |
| `stat <path>` | Details |
| `du [-h] [path]` | Size summary (limit recursion depth and time) |
| `find <name-pattern> [path]` | Case-insensitive name search under path (cap 500 results) |
| `tree [-L N] [path]` | Tree view (default depth 2) |
| `open <file>` / `preview <file>` | Triggers a client action to download and show in QuickLook |
| `get <file>` | Download to the iOS app's Downloads folder |
| `put` | Presents the iOS file picker; uploads to the current directory (if writable) |
| `clear` | Clears the screen (client side) |
| `exit` | Returns to the Files tab |

Stretch: `mkdir`, `cp`, `mv`, `rm` (only on shares with a "Allow changes" toggle), pipes with a small allowlist (`ls | grep x`).

Unknown commands print: `tether: command not found: <cmd>. Type 'help'.`

### 13.4 Parsing
Implement a small tokenizer (quotes, escaped spaces) and command registry. Each command is a type conforming to `TerminalCommand` with `run(context) async throws -> TerminalResult`. All commands are unit tested against an in-memory fake filesystem.

### 13.5 Live coding agents
Typing `claude`, `cursor`, `agent`, `codex`, or another name in `AgentPrograms` opens that program on the Mac and uses the iPhone as its screen and keyboard.

- The host allocates a pseudo-terminal, starts the user's login shell so PATH and credentials match Terminal.app, then `exec`s the command. At `/` the directory is the user's home; inside a share it is that folder.
- The phone parses the byte stream (cursor movement, color, alternate screen) and sends keystrokes back. Output is `term.data`. Process exit is `term.exit`.
- Control, then a tap on an http or https link (OSC 8 or plain text), opens that address in the phone's browser. A tap without Control focuses the keyboard.
- Opening the software keyboard must not change the remote rows/columns. Claude Code, Codex, and Cursor CLI draw permission menus at the bottom of the screen; a shrink-on-keyboard resize was wiping them until the next keystroke. The phone keeps the last full PTY size while the keyboard is up. The agent key row includes `S-Tab`, `Y`, and `N` for those prompts.
- `term.exec` does not launch these programs. They need the live screen.
- Shell syntax (`|`, `;`, `` ` ``, `$`) stays on the one-shot path so a live session cannot be turned into a script.
- Closing the session from the phone (the Terminal close control) sends SIGHUP. Switching to Files or Transfers (header folder control, or the tab bar once you leave Terminal), switching to another terminal slot, or switching apps, does not: the process keeps running on the Mac. While a live agent slot is focused on the Terminal tab the root tab bar is hidden; it returns when you leave Terminal or focus a non-agent slot, with a Live badge on Terminal while any agent is still running, and the phone rejoins that agent’s screen when you return to its slot.
- Up to three concurrent live agents per connection (aligned with the slot cap). Session IDs on `term.*` demux bytes to the matching slot. The Dynamic Island still shows one agent chip: the focused agent, or else the agent with highest urgency (`Needs you` first).
- Live agents launch only as bare allowlisted names (no `./claude` or absolute paths). The Host re-validates and runs a sanitized `exec` line. Each session is owned by the pairing `deviceId` that opened it; other paired phones cannot input, resume, resize, or close it (v2.5).
- Connecting to a different Mac clears Terminal slots from the previous host. Resume persistence stores session id and program name only. Live Activity agent details use fixed status words — never scraped PTY snippets (v2.6).
- Terminal bytes are never logged.

---

## 14. File operations and preview rules

### 14.1 Downloads
Client calls `read` in 256 KiB chunks sequentially (pipelining depth 4 allowed). Verify total bytes against `totalSize`. Write to a temp file, then atomically move to the destination. Resume is out of scope for v1, but design `read` offsets so it is possible later.

### 14.2 Uploads
`write.begin` → repeated `write.chunk` (client waits for ack, pipelining depth 4) → `write.commit`. The Host writes to a hidden temp file in the destination folder and renames on commit. Conflicts: default to appending ` (2)`, `(3)` unless `overwrite: true`.

### 14.3 Video
v1: download then QuickLook. Stretch: `AVAssetResourceLoaderDelegate` serving byte ranges through `read`, so large videos start immediately and remain encrypted.

### 14.4 Limits
Uploads and downloads of files over 4 GB are allowed in the protocol (64-bit offsets) but are not a v1 test target.

---

## 15. Data model

Non-secret metadata uses SwiftData; secrets use the Keychain.

**iOS (Client):**
- `PairedHost`: `hostId: String` (unique), `name: String`, `pairedAt: Date`, `lastConnectedAt: Date?`, `lastKnownPort: Int?`
- `RecentItem`: `hostId`, `path`, `openedAt`
- Keychain: `K` per `hostId`; a stable client `deviceId` (UUID, generated once, stored in Keychain).

**macOS (Host):**
- `Share`: `id: UUID`, `displayName`, `bookmarkData: Data`, `writable: Bool`, `allowChanges: Bool`
- `PairedDevice`: `deviceId: String` (unique), `name`, `pairedAt`, `lastSeenAt`
- Keychain: `K` per `deviceId`; a stable `hostId` (8 hex chars from a UUID, generated once).

---

## 16. Non-functional requirements

- **Performance:** idle CPU under 1% on the Host; steady-state transfer at or above 30 MB/s on 5 GHz Wi-Fi; UI never blocks on network (all calls async).
- **Reliability:** every request has a timeout (10 s for metadata, 30 s idle for transfers). No crashes on malformed frames (fuzz test the codec).
- **Privacy:** no analytics, no network calls except the local connection. No third-party SDKs.
- **Accessibility:** see `DESIGN.md` (Dynamic Type, VoiceOver, contrast, reduced motion).
- **Logging:** `os.Logger` with categories (`discovery`, `pairing`, `transport`, `fs`, `terminal`). Paths and names logged with `privacy: .private`.
- **Code quality:** SwiftLint optional; zero compiler warnings; public types in `TetherCore` documented.

---

## 17. Testing and demo plan

### 17.1 Automated (in `TetherCoreTests`)
- Path sanitizer: `..`, absolute paths, symlink escapes, unicode normalization, trailing slashes, empty segments.
- Crypto: HKDF vectors, counter enforcement, replay rejection, wrong-key rejection.
- Codec: round trips, truncated frames, oversize frames, malformed JSON (must not crash).
- Terminal: each command against a fake filesystem, including quoting and error cases.
- Integration: Host and Client in one process over the loopback interface; pair, list, read, write, revoke.

### 17.2 Manual checklist
- Fresh install on both devices; pair by QR and by manual code.
- Deny pairing; expired code; 6 wrong codes then lockout.
- Wi-Fi off and on during a transfer.
- Mac sleep and wake while connected.
- Large file (2 GB) download and upload.
- Local Network permission denied on iOS: the app shows a clear recovery screen with a Settings button.

### 17.3 Meetup demo hardening
- **Demo mode** (Settings toggle on iOS): an in-app fake host serving sample files, so the demo can proceed if venue Wi-Fi blocks device-to-device traffic. The UI is identical; add a small "Demo" badge.
- Bring a phone hotspot as a network fallback; test the Mac and iPhone both on it beforehand.
- Prepare a demo folder: a PDF, a photo, a short MP4, a DOCX, and a text log.
- Script: open the Mac menu bar → pair via QR → browse → preview a PDF → run `ls`, `cat`, `open` in the terminal → upload a photo → show the Mac's activity log.

---

## 18. Milestones

Time estimates assume focused work. M0 is sized for the meetup.

### M0 — Meetup slice (days 1–4)
- Workspace, `TetherCore` package, both app targets building.
- Bonjour advertise and browse.
- Secure channel (Section 9.3) with unit tests.
- QR pairing with Mac approval dialog; Keychain storage on both sides.
- Mac: menu bar, add share folders, pairing window.
- iOS: hosts list, QR scan, folder browsing (basic list), tap a file to download then QuickLook.
- **Acceptance:** live demo path S1 + S2 works end to end; path sanitizer and crypto tests pass.

### M1 — GUI polish and transfers (days 5–7)
- Grid and list, breadcrumbs, thumbnails, sort, filter.
- Uploads (photos and files), Transfers tab with progress, cancel, retry.
- Cache management.

### M2 — Terminal (days 8–10)
- Parser, command registry, all v1 commands, history, Tab completion, accessory key row, QuickLook integration for `open`.

### M3 — Hardening (days 11–14)
- Settings, device revoke, error and offline states, reconnect logic, demo mode, accessibility pass, app icon, README with screenshots.

### Stretch
Streaming video, Share Extension, rename/delete/mkdir, Save to Photos.

---

## 19. Risks and mitigations

| Risk | Mitigation |
|---|---|
| Venue Wi-Fi blocks peer-to-peer traffic (client isolation) | Phone hotspot fallback; demo mode |
| Local Network permission confusion on iOS | Pre-prompt primer screen; recovery screen with deep link to Settings |
| Sandbox blocks access after relaunch | Security-scoped bookmarks; stale bookmark detection |
| Crypto mistakes | Use only CryptoKit primitives as specified; unit tests with vectors; no custom ciphers |
| Scope creep (terminal, streaming) | Milestone gates; Stretch list is explicitly not committed |
| Free developer account limits (7-day signing, device limit) | Re-sign before the meetup; do not rely on any capability that needs the paid program |
| Large directory performance | Paging in `list`; lazy thumbnails; virtualized lists (`LazyVStack`/`List`) |

---

## 20. Open questions (decide during build, default in bold)

1. App name: **Tether** (placeholder).
2. Show hidden files by default: **No.**
3. Terminal allowed to run on shares marked read-only: **Yes** (read commands only).
4. Mac "Received" folder: **user chooses a writable share; none by default.**
5. Open source license if published: **MIT.**

---

## Appendix A — `.cursor/rules/tether.mdc`

```
---
description: Tether project rules
alwaysApply: true
---
- Read /docs/PRD.md and /docs/DESIGN.md before large changes. They are the source of truth.
- Language: Swift 6, SwiftUI, async/await. Minimum iOS 17 / macOS 14. No third-party dependencies unless asked.
- All networking, crypto, protocol, filesystem-virtualization and terminal logic lives in Packages/TetherCore with no UI imports. Apps contain UI and platform glue only.
- Use CryptoKit only (ChaChaPoly, HKDF, HMAC). Never invent crypto. Never log secrets, keys, or file contents.
- Every path from a client must pass through the path sanitizer before touching disk. Never trust client input.
- Use @Observable view models; no business logic in Views. Keep Views small and previewable.
- Use SF Symbols and system components; follow DESIGN.md tokens (colors, spacing, typography). No hard-coded colors outside the Theme file.
- Write unit tests for every new piece of TetherCore logic. Run `swift test` before declaring a task done.
- Make small, reviewable changes. After each task, summarize what changed and what to test manually.
- If requirements conflict or are unclear, ask before guessing; do not silently expand scope. Stretch items are not committed.
```

## Appendix B — Starter prompts (one per step)

1. **Scaffold:** "Read docs/PRD.md and docs/DESIGN.md. Create the Xcode workspace with a local Swift package `TetherCore`, a macOS menu bar app `TetherHost` (sandboxed, LSUIElement) and an iOS app `TetherClient`, matching Section 7.1. Everything must build. Add a placeholder test in TetherCore. Do not implement features yet."
2. **Protocol and framing:** "Implement Section 10 in TetherCore: message types, framing codec, error codes, with unit tests including malformed and oversize frames."
3. **Secure channel:** "Implement Section 9.3 exactly: hello frames, HKDF key derivation, ChaChaPoly sealing with per-direction counters, replay rejection, and the `auth` frame. Add tests with wrong key, replay, and out-of-order frames."
4. **Virtual filesystem and sanitizer:** "Implement Section 10.2 and the path sanitizer with the tests listed in 17.1. Include a `FileProvider` protocol and an in-memory fake."
5. **Discovery and pairing:** "Implement Section 8 and 9.2. Host: NWListener + Bonjour + pairing window with QR and manual code. Client: NWBrowser + QR scanner. Include the Mac approval dialog and Keychain storage."
6. **Browse and preview (M0 finish):** "Implement `list` and `read` end to end, the iOS folder browser, and download-then-QuickLook. Verify with the M0 acceptance criteria."
7. **M1, M2, M3:** one prompt per milestone, quoting the milestone text from Section 18.

---

*End of PRD v0.1*
