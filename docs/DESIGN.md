# Tether — Design Guidelines (v0.1)

> Companion to `PRD.md`. Working title "Tether". This file defines look, feel, and interaction. When code and this file disagree, this file wins for visuals; `PRD.md` wins for behavior.

---

## 1. Design principles

1. **Native first.** Use standard SwiftUI and system components so the apps inherit the current system look (materials, bars, controls) automatically. Do not fake system chrome and do not restyle navigation bars, tab bars, toolbars, or sheets.
2. **Calm and obvious.** Two taps from launch to a file. No jargon in the GUI (no "TCP", "Bonjour", "port"). Technical vocabulary lives only in the terminal.
3. **Trust is visible.** Connection state, what is shared, and who is connected must always be visible and understandable. Security should feel reassuring, never scary.
4. **Two voices, one product.** The GUI is friendly and spacious. The terminal is dense, monospaced, and unapologetically technical. They share color tokens and the same connection indicator.
5. **Fast feeling.** Show skeletons and cached content immediately, then update. Never block the whole screen on a spinner.
6. **Control center, not disco.** The Mac host is a day-to-day control surface: configuration and operations come first. Prefer clear status, reachability, and the few controls a normal user needs at a glance. Do not bury core function under glitter, novelty chrome, or optional flourish. If something can be configured, it must live where a user would expect it.
7. **Sections vs Settings.** Sidebar **sections** hold only first-glance essentials (status, share folders, Inbox work, nearby iPhones). **Settings** (⌘,) holds tuning, preference, and infrequent setup. Never duplicate a Settings control inside a section — if it already exists in Settings, remove it from the section. When unsure whether a control belongs at first glance, put it in Settings.

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

Define semantic colors in one `Theme` file. The asset catalog remains the compiled Gold fallback; live UI reads `AppearancePreferences` presets (TetherCore) so users can switch Gold / Blue / Green / Neutral / Midnight. No ad-hoc hex in views outside that pipeline.

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
  - Send / Inbox: `tray.and.arrow.up` / `tray.and.arrow.down`; Shelf: `shippingbox`
  - Pairing: `qrcode.viewfinder`; security: `lock.shield`

---

## 6. iOS app

### 6.1 Navigation
- Root: **Hosts** screen. After connecting to a Mac, show a `TabView` with **Files**, **Send**, **Terminal**, **Transfers**. The navigation title in Files is the Mac's name with a menu to switch Mac or disconnect.
- Use `NavigationStack` for folder drilling. The title shows the current folder; a long-press (or the title menu) shows ancestors for quick jumping.

### 6.1a Send tab (v3.0)
- Tab symbol: `tray.and.arrow.up.fill`. Title "Send".
- Primary actions: **Photos** and **Files** pickers (multi-select). Each selection queues an upload into the Mac **Inbox** share (`/Inbox/…`), independent of the current Files browser path.
- Empty state: symbol `tray.and.arrow.up`, headline "Send to this Mac", body "Photos and files land in the Inbox on your Mac. Drag them out from the Shelf or open Inbox in Tether on the Mac."
- Active sends appear in the Transfers tab (same progress / cancel / retry).
- Share Extension uses the same Inbox destination; if Tether must come to the foreground to finish, show a short "Open Tether to finish" handoff.

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
Grouped list: Device name, **Appearance** (preset picker: Gold / Blue / Green / Neutral / Midnight; GUI text size 13–20 pt; text weight), home-screen Icon, Cache (size + Clear), Terminal font size slider (independent of GUI type), Forget all Macs (destructive, with confirmation), About with version and What's new. Appearance uses the shared `AppearancePreferences` model from TetherCore (local UserDefaults; not synced to the Mac).

### 6.10 Live Activities / Dynamic Island (v2.3)
Glanceable surfaces only — calm, few words, monospaced digits for percents and rates. Use Tether **gold** (`accent` / `#E8B04A` dark) explicitly — do not rely on system blue `.tint` inside the Island. Respect Reduce Motion and Always-On (`isLuminanceReduced`): no repeating pulse when dimmed. The whole Island is tappable; do **not** put clipped "Open Terminal" / "Transfers" labels in the bottom region.

**Transfer — compact:** gold up/down badge; trailing `62%` or `62% · +2` (single line, `fixedSize`). **Expanded Island:** one centered `HStack` (badge + copy + percent) — do **not** use separate leading/trailing regions (they sit higher than the center text on device). Lock Screen keeps a full-width progress row. No footer link text.

**Agent — compact:** leading brand mark / CLI thinking glyph; trailing status **word** only (no pencil / SF Symbol chrome). **Expanded Island:** one centered `HStack` (mark + copy); no trailing icon. Status chip (Thinking / Working / Running / Editing / Needs you / Waiting) tracks one live session via bottom-up PTY scrape: the focused agent slot if any, otherwise the agent with highest urgency (`Needs you` first). Tap opens Terminal focused on that slot (`tether://terminal`). When the agent needs approval or input, update with `AlertConfiguration` so the Island expands / Lock Screen banners — chip uses warning gold and detail “Waiting for your input”. Detail copy is fixed status wording only (v2.6) — never a scraped PTY line snippet. No GIF/video. No transcript in the Island. No multi-agent Island carousel.

