# Tether — Design Guidelines (v0.1)

> Companion to `PRD.md`. Working title "Tether". This file defines look, feel, and interaction. When code and this file disagree, this file wins for visuals; `PRD.md` wins for behavior.

---

## 1. Design principles

1. **Native first.** Use standard SwiftUI and system components so the apps inherit the current system look (materials, bars, controls) automatically. Do not fake system chrome and do not restyle navigation bars, tab bars, toolbars, or sheets.
2. **Calm and obvious.** Two taps from launch to a file. No jargon in the GUI (no "TCP", "Bonjour", "port"). Technical vocabulary lives only in the terminal.
3. **Trust is visible.** Connection state, what is shared, and who is connected must always be visible and understandable. Security should feel reassuring, never scary.
4. **Two voices, one product.** The GUI is friendly and spacious. The terminal is dense, monospaced, and unapologetically technical. They share color tokens and the same connection indicator.
5. **Fast feeling.** Show skeletons and cached content immediately, then update. Never block the whole screen on a spinner.

---

## 2. Brand and tone

- **Personality:** quiet, capable, a little geeky.
- **Voice:** short, plain sentences. Tell people what happened and what to do next.
  - Good: "Couldn't reach Studio Mac. Make sure both devices are on the same Wi-Fi."
  - Bad: "Connection error 0x2F: NWError.posix(60)."
- **Never** blame the user. **Never** use exclamation marks except for the pairing success message.
- App icon: a simple, bold glyph of two linked rounded squares (a phone and a Mac) in the accent gold on a charcoal background. Provide light, dark, and tinted variants following current Apple icon guidance, and keep the glyph centered with generous padding.

---

## 3. Color tokens

Define all colors in one `Theme` file using an asset catalog with Light/Dark variants. No raw hex values anywhere else in code.

### 3.1 Core palette

| Token | Light | Dark | Use |
|---|---|---|---|
| `accent` | `#C98A1B` | `#E8B04A` | Tint, selection, primary buttons, progress |
| `accentText` | `#7A5200` | `#F2C970` | Accent-colored text on neutral backgrounds (meets contrast) |
| `success` | `#1F8A4C` | `#4CC38A` | Connected, completed |
| `warning` | `#B26A00` | `#F0A84A` | Waiting, slow link |
| `danger` | `#C62F2F` | `#FF6B6B` | Errors, revoke, delete |
| `surface` | system grouped background | system grouped background | Screens (use system colors) |
| `surfaceRaised` | system secondary grouped background | same | Cards, rows |

Rules:
- Use system semantic colors (`.primary`, `.secondary`, `Color(.systemBackground)` and friends) for text and backgrounds. Only the tokens above are custom.
- **Never use `accent` as small text color on light backgrounds** (contrast is insufficient). Use `accentText`, or put text on an accent fill with a dark label.
- Never rely on color alone: pair status color with an icon and a word.

### 3.2 Terminal palette (both modes use the dark terminal by default; a light variant is optional)

| Token | Hex | Use |
|---|---|---|
| `term.bg` | `#121417` | Background |
| `term.fg` | `#E6E1D6` | Default text |
| `term.dim` | `#7D8590` | Secondary text, timestamps |
| `term.prompt` | `#E8B04A` | Prompt and cursor |
| `term.dir` | `#6CB6FF` | Directory names |
| `term.file` | `#E6E1D6` | Files |
| `term.exec` | `#7EE787` | Success lines |
| `term.error` | `#FF7B72` | Errors |

---

## 4. Typography

- **GUI:** system font (SF Pro) with Dynamic Type text styles only (`.title2`, `.headline`, `.body`, `.subheadline`, `.footnote`, `.caption`). No fixed point sizes.
- **Numbers (sizes, speeds, ETAs):** `.monospacedDigit()` so values do not jitter while updating.
- **Terminal:** SF Mono (`.system(.body, design: .monospaced)`). Default 14 pt on iOS, 13 pt on macOS; user-adjustable 11–20 pt in Settings. Line height 1.25.
- Titles use sentence case ("Shared folders", not "Shared Folders").
- Truncate file names in the middle (`lineLimit(1)` with `.truncationMode(.middle)`) so extensions stay visible.

