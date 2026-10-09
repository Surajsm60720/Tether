# Tether

Version 3.1.

Tether lets an iPhone browse, preview, download, and upload files on a Mac, send files into a Mac Inbox (with a floating Shelf for drag-out), run a terminal against those folders, and drive allowlisted coding agents (Claude Code, Cursor Agent, Codex, and related CLIs) over a live pseudo-terminal — without a cloud account or a password. The Mac app is the host. The iPhone app is the client. Pairing is a one-time QR code (or a short typed code). After that, the phone keeps a key in the Keychain and can open the Mac again.

On the same Wi-Fi, the Mac advertises itself and the phone finds it. Away from that network, the phone can still connect if you save a reachable address (a public hostname, a forwarded port, or a Tailscale address) or if both devices dial out to a small relay you run. File contents and terminal commands stay encrypted with the pairing key. A relay only forwards bytes.

There is no account, no third-party networking library, and no third-party crypto. Shared code lives in the `TetherCore` Swift package. The apps are SwiftUI.

## What you can do

- Share only the folders you pick. The rest of the Mac is not a filesystem the phone can walk.
- Browse those folders on the iPhone in a list or a grid, sort them, search by name across every shared folder, and open a file in QuickLook (photos, video, audio, PDF, and the other types QuickLook supports).
- Download files to the phone and upload files into a folder that you have marked writable.
- Send photos and files from the iPhone **Send** tab (or the Share sheet) into the Mac **Inbox**. On the Mac, open the floating **Shelf** to drag received files into Finder, Mail, Slack, and other apps, or manage them from the Inbox page.
- Watch transfer progress, retry, and cancel.
- Use a terminal on the phone for everyday file commands (`ls`, `cd`, `cat`, `find`, and the rest listed below). Those commands stay inside the shared folders.
- Type an allowlisted agent name (`claude`, `agent`, `codex`, `cursor`, and the rest) to open a live terminal session on the Mac. The phone is the screen and keyboard. The agent keeps running if you leave the app; reconnect resumes it. Live Activities and the Dynamic Island show transfer progress and live agent status (Thinking, Working, Editing, Needs you) while you use other apps.
- Ask the Mac who you are, print a short system summary, and open a live monitor for CPU, memory, swap, disk, network, battery, temperature, and the busiest processes.
- Approve or revoke each iPhone from the Mac. A revoked phone cannot open a new session.
- Reach the Mac from another network with a saved address or a relay, after you have paired once on Wi-Fi.

## Requirements

- Xcode 16 or later
- macOS 14 or later for the host
- iOS 17 or later for the client
- Swift 6
- A physical iPhone for real pairing. The simulator can build the client.
- For a device install, an Apple ID in Xcode signing. A paid developer account is not required for a personal install.

Bundle identifiers:

| App | Identifier |
|---|---|
| Mac host | `app.tether.host` |
| iPhone client | `app.tether.client` |
| Share extension | `app.tether.client.share` |
| Widgets | `app.tether.client.widgets` |

The client and Share extension use the App Group `group.app.tether.client` so shared items can hand off into Tether.

## Open the project

Open `Tether.xcodeproj`. The local package `Packages/TetherCore` is already part of the project. Do not add Swift packages from the network. Tether has no third-party dependencies.

## Run the Mac app

1. Select the **TetherHost** scheme and **My Mac**.
2. Press Run.
3. Tether appears in the Dock and in the menu bar. The Dock icon follows the accent you pick in Settings and switches between light and dark with the Mac’s appearance.
4. Open the main window from the menu bar if it is not already open.
5. On first launch, add at least one folder. Nothing is shared until you choose it.
6. If macOS asks for Local Network access, allow it. The host uses that permission to see the iPhone on Wi-Fi. You can confirm the advertisement with `dns-sd -B _tether._tcp`.

The menu bar menu shows whether sharing is on, which phones are connected, and shortcuts to pair, open the window, and quit. The main window is a day-to-day control center — first-glance pages only; tuning lives in Settings:

| Page | What it is for |
|---|---|
| Status | Sharing switch, network line, and connected phones (Disconnect) |
| Shared folders | Add, remove, and choose whether each folder accepts uploads |
| Inbox | Files sent from the iPhone; Open, Reveal, Move, Clear list |
| iPhones | Nearby phones — Look again, Pair, Connect |
| Settings | Opens the full Settings window (same as ⌘, or the menu bar **Settings…**) |