---

## 7. macOS app

### 7.1 Menu bar item
- Glyph: SF Symbol `infinity` (same mark as the Dock icon). Do **not** stamp the full Dock square into the menu bar as a template — that reads as a white blob. Accessibility label states status.
- Use **`.menuBarExtraStyle(.menu)`** — a native system menu, not a custom window with bordered pill buttons.
- Menu contents: Sharing toggle; Disconnect rows when phones are connected; optional "N new"; Show Shelf; Open Tether; Pair; Settings; Quit.
- Do **not** list shared folders in the menu — manage those in the main window.

### 7.2 Pairing window
- Single-purpose window 420×520 pt, non-resizable, centered.
- Large QR code (240 pt) on a white rounded card (QR codes need a light background even in dark mode), the 16-character code beneath in monospaced type, a circular countdown (120 s), and the text "Scan this with Tether on your iPhone."
- Status line updates: *Waiting for iPhone…* → *"Suraj's iPhone" wants to connect* → approval alert. On success: checkmark and auto-close.

### 7.3 Approval alert
Native `NSAlert` style: title "Allow *<device>* to access your shared folders?", body "It will be able to browse and download from: *<share names>*." Buttons: **Allow** (default), **Don't Allow**. For shares that allow upload, add: "It can also add files to: *<names>*."

### 7.4 Main window sidebar
Primary pages (first-glance operations only): **Status**, **Shared folders**, **Inbox**, **iPhones**. A separate bottom sidebar row is a **Settings** `SettingsLink` (gear) that opens the full Settings window — the same scene as ⌘, and the menu bar popover — not a partial in-window copy. Do **not** put Other networks or Activity in the sidebar; those live only in Settings.

**Status** is the operational dashboard: Mac identity line (read-only), sharing master switch, network/status, connected devices with Disconnect. Mac name editing and other preferences live in Settings → General — not on Status.

**Shared folders** is the only place to add/remove folders and toggle Allow uploads.

**iPhones** is for discovery on this network (Look again, Pair, Connect). Paired-device revoke lives in Settings → Devices.

### 7.4a Inbox page (v3.0)
- List of files received from the iPhone: thumbnail, name (middle truncation), destination path, size, sender when known, received time.
- Row actions: Open, Reveal in Finder, Move…, Delete. Toolbar: Clear list (with confirmation; does not delete files on disk).
- Show the save destination as read-only context. **Change Inbox folder**, Shelf auto-show, and receive sound live only in Settings → General.
- Empty state: `tray`, "No files yet", path in the description.

### 7.4b Shelf window (v3.0)
- Floating utility panel (~420×120 pt, resizable horizontally), always-on-top optional via window level; closing it does not quit Tether.
- Horizontal strip of the **latest receive batch** only (thumbnail + short name). Multi-select + drag-out (`NSItemProvider`) into Finder and other apps.
- No Inbox-folder or Shelf preference controls on the Shelf itself — those stay in Settings. Auto-show when a file arrives if Settings → "Show Shelf when a file arrives" is on (default on).

### 7.5 Settings window
Standard Settings scene (⌘, / menu bar **Settings…** / sidebar Settings) with tabs:
- **General** — Mac name, launch at login, require approval, prevent sleep, Inbox folder, Show Shelf on receive, play sound on receive.
- **Appearance** — theme presets (Gold / Blue / Green / Neutral / Midnight), GUI text size and weight, Dock icon, version. Classic SwiftUI only.
- **Devices** — paired iPhones + Revoke.
- **Other networks** — remote listen, addresses, relay, iPhone setup code.
- **Activity** — event log.
- **What's new**.

Do not mirror Shared folders management here (that is the Shared folders section). Do not put a Sharing master switch here when Status already has it. Themes retint accent / type tokens only — they must not restyle sidebar chrome or turn operational pages into a component showcase.

### 7.5a Appearance model (v3.1)
- Tokens live in TetherCore (`AppearancePreset`, `AppearancePreferences`). Apps map them in `Theme.swift` (`Color.tether.*`, `TetherType.*`, optional terminal palette).
- Asset-catalog Gold colors remain the compiled fallback; live UI reads the active preset.
- No glass-intensity knobs and no Mac↔iPhone preference sync in v3.1.

### 7.6 Behavior polish
- Accessible keyboard shortcuts: `⌘,` Settings, `⌘N` Pair new iPhone (when the popover is key), `⌘Q` Quit.
- Respect Dark Mode and "Reduce transparency".
- No Dock icon by default; no first-launch window except a short welcome that asks the user to pick a folder to share. First Send setup may also prompt for an Inbox folder if none is configured.

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
