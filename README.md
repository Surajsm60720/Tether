# Tether

Tether lets an iPhone browse, preview, download, and upload files on a Mac, and run a terminal against those folders, without a cloud account or a password. The Mac app is the host. The iPhone app is the client. Pairing is a one-time QR code (or a short typed code). After that, the phone keeps a key in the Keychain and can open the Mac again.

On the same Wi-Fi, the Mac advertises itself and the phone finds it. Away from that network, the phone can still connect if you save a reachable address (a public hostname, a forwarded port, or a Tailscale address) or if both devices dial out to a small relay you run. File contents and terminal commands stay encrypted with the pairing key. A relay only forwards bytes.

There is no account, no third-party networking library, and no third-party crypto. Shared code lives in the `TetherCore` Swift package. The apps are SwiftUI.

## What you can do

- Share only the folders you pick. The rest of the Mac is not a filesystem the phone can walk.
- Browse those folders on the iPhone in a list or a grid, sort them, search by name, and open a file in QuickLook (photos, video, audio, PDF, and the other types QuickLook supports).
- Download files to the phone and upload files into a folder that you have marked writable.
- Watch transfer progress, retry, and cancel.
- Use a terminal on the phone for everyday file commands (`ls`, `cd`, `cat`, `find`, and the rest listed below). Commands stay inside the shared folders.
- Ask the Mac who you are, print a short system summary, and open a live monitor for CPU, memory, swap, disk, network, battery, temperature, and the busiest processes.
- Approve or revoke each iPhone from the Mac. A revoked phone cannot open a new session.
- Reach the Mac from another network with a saved address or a relay, after you have paired once on Wi-Fi.

Tether does not run Claude Code, the Cursor CLI, or any other full-screen terminal program. Those need a real pseudo-terminal and a terminal emulator. The phone terminal is a command interpreter plus, for commands it does not implement, a short non-interactive `zsh -c` on the Mac.

## Requirements

- Xcode 16 or later
- macOS 14 or later for the host
- iOS 17 or later for the client
- Swift 6
- A physical iPhone for real pairing. The simulator can build, and Demo mode on the phone shows sample files without a Mac.
- For a device install, an Apple ID in Xcode signing. A paid developer account is not required for a personal install.

Bundle identifiers:

| App | Identifier |
|---|---|
| Mac host | `app.tether.host` |
| iPhone client | `app.tether.client` |

## Open the project

Open `Tether.xcodeproj`. The local package `Packages/TetherCore` is already part of the project. Do not add Swift packages from the network. Tether has no third-party dependencies.

## Run the Mac app

1. Select the **TetherHost** scheme and **My Mac**.
2. Press Run.
3. Tether appears in the Dock and in the menu bar. The Dock icon follows the accent you pick in Settings and switches between light and dark with the Mac’s appearance.
4. Open the main window from the menu bar if it is not already open.
5. On first launch, add at least one folder. Nothing is shared until you choose it.
6. If macOS asks for Local Network access, allow it. The host uses that permission to see the iPhone on Wi-Fi. You can confirm the advertisement with `dns-sd -B _tether._tcp`.

The menu bar menu shows whether sharing is on, which phones are connected, and shortcuts to pair, open the window, and quit. The main window has five pages:

| Page | What it is for |
|---|---|
| Status | Mac name, sharing switch, network line, connected phones, and a short list of shared folders |
| Shared folders | Add, rename, remove, and choose whether each folder accepts uploads |
| iPhones | Paired phones, including ones nearby, and revoke |
| Other networks | Listen for connections from outside this Wi-Fi, show addresses, set a relay, and copy the setup code |
| Activity | A short log of pairing and connection events. Filter and clear it here |

Settings (the macOS Settings window) repeats general options, folders, phones, other networks, and activity. General settings include the name shown on the iPhone, launch at login, require approval for each session, the sharing switch, and the icon color (Gold, Blue, Green, or Neutral).

Folders start read-only. Turn on **Allow uploads** for a folder before the phone can add files there. Uploads are still limited to that folder. Paths that try to escape it are rejected.

**Pair new iPhone** opens a window with a QR code and a 16-character code grouped as `XXXX-XXXX-XXXX-XXXX`. Both expire after 120 seconds and work once. The Mac must approve the phone before pairing finishes. If you turn on **Require approval**, later sessions also wait for Allow on the Mac. Revoke a phone from the iPhones page or from Settings. Revoke deletes that phone’s key. The phone has to pair again.

## Run the iPhone app

The iPhone target must be signed with your Apple ID. A simulator build is already configured. A physical iPhone is not, until you set a team.

1. Connect the iPhone with a cable, or choose it as a wireless device.
2. Select the **TetherClient** scheme and your iPhone.
3. Open the target’s **Signing & Capabilities** tab. Set **Team** to your Apple ID. Leave the bundle id as `app.tether.client` unless Xcode says it is already taken.
4. Press Run. If iOS asks you to trust the developer certificate, do that in Settings → General → VPN & Device Management.
5. Keep the Mac and iPhone on the same Wi-Fi for the first pair. A phone hotspot works when a guest network blocks device-to-device traffic. The Mac must be on that same hotspot.
6. On the iPhone, tap **Continue** so Tether can look for the Mac, then tap **Allow** on the system Local Network prompt.
7. Tap **Pair**, scan the QR code, or type the 16-character code. On the Mac, tap **Allow**.
8. The phone opens the shared folders. Files, Terminal, and Transfers are the three tabs.