Settings includes **General** (Mac name, launch at login, approval, prevent sleep, Inbox folder, Shelf / sound on receive), **Appearance** (theme presets, text size/weight, Dock icon), **Devices** (paired phones + Revoke), **Other networks**, **Activity**, and **What's new**.

Folders start read-only. Turn on **Allow uploads** for a folder before the phone can add files there. Uploads are still limited to that folder. Paths that try to escape it are rejected.

The reserved **Inbox** share is always writable for paired phones. By default it uses `Documents/Tether Received` (change it in Settings → General). When a file arrives, the Shelf can open automatically so you can drag it into another app.

**Pair new iPhone** opens a window with a QR code and a 16-character code grouped as `XXXX-XXXX-XXXX-XXXX`. Both expire after 120 seconds and work once. The Mac must approve the phone before pairing finishes. If you turn on **Require approval**, later sessions also wait for Allow on the Mac. Revoke a phone from Settings → Devices. Revoke deletes that phone’s key. The phone has to pair again.

## Run the iPhone app

The iPhone target must be signed with your Apple ID. A simulator build is already configured. A physical iPhone is not, until you set a team.

1. Connect the iPhone with a cable, or choose it as a wireless device.
2. Select the **TetherClient** scheme and your iPhone.
3. Open the target’s **Signing & Capabilities** tab. Set **Team** to your Apple ID. Leave the bundle id as `app.tether.client` unless Xcode says it is already taken.
4. Press Run. If iOS asks you to trust the developer certificate, do that in Settings → General → VPN & Device Management.
5. Keep the Mac and iPhone on the same Wi-Fi for the first pair. A phone hotspot works when a guest network blocks device-to-device traffic. The Mac must be on that same hotspot.
6. On the iPhone, tap **Continue** so Tether can look for the Mac, then tap **Allow** on the system Local Network prompt.
7. Tap **Pair**, scan the QR code, or type the 16-character code. On the Mac, tap **Allow**.
8. The phone opens the shared folders. Files, Send, Terminal, and Transfers are the four tabs.

iPhone Settings has the device name (what the Mac shows for this phone), **Appearance** (same theme presets and GUI text size/weight as the Mac), the home-screen icon (Gold, Blue, Green, or Neutral; light, dark, and tinted follow the system), a cache size and clear button, terminal font size from 11 to 20 points (separate from GUI type), prevent Mac sleep while active (synced when connected), **Other networks** for the remote setup code, and **What's new** for this version.

## Everyday use on the iPhone

Tap a paired Mac to connect. If it is on the same Wi-Fi, the row says **Available**. If you have saved a remote code and the Mac is not on this network, the row says **Saved for other networks**.

The file browser starts at `/`, which is the list of shared folders, not the Mac’s real disk root. Open a folder, tap a file to preview it, or select several files and download them. Large downloads ask before they start. Search filters the current folder by name. Sort by name, date, size, or kind. Switch between list and grid. Pull to refresh discovery from the Mac list.

Downloads land in the app’s local files. The **Send** tab always targets the Mac Inbox (photos or Files). You can also share into Tether from other apps (“Send to Mac”); if Tether is not connected yet, open it and connect to finish. Folder-browser uploads still use the system file picker and only succeed in a folder whose Mac-side switch allows uploads. The Transfers tab shows active and finished transfers, progress, and failures. Keep Tether in the foreground during a transfer. iOS can suspend the app, and a suspended app does not continue the copy. While a transfer or agent is active, a Live Activity can show progress or status on the Lock Screen and Dynamic Island; tap it to jump back into Tether. When an agent asks for approval or input, the Island expands with a **Needs you** alert.

The Terminal tab is a prompt of the form `mac-name:/Share/dir $`. History is the up and down keys. Tab completes commands and names in the current folder; a scrollable list above the prompt shows every match (tap to insert). Type `help` for a catalog with each command’s syntax and flags. Output wraps to the width of the monospaced font so a long line is not cut off at the edge of the screen. `exit` returns to Files. `clear` wipes the scrollback.

## Terminal commands