---

## 5. Layout, spacing, shape

- **Grid:** 4 pt base. Common steps: 4, 8, 12, 16, 24, 32.
- **Screen margins:** system default (16 pt on iPhone). Rows min height 44 pt; all tap targets at least 44×44 pt.
- **Corner radius:** thumbnails 10 pt, cards 12 pt, chips 8 pt (use continuous corners: `RoundedRectangle(cornerRadius:style: .continuous)`).
- **Elevation:** use system materials and grouped lists; avoid custom drop shadows.
- **Icons:** SF Symbols only, `.symbolRenderingMode(.hierarchical)` by default. Use `.fill` variants for selected tab states. Suggested symbols:
  - Mac host: `desktopcomputer` / `laptopcomputer`
  - Connected: `checkmark.circle.fill`; searching: `antenna.radiowaves.left.and.right`
  - Folder: `folder.fill`; file: `doc`; image: `photo`; video: `film`; audio: `waveform`; archive: `archivebox`
  - Terminal: `terminal`; transfers: `arrow.up.arrow.down.circle`
  - Pairing: `qrcode.viewfinder`; security: `lock.shield`

---

## 6. iOS app

### 6.1 Navigation
- Root: **Hosts** screen. After connecting to a Mac, show a `TabView` with **Files**, **Terminal**, **Transfers**. The navigation title in Files is the Mac's name with a menu to switch Mac or disconnect.
- Use `NavigationStack` for folder drilling. The title shows the current folder; a long-press (or the title menu) shows ancestors for quick jumping.

### 6.2 Hosts screen
- Large title "Your Macs". Two sections: **Nearby** (discovered, not yet paired, with a "Pair" button) and **Paired** (with a status dot + word: "Connected", "Available", "Not found").
- Empty state: illustration (SF Symbol composition, not custom art), headline "Looking for your Mac…", body "Open Tether on your Mac and make sure both devices are on the same Wi-Fi.", secondary button "Pair with a code".
- Pull to refresh restarts the browser.

### 6.3 Local Network primer (before the system prompt)
- Full-screen sheet, icon `wifi`, title "Find your Mac nearby".
- Body: "Tether needs to look for devices on your Wi-Fi network. Your files never leave your local network."
- Primary button: "Continue" (then trigger the system prompt). If denied later, show: "Local Network access is off. Turn it on in Settings to find your Mac." with an **Open Settings** button.

### 6.4 Pairing
- Full-screen camera with a rounded square reticle and the text "Scan the code on your Mac".
- Link under the reticle: "Enter code instead" (monospaced 4×4 field, auto-uppercase, forgiving of O/0 and I/1/L per Crockford rules).
- States with distinct icon and text: *Connecting…* → *Waiting for approval on your Mac…* (animated pulse, can cancel) → success (checkmark, haptic `.success`, "Paired with *Studio Mac*") → auto-dismiss after 1.2 s. Failure messages use the voice rules in §2.

### 6.5 Files
- **List mode (default):** 40 pt icon/thumbnail leading, name (headline weight regular), secondary line "Today · 2.4 MB" or "12 items" for folders.
- **Grid mode:** adaptive columns (minimum 110 pt), square thumbnail, name below (2 lines max, middle truncation).
- **Toolbar:** view toggle, sort menu, "+" (Upload). **Search field:** `.searchable` prompt "Search files"; walks shared folders live and lists matches with full virtual path (tap file to preview, tap folder to navigate). Empty query returns to the current-folder list/grid.
- **Row actions:** swipe leading = Download; context menu = Preview, Download, Share, Get Info.
- **Thumbnails:** load lazily; show a symbol placeholder immediately; cross-fade in (150 ms).
- **Folders that cannot be read:** row dimmed with a lock icon; tap shows a brief explanation.
- **Empty folder:** "This folder is empty."