To look around with no Mac, open Settings on the iPhone and turn on **Demo**. Sample files appear under Demo Mac, and the terminal commands that do not need a live machine still run against those samples.

iPhone Settings also has the device name (what the Mac shows for this phone), the home-screen icon (Gold, Blue, Green, or Neutral; light, dark, and tinted follow the system), a cache size and clear button, terminal font size from 11 to 20 points, and **Other networks** for the remote setup code.

## Everyday use on the iPhone

Tap a paired Mac to connect. If it is on the same Wi-Fi, the row says **Available**. If you have saved a remote code and the Mac is not on this network, the row says **Saved for other networks**.

The file browser starts at `/`, which is the list of shared folders, not the Mac’s real disk root. Open a folder, tap a file to preview it, or select several files and download them. Large downloads ask before they start. Search filters the current folder by name. Sort by name, date, size, or kind. Switch between list and grid. Pull to refresh discovery from the Mac list.

Downloads land in the app’s local files. Uploads use the system file picker and only succeed in a folder whose Mac-side switch allows uploads. The Transfers tab shows active and finished transfers, progress, and failures. Keep Tether in the foreground during a transfer. iOS can suspend the app, and a suspended app does not continue the copy.

The Terminal tab is a prompt of the form `mac-name:/Share/dir $`. History is the up and down keys. Tab completes commands and names in the current folder. Output wraps to the width of the monospaced font so a long line is not cut off at the edge of the screen. `exit` returns to Files. `clear` wipes the scrollback.

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

A line Tether does not implement, including a pipeline (`ls | grep pdf`), is run on the Mac with `zsh -c` in the current shared folder, or in your home directory when the working folder is `/`. Standard output and standard error come back as text. The command is stopped after 20 seconds. The terminal does not give that process a screen, a cursor, or a way to keep reading keystrokes, so interactive programs will not behave like they do in Terminal.app.

`whoami`, `status`, `fetch`, and `htop` do not shell out. They use system calls on the Mac and the existing encrypted session.

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

A home address such as `192.168.1.20` only works on that Wi-Fi. The internet cannot route to it. Tether has two ways to connect when Bonjour does not see the Mac.

1. **A reachable address.** The Mac listens on port **52173** while **Allow connections from other networks** is on. The Other networks page lists this Mac’s addresses. A Tailscale address (`100.x`) is preferred when one exists, then a public address, then a VPN address, then the Wi-Fi address. You can type a hostname instead, for example the name you forwarded on your router. The phone tries that address when the Mac is not on the local network. Private Wi-Fi addresses are only tried briefly, then Tether falls through to the relay if you set one.
2. **A relay.** Run `tether-relay` on a computer that has a public port. The Mac and the iPhone both connect outward to it, so the home router does not need a port forward. The default relay port is **52174**.

```bash
cd Packages/TetherCore
swift run tether-relay 52174
```

Leave that process running. On the Mac, open **Other networks**, turn the switch on, enter the relay address (for example `example.com:52174`), and save. Copy the setup code. On the iPhone, open Settings → **Other networks**, paste the code, and save. Pair on Wi-Fi once before that. The code is tied to the Mac you already paired. It carries the Mac id, the address, the relay, and a rendezvous token. The token is not the file-encryption key. Someone who has only the token still cannot pass the pairing handshake.

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
- The Mac app is sandboxed. It can read and write the folders you choose, plus the temporary file exceptions in `TetherHost/TetherHost.entitlements`. Process listing for the monitor is a sandbox exception (`process-info`). It does not grant the phone a shell.
- Unknown terminal commands do run `zsh -c` on the Mac, inside the current shared folder when there is one, with a 20 second limit. Treat that as a real command on your Mac user account, not as a pretend shell. Do not pair a phone you do not trust.

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
└── docs/                PRD.md and DESIGN.md
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

## Limits

- Mac and iPhone only. There is no Windows, Android, or Linux app. The relay tool runs wherever the Swift package runs, which today means the Mac you build it on.
- The phone cannot see folders you did not share.
- Transfers stop if iOS suspends the app.
- `htop` is a Tether screen, not the `htop` or `btop` program. `fetch` is a Tether portrait, not the real neofetch binary.
- Interactive TUIs, including Claude Code and the Cursor CLI, are not hosted. They need a pseudo-terminal that stays alive when the phone locks, and a phone view that understands a full terminal. That is not this terminal.
- Temperature depends on sensors the Mac exposes to the app. If a sensor is missing, the monitor still shows the thermal state (Nominal, Fair, Serious, or Critical).
- A relay or an open port is reachable by anyone who can route to it. They still need a paired device key to read files. Do not publish the setup code.