These commands are implemented in Tether and only see shared folders. `~` is `/`. Quotes and backslash escapes work. `..` cannot climb out of a share.

| Command | What it does |
|---|---|
| `help` | List commands |
| `pwd` | Print the working folder |
| `cd <dir>` | Change folder. `cd` or `cd /` returns to the share list |
| `ls [-l] [-a] [path]` | List a folder. `-l` adds size, date, and kind. `-a` shows hidden names |
| `cat <file>` | Print a text file, up to 1 MB |
| `head -n N <file>` | First lines |
| `tail -n N <file>` | Last lines |
| `stat <path>` | Details for a file or folder |
| `du [-h] [path]` | Size summary |
| `find <name> [path]` | Case-insensitive name search |
| `tree [-L N] [path]` | Folder tree |
| `mkdir [-p] <dir>` | Create a folder in a writable share |
| `rm [-r] <path>` | Remove a file or folder in a writable share |
| `rmdir <dir>` | Remove an empty folder in a writable share |
| `cp <from> <to>` | Copy inside a writable share |
| `mv <from> <to>` | Move or rename inside a writable share |
| `touch <file>` | Create an empty file in a writable share |
| `echo <text>` | Print text |
| `grep <text> <file>` | Search a text file |
| `wc <file>` | Line, word, and byte counts |
| `date` | Current time |
| `whoami` | Mac account, Mac name, and this iPhone, for example `suraj@Studio Mac (via Suraj's iPhone)` |
| `status` | Host, user, phone, folder, OS, uptime, load, memory, and share count |
| `fetch` | A short Mac portrait: model, OS, CPU, cores, memory, uptime, load, disk, and shares. `neofetch` and `fastfetch` are the same command |
| `htop` | Open the live monitor. `btop` and `monitor` are the same command |
| `open <file>` | Download and preview on the iPhone. `preview` is the same command |
| `get <file>` | Download to the phone |
| `put` | Open the file picker and upload into the current folder when that folder is writable |
| `clear` | Clear the screen |
| `exit` | Leave the terminal |

Unknown commands and shell operators (`|`, `>`, `;`, and the rest) are rejected for a general Mac shell. The built-in commands above stay inside the folders you shared.

Typing an allowlisted coding-agent name opens a live PTY on the Mac instead (see **Live coding agents** below). Tab completes commands and names in the current folder.

`whoami`, `status`, `fetch`, and `htop` do not shell out. They use system calls on the Mac and the existing encrypted session.

## Live coding agents

From the Terminal tab, run a program name from the allowlist (for example `claude`, `agent`, `codex`, `cursor`, `aider`, `gemini`). Tether:

1. Opens a pseudo-terminal on the Mac with your login shell PATH and credentials.
2. Starts the agent in the current share folder, or in your home directory when the working folder is `/`.
3. Streams output to the phone and sends keystrokes back.
4. Keeps the process alive if you switch away, open Files or Transfers, or the connection drops; the phone can resume the same session.

While the live agent is on the Terminal tab, the root tab bar is hidden so the PTY and accessory key row use the full bottom edge. The header folder control switches to Files without ending the session; Terminal shows a **Live** badge until you close with X. Opening the software keyboard does not resize the remote rows and columns (that was clipping permission menus). The agent key row includes `S-Tab`, `Y`, and `N`. Control-tap an http or https link (OSC 8 or plain text) to open it in Safari; a plain tap focuses the keyboard again. A keyboard show/hide key is on every terminal accessory row.

Shell operators are not allowed on this path, so a live session cannot be turned into an arbitrary script. Closing the session from the phone (the Terminal X control) ends the process. Only pair a phone you trust: an agent runs as your Mac user.

## The monitor

`htop`, `btop`, or `monitor` opens a full-screen view. It refreshes about every second and a half. It shows:

- Who you are, the Mac model, the OS, and the CPU name
- Uptime and the 1, 5, and 15 minute load averages
- Task count and thread count
- Battery charge, whether it is charging, maximum capacity, condition (Good, Fair, or Service), and cycle count against the design count, on a Mac that has a battery
- Maximum capacity matches System Settings. It is the battery’s present full charge in milliamp-hours divided by the design capacity, not the separate “max capacity” field that stays at 100
- Thermal state (Nominal, Fair, Serious, or Critical) and temperature sensors the Mac exposes: the hottest chip sensors, plus the battery temperature when that sensor exists. Bars run from 20°C to 90°C
- CPU split into user, system, nice, and idle, and a bar for each core
- Memory split into wired, active, compressed, cached, and free, plus swap
- Disk used and total for the startup volume
- Network down and up, and bytes received and sent since boot
- The busiest processes, with PID, name, thread count, CPU, and memory

There is no kill or renice. The process list needs the Mac app’s process-info entitlement. Quit and relaunch Tether Host after a rebuild so that entitlement is in the signed app. An already running copy will still report no processes.

## Other networks

Step-by-step setup for Tailscale, relay, and port forward (including cellular → home Mac) lives in [docs/help/remote-access.md](docs/help/remote-access.md). Use that file for FAQ or website help later.

A home address such as `192.168.x.x` only works on that Wi-Fi. The internet cannot route to it. Tether has two ways to connect when Bonjour does not see the Mac.

1. **A reachable address.** The Mac listens on port **52173** while **Allow connections from other networks** is on. Settings → Other networks lists this Mac’s addresses. A Tailscale address (`100.x`) is preferred when one exists, then a public address, then a VPN address, then the Wi-Fi address. You can type a hostname instead, for example the name you forwarded on your router. The phone tries that address when the Mac is not on the local network. Private Wi-Fi addresses are only tried briefly, then Tether falls through to the relay if you set one.
2. **A relay.** Run `tether-relay` on a computer that has a public port. The Mac and the iPhone both connect outward to it, so the home router does not need a port forward. The default relay port is **52174**.

```bash
cd Packages/TetherCore
swift run tether-relay 52174
```

Leave that process running. On the Mac, open **Settings → Other networks**, turn the switch on, enter the relay address (for example `example.com:52174`), and save. Copy the setup code. On the iPhone, open Settings → **Other networks**, paste the code, and save. Pair on Wi-Fi once before that. The code is tied to the Mac you already paired. It carries the Mac id, the address, the relay, and a rendezvous token. The token is not the file-encryption key. Someone who has only the token still cannot pass the pairing handshake.

Connection order on the phone:

1. If the Mac is visible on the local network, use that. Cellular is not used for this path.
2. Otherwise try the saved address.
3. Otherwise open the saved relay.

Same-Wi-Fi use does not go through the relay.

## Security

Tether’s threat model is another device on the network, or a stranger who can open a TCP connection to the Mac, trying to read files or impersonate a paired phone.

- Pairing creates a one-time 32-byte secret. The QR code carries all of it. The typed code carries the first 10 bytes. The Mac shows an approval dialog before it stores a phone.
- On approval the Mac creates a fresh 32-byte device key, stores it in the Keychain, and sends it to the phone over the encrypted channel. The one-time secret is discarded. Later sessions use the device key.
- The session is ChaChaPoly. Keys are derived with HKDF-SHA256. Handshakes are authenticated with HMAC-SHA256. There is no third-party crypto.
- Every path from the phone is parsed and checked against the shared folders before it touches disk. `..`, absolute host paths, and symlink escapes are rejected.
- Five failed handshakes in a minute from one remote, or five failed pairing attempts, lock pairing for five minutes.
- Revoke removes the device key. The next session from that phone fails.
- Logs use `os.Logger` and mark paths and names private. Tether does not log keys, pairing secrets, or file contents.
- Remote listening is off until you turn it on. The port is still protected by the pairing handshake. Only a phone you have paired can list or read files.
- The relay learns that two peers want to meet, and it sees the handshake headers. After the handshake, file and terminal bytes are ciphertext. The relay does not have the device key.
- The Mac app is sandboxed. The file browser stays inside folders you choose. Allowlisted coding agents run as your Mac user (home and tool paths) via PTY sandbox exceptions. Process listing for the monitor uses `process-info`. The phone does not get a general Mac shell.
- Inbound connections are capped and must finish the handshake within a short deadline. Failed handshakes and pairing codes are rate-limited.

A compromised Mac or a compromised iPhone is outside this design. So is a full interactive shell. That would be a different mode, off by default, and it is not in this build.

## How it works