### 6.6 Preview and downloads
- Tapping a file starts download with an inline determinate progress ring on the row (not a blocking modal). When complete, present QuickLook.
- Large files (over 100 MB): confirm once with the size ("Download 1.4 GB?").
- Provide **Share** and **Save to Files** in the preview.

### 6.7 Transfers tab
- Sections: Active, Completed. Each row: icon, name, direction arrow (up/down), progress bar, "12.4 MB/s · 8 s left" (monospaced digits). Swipe to cancel or retry. A banner at the top when the app is not in the foreground: "Keep Tether open while transferring."

### 6.8 Terminal tab
- Full-bleed dark terminal (`term.bg`) regardless of system appearance, status bar style adapted.
- Top strip (thin): host name with connection dot, current directory (or agent/Monitor/fetch title for that slot); during a live agent slot also a Files control (leaves Terminal without ending the session), copy, and a close button (ends that agent). Closing a virtual/fetch/monitor slot discards that slot; the last slot cannot be closed (a fresh virtual shell is kept). Otherwise close on a lone virtual shell returns to Files.
- **Slot strip (v2.4):** under the header, up to three short tabs (`~`, agent display name, `Monitor`, `fetch`) plus a `+` to open another virtual shell (disabled at three). Long-press/drag reorders. Only the focused slot is interactive; others keep running in the background. A Live or Needs-you dot marks agent slots when appropriate.
- While a live agent slot is focused on the Terminal tab, the root tab bar is hidden so the PTY and accessory key row use the full bottom edge. The header Files control (folder) switches to Files without ending sessions; the Terminal tab shows a Live badge while any agent is still running. Leaving Terminal dismisses the keyboard so Files and Transfers keep the full screen. Focusing a non-agent slot restores the root tab bar.
- `htop` / `btop` and `fetch` open or focus Monitor/fetch slots inside the Terminal tab (not a full-screen cover over the app). Pause Monitor polling when that slot is not focused or when the root tab is not Terminal.
- Accessory key row above the keyboard: a keyboard show/hide key, then `Tab` `Esc` `Ctrl` `↑` `↓` `/` `~` `-` `|`, each a 44 pt-tall key with `term.dim` outline. The live agent row also has `S-Tab`, `Y`, and `N` for permission menus. The key row uses normal keyboard avoidance (no manual keyboard-frame lift). Opening the keyboard must not resize the remote PTY (that was clipping those menus); the phone keeps the last full size until the keyboard hides. Inactive agent slots must not apply collapsed layout sizes. Tapping the agent screen shows the keyboard again.
- Blinking block cursor in `term.prompt`. Respect Reduce Motion by not blinking.
- Command output color rules: directories `term.dir` with trailing `/`, errors `term.error`, informational `term.dim`.
- Long-press output to select text; a floating "Copy" action appears.
- Welcome line on open: `Tether terminal · type 'help' for commands` in `term.dim`.
- Virtual shell only: a scrollable suggestion list above the prompt (folder/doc/terminal SF Symbol + name, max height ~260 pt, visible scroll indicators, count header) for live path and command matches; the full match list is kept — never truncated to a “N more” hint. Command rows show typed syntax and a short description; tap inserts. `help` shows the same height of scrollable catalog with syntax (flags/placeholders) per row. Esc dismisses the menu before clearing the draft. Live agents keep the PTY Tab behavior; no dropdown on the agent screen.

### 6.9 Settings
Grouped list: Device name, Cache (size + Clear), Terminal font size slider, Forget all Macs (destructive, with confirmation), About with version and What's new.

### 6.10 Live Activities / Dynamic Island (v2.3)
Glanceable surfaces only — calm, few words, monospaced digits for percents and rates. Use Tether **gold** (`accent` / `#E8B04A` dark) explicitly — do not rely on system blue `.tint` inside the Island. Respect Reduce Motion and Always-On (`isLuminanceReduced`): no repeating pulse when dimmed. The whole Island is tappable; do **not** put clipped "Open Terminal" / "Transfers" labels in the bottom region.