```
Tether/
├── TetherHost/          macOS app: menu bar, window, sharing, approval
├── TetherClient/        iOS app: browser, terminal, transfers, settings
├── Packages/TetherCore/ shared package, no SwiftUI, UIKit, or AppKit
│   ├── Protocol/        messages, frames, error codes
│   ├── Transport/       TCP connection and the encrypted session
│   ├── Security/        pairing, ChaChaPoly channel, Keychain helpers
│   ├── Discovery/       Bonjour advertise and browse
│   ├── Remote/          addresses, setup codes, relay
│   ├── FileSystem/      virtual paths, sanitizer, disk and memory providers
│   └── Terminal/        command parser, virtual commands, system stats
└── docs/                PRD.md, DESIGN.md, and help/ (remote access FAQ)
```

`TetherCore` is the only place for networking, crypto, the wire protocol, path checks, and terminal logic. The apps are UI and platform glue. View state uses `@Observable`. Views do not own the protocol.

Discovery uses Bonjour service `_tether._tcp` for the Mac and `_tether-phone._tcp` for the phone, over Network.framework. The TXT record carries protocol version `1`, a short host id, a role, and the display name. It does not carry file names, paths, or user names. The phone’s local-network browse does not use cellular. A saved remote address or relay does.

One TCP connection stays up for a session. Requests and responses carry a `requestId`. File reads and writes are chunked at 768 KB, with up to 8 chunks in flight, and each frame is capped at 1 MB. A ping runs on the session. If the connection drops, the phone retries with backoff.

The virtual root `/` is the list of shares. A phone path is never used as a host path until the sanitizer accepts it.

## Tests

```bash
swift test --package-path Packages/TetherCore
```

The tests cover pairing, the encrypted channel, framing, path escapes, the virtual filesystem, Bonjour names, terminal commands, system-stat formatting, battery maximum-capacity math, the relay, and a direct TCP session. They do not replace trying a real iPhone against the Mac.

## Changelog

The same notes are in Settings → What's new on both the Mac and the iPhone.

### 3.1

Appearance presets and type controls on Mac and iPhone.

- Gold, Blue, Green, Neutral, and Midnight themes retint accent (and lightly tint terminal chrome).
- GUI text size and weight in Settings → Appearance; iPhone terminal font size stays its own slider.
- Mac menu bar uses the Dock brand mark; the popover is status, sharing, connected phones, Shelf, Open Tether, Pair, Settings, Quit.

### 3.0

Phone → Mac Send with Inbox and Shelf.

- Send files from the iPhone Send tab, or from the Share sheet (“Send to Mac”).
- Mac Inbox page lists received files; Open, Reveal, Move, or Delete.
- Floating Shelf for drag-out into Finder, Mail, Slack, and other apps.
- Configurable Inbox folder; reserved Inbox share is always writable for paired phones.

### 2.6

Session isolation and Island privacy after 2.5.

- Switching Macs clears terminal slots from the previous host.
- Agent resume data no longer stores the full launch line.
- Dynamic Island agent details are fixed status words only (no PTY snippets).
- Concurrent agent opens cannot exceed the three-session cap.

### 2.5

Security hardening for live agents and shared folders.

- Agents launch only as bare allowlisted names; path-shaped tokens like `./claude` are rejected.
- The Mac re-checks the allowlist and runs a sanitized command line.
- `mkdir` no longer follows outbound symlinks out of a share.
- Each live terminal is bound to the iPhone that opened it.

### 2.4

Multiple terminal slots inside the Terminal tab.

- Up to three reorderable slots: virtual shell, live coding agent, Monitor, or a pinned fetch snapshot.
- Switch tabs without losing progress; inactive slots keep running in the background.
- `htop` / `btop` and `fetch` open as slots instead of covering the whole app.
- More than one coding agent can run at once (still capped at three terminals); the Island follows the focused or most urgent agent.

### 2.3

Live Activities and Dynamic Island for transfers and coding agents.

- File transfers: percent, speed, ETA, and batch count on the Island and Lock Screen; tap to open Transfers.
- Live agents: per-tool mark plus a status chip (Thinking / Working / Running / Editing / Needs you / Waiting) inferred from the terminal session — never by showing transcript on the Island.
- When an agent asks for permission, plan approval, or other input, the Island expands with a Needs you alert so you can jump back to Terminal.
- Updates are opportunistic while iOS keeps the app awake; after that the Island freezes on the last state until you reopen Tether.

### 2.2

Stay awake during remote sessions, keep agents usable over hotspot and other networks, and type less in the everyday terminal.

- Prevent sleep while active (Mac and iPhone Settings): the Mac stays awake while a phone is connected or an agent is still running.
- Reconnect after a network switch no longer detaches a live agent when the old socket closes.
- Keystrokes over remote links are sent without waiting for each ACK.
- Path changes are probed sooner; the terminal keyboard returns when the agent resumes.
- Terminal suggestions: scrollable dropdown for commands and path segments (listed fresh from the Mac folder you are completing); Tab still unique-fills or opens the same list. `help` opens a tappable catalog with typed syntax (flags and placeholders).
- Files search: type in the search field to find files and folders across all shares; tap a result to preview or open that folder.

### 2.1

Live-agent UX polish on top of 2.0.

- Switch to Files or Transfers without ending a live agent; Terminal shows a Live badge until you close with X.
- Tab bar hides while the agent fills Terminal so the PTY and key row use the full bottom edge.
- Software keyboard no longer shrinks the remote PTY (permission menus stay on screen).
- Keyboard show/hide key; live agents also get `S-Tab`, `Y`, and `N`.
- Control-tap http/https links (OSC 8 or plain text) open in the phone browser.

### 2.0

Live coding agents and terminal polish on top of the 1.x security line.

- Allowlisted agents (`claude`, `agent`, `codex`, `cursor`, and related CLIs) open a live PTY on the Mac.
- Phone acts as screen and keyboard; sessions survive app switch and reconnect.
- Batched PTY output and viewport-only drawing for long agent runs.
- Tab completion for everyday terminal commands and paths.

### 1.2

Continued security and reliability hardening on the 1.x line.

- Foreground probe reconnects half-dead sockets instead of hanging actions.
- Cancelled transfers free waiters immediately.
- Cache and downloads use Complete protection while the device is locked.
- Monitor process list is limited to your Mac user account (short names only).
- Huge folder listings use a scan cap; empty reads back off instead of spinning.

### 1.1

Security patch over 1.0.

- Phone terminal is virtual-only: no Mac `zsh` fall-through.
- Caps and timeouts on inbound handshakes; global lock after repeated handshake failures.
- Device keys Keychain-only (legacy on-disk mirrors cleared).
- Safer uploads (abort on disconnect, chunk bounds) and symlink write rejection.
- Paginated listings under the frame size limit; relay prelude timeouts.
- Narrower host sandbox (no whole-home temporary exception).

### 1.0

- Pair an iPhone with a Mac by QR code or a typed code, then reconnect without a password.
- Browse, preview, download, and upload files in the folders you choose to share.
- Follow transfers with progress, retry, and cancel.
- Use a terminal for everyday file commands inside those folders.
- See who you are with `whoami`, a short Mac summary with `fetch`, and a live monitor with `htop` or `btop`.
- The monitor shows CPU, memory, swap, disk, network, battery, temperature, and the busiest processes.
- Reach the Mac from another network with a saved address or a relay, after pairing once on Wi-Fi.
- Choose an icon color, set the terminal font size, and clear the preview cache.
- Approve or revoke each iPhone from the Mac.

## Limits

- Mac and iPhone only. There is no Windows, Android, or Linux app. The relay tool runs wherever the Swift package runs, which today means the Mac you build it on.
- The phone cannot see folders you did not share.
- Transfers stop if iOS suspends the app.
- `htop` is a Tether screen, not the `htop` or `btop` program. `fetch` is a Tether portrait, not the real neofetch binary.
- Only allowlisted coding-agent names get a live PTY. There is still no general interactive shell for arbitrary programs.
- A live agent runs as your Mac user (home and tool paths). The file browser remains limited to shares you chose.
- Temperature depends on sensors the Mac exposes to the app. If a sensor is missing, the monitor still shows the thermal state (Nominal, Fair, Serious, or Critical).
- A relay or an open port is reachable by anyone who can route to it. They still need a paired device key to read files. Do not publish the setup code.