**Transfer — compact:** gold up/down badge; trailing `62%` or `62% · +2` (single line, `fixedSize`). **Expanded Island:** one centered `HStack` (badge + copy + percent) — do **not** use separate leading/trailing regions (they sit higher than the center text on device). Lock Screen keeps a full-width progress row. No footer link text.

**Agent — compact:** leading brand mark / CLI thinking glyph; trailing status **word** only (no pencil / SF Symbol chrome). **Expanded Island:** one centered `HStack` (mark + copy); no trailing icon. Status chip (Thinking / Working / Running / Editing / Needs you / Waiting) tracks one live session via bottom-up PTY scrape: the focused agent slot if any, otherwise the agent with highest urgency (`Needs you` first). Tap opens Terminal focused on that slot (`tether://terminal`). When the agent needs approval or input, update with `AlertConfiguration` so the Island expands / Lock Screen banners — chip uses warning gold and detail “Waiting for your input”. No GIF/video. No transcript in the Island. No multi-agent Island carousel.

---

## 7. macOS app

### 7.1 Menu bar item
- Template image symbol; states: idle (outline), device connected (filled with a small dot), sharing paused (slashed). Provide an accessibility label that states the status.
- Popover window (style `.window`), width 320 pt, content in vertical sections:
  1. **Header:** app name, status line ("Sharing 2 folders · 1 device connected"), master switch.
  2. **Connected devices:** device name, connected duration, a small "Disconnect" button.
  3. **Shared folders:** list with folder icon, name, access badge ("Read only" / "Can upload"). "Add folder…" button.
  4. **Footer:** "Pair new iPhone…", "Settings…", "Quit".

### 7.2 Pairing window
- Single-purpose window 420×520 pt, non-resizable, centered.
- Large QR code (240 pt) on a white rounded card (QR codes need a light background even in dark mode), the 16-character code beneath in monospaced type, a circular countdown (120 s), and the text "Scan this with Tether on your iPhone."
- Status line updates: *Waiting for iPhone…* → *"Suraj's iPhone" wants to connect* → approval alert. On success: checkmark and auto-close.

### 7.3 Approval alert
Native `NSAlert` style: title "Allow *<device>* to access your shared folders?", body "It will be able to browse and download from: *<share names>*." Buttons: **Allow** (default), **Don't Allow**. For shares that allow upload, add: "It can also add files to: *<names>*."

### 7.4 Main window sidebar
Primary pages: Status, Shared folders, iPhones, Other networks, Activity. A separate bottom sidebar row is a **Settings** `SettingsLink` (gear) that opens the full Settings window — the same scene as ⌘, and the menu bar popover — not a partial in-window copy.

### 7.5 Settings window
Standard Settings scene (⌘, / menu bar **Settings…** / sidebar Settings) with tabs: **General** (Mac name, launch at login, require approval each session, prevent sleep), **Folders**, **Devices**, **Other networks**, **Activity**, **What's new**.

### 7.6 Behavior polish
- Accessible keyboard shortcuts: `⌘,` Settings, `⌘N` Pair new iPhone (when the popover is key), `⌘Q` Quit.
- Respect Dark Mode and "Reduce transparency".
- No Dock icon by default; no first-launch window except a short welcome that asks the user to pick a folder to share.

---

## 8. Motion and haptics

- **Default animation:** `.snappy` (about 0.25 s). Use `withAnimation` for list changes; `matchedGeometryEffect` for thumbnail → preview is optional polish.
- **Pairing success:** checkmark draw/scale (0.35 s).
- **Connecting:** subtle pulsing of the host icon, not a spinner, for discovery; a standard `ProgressView` for short waits.
- **Reduce Motion:** replace movement with cross-fades; disable pulsing and cursor blink.
- **Haptics (iOS):** `.success` on pairing and completed download, `.warning` on lost connection, `.selection` when toggling view mode, light impact on pull-to-refresh trigger. Never haptic during continuous progress.

---

## 9. States and feedback

| State | Treatment |
|---|---|
| Loading folder | Cached content immediately if available, otherwise 8 skeleton rows |
| Offline / host unreachable | Inline banner at top: icon + "Studio Mac isn't reachable" + "Retry". Keep cached listings readable but dimmed |
| Reconnecting | Small "Reconnecting…" capsule in the nav bar; auto-dismiss on success |
| Permission denied by Mac | Alert: "This folder isn't shared with your iPhone." |
| Upload to read-only share | Alert: "This folder is read-only. Choose a folder that allows uploads." |
| Transfer failed | Row turns `danger` with "Failed · Retry"; do not auto-retry more than twice |
| Revoked | Full-screen message: "This Mac removed your iPhone. Pair again to reconnect." with a **Pair again** button |

Destructive actions (forget Mac, revoke device, delete) always use a confirmation with a red button and a clear object name.

---

## 10. Accessibility

- **Dynamic Type:** all GUI text scales to the largest accessibility sizes; layouts switch to single-column and wrap secondary lines. The terminal has its own font-size setting instead.
- **VoiceOver:**
  - Rows: "Quarterly report, PDF, 2.4 megabytes, modified today" / "Photos, folder, 12 items".
  - Status dots have text equivalents ("Connected").
  - Terminal output is an accessibility element group; new output posts an announcement (rate-limited).
  - QR scanner: spoken instruction plus the "Enter code instead" path is always available.
- **Contrast:** text and meaningful icons meet WCAG AA (4.5:1 for text under 18 pt). Verify `accentText` and terminal colors in both modes.
- **Hit targets:** minimum 44×44 pt on iOS.
- **Motion:** honor Reduce Motion; no flashing content.
- **Input:** full keyboard navigation on macOS and hardware keyboard support in the iOS terminal (arrows, Tab, Ctrl-C, Ctrl-L).

---

## 11. Copy deck (reference strings)

| Key | String |
|---|---|
| `hosts.title` | Your Macs |
| `hosts.empty.title` | Looking for your Mac… |
| `hosts.empty.body` | Open Tether on your Mac and make sure both devices are on the same Wi-Fi. |
| `pair.scan.title` | Scan the code on your Mac |
| `pair.waiting` | Waiting for approval on your Mac… |
| `pair.success` | Paired with %@ |
| `pair.failed.expired` | That code has expired. Create a new one on your Mac. |
| `pair.failed.locked` | Too many attempts. Try again in a few minutes. |
| `files.empty` | This folder is empty. |
| `files.readonly` | This folder is read-only. |
| `transfers.keepOpen` | Keep Tether open while transferring. |
| `net.unreachable` | %@ isn't reachable. Check that both devices are on the same Wi-Fi. |
| `perm.localnetwork.off` | Local Network access is off. Turn it on in Settings to find your Mac. |
| `host.alert.title` | Allow “%@” to access your shared folders? |
| `term.welcome` | Tether terminal · type 'help' for commands |
| `term.notfound` | tether: command not found: %@. Type 'help'. |

---

## 12. Implementation notes for the coding agent

- Create `Theme.swift` in each app target (or a shared `TetherUI` package if both apps use it) exposing `Color.tether.accent`, `.accentText`, `.success`, `.warning`, `.danger`, and a `TerminalTheme` struct with the `term.*` values. All colors come from the asset catalog.
- Build reusable views early: `HostRow`, `FileRow`, `FileGridItem`, `TransferRow`, `StatusDot`, `EmptyStateView`, `TerminalView`, `AccessoryKeyRow`.
- Every view gets an Xcode Preview with: normal data, empty data, long names, the largest Dynamic Type size, and dark mode.
- Use `Localizable.xcstrings` for all user-facing text from §11; no inline string literals in views.
- Do not use custom navigation bar or tab bar backgrounds. Do not use `.toolbarBackground` overrides.
- Run an accessibility audit (Xcode Accessibility Inspector) before each milestone sign-off.

---

*End of Design Guidelines v0.1*
