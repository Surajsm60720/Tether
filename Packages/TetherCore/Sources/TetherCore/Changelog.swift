import Foundation

public struct ReleaseNotes: Equatable, Sendable, Identifiable {
    public var version: String
    public var items: [String]

    public var id: String { version }

    public init(version: String, items: [String]) {
        self.version = version
        self.items = items
    }
}

/// User-facing history shown in Settings on the Mac and the iPhone.
public enum AppChangelog {
    public static let current = "2.4"

    public static let releases: [ReleaseNotes] = [
        ReleaseNotes(version: "2.4", items: [
            "Terminal slots: open up to three windows inside Terminal and switch without losing progress.",
            "Each slot can be a virtual shell, a live coding agent, the system Monitor, or a pinned fetch snapshot.",
            "Drag to reorder slots; only one is on screen at a time — the others keep running in the background.",
            "htop, btop, and fetch open as slots instead of covering the whole app, so you can jump back to a shell or agent.",
            "Run more than one coding agent at once (still capped at three terminals); the Island follows the focused or most urgent agent.",
        ]),
        ReleaseNotes(version: "2.3", items: [
            "Live Activities and Dynamic Island show file-transfer progress and live coding-agent status while you use other apps.",
            "Transfers: percent, speed, and ETA on the Island and Lock Screen; tap to jump back to Transfers.",
            "Agents: per-tool mark plus live Thinking / Working / Running / Editing status from the terminal; tap to return to Terminal.",
            "When an agent asks for approval or input, the Island expands with a Needs you alert so you can jump back in.",
            "Updates are opportunistic while iOS keeps the app awake — then the Island freezes on the last state until you reopen Tether.",
        ]),
        ReleaseNotes(version: "2.2", items: [
            "Prevent sleep while active: the Mac stays awake during a connected session or live agent, so remote work is not cut off. Toggle it in Settings on the Mac and the iPhone.",
            "Remote and hotspot reconnects no longer detach a live agent when the old socket closes after the new one resumes.",
            "Typing and dictation stay responsive over other networks: keystrokes are sent without waiting for each ACK.",
            "After a network switch, the phone probes the path sooner and restores the terminal keyboard when the agent comes back.",
            "Terminal suggestions: tap a command or path from a scrollable dropdown while typing; Tab still fills a unique match or opens the same list. help opens a catalog with typed syntax and flags.",
            "Files search finds names across every shared folder (live walk from the Mac, not a local index); tap a hit to open the file or go to that folder.",
            "Settings is in the Mac window sidebar (gear) and opens the full Settings window, same as ⌘, or the menu bar.",
        ]),
        ReleaseNotes(version: "2.1", items: [
            "Leave a live agent for Files or Transfers without ending it; Terminal shows a Live badge until you close with X.",
            "While the agent fills the Terminal tab, the tab bar hides so the PTY and key row use the full bottom edge.",
            "Opening the software keyboard no longer shrinks the remote screen, so Claude Code, Codex, and Cursor permission menus stay visible.",
            "Accessory keys: show or hide the keyboard; live agents also get S-Tab, Y, and N for those prompts.",
            "Control-tap an http or https link (OSC 8 or plain text) to open it in the phone browser; a plain tap focuses the keyboard.",
            "Snappier paint when the agent is idle so follow-ups and permission menus appear on the next frame.",
        ]),
        ReleaseNotes(version: "2.0", items: [
            "Run allowlisted coding agents from the phone: Claude Code, Cursor Agent, Codex, and related CLIs.",
            "A live pseudo-terminal on the Mac drives the agent; the phone is the screen and keyboard.",
            "Agents keep running when you leave the app; reconnect resumes the same session.",
            "Batched PTY output and a viewport-only phone draw keep long agent runs cooler and smoother.",
            "Tab completion for commands and paths in the everyday terminal.",
            "Everyday file commands stay virtual and share-scoped; only named agents get a live PTY.",
        ]),
        ReleaseNotes(version: "1.2", items: [
            "Faster reconnect when the iPhone wakes: dead sockets are probed and replaced instead of hanging.",
            "Cancelled transfers release their waiters immediately instead of leaking for the session lifetime.",
            "Preview cache and downloads use Complete file protection while the device is locked.",
            "The monitor only lists processes owned by your Mac user account, with short names (no paths).",
            "Huge folders stop after a bounded scan so listing cannot exhaust host memory.",
            "Empty network reads back off instead of spinning the CPU.",
        ]),
        ReleaseNotes(version: "1.1", items: [
            "Security hardening: the phone terminal no longer runs a Mac shell; only built-in commands work.",
            "Caps inbound connections and handshake time so silent TCP floods cannot exhaust the Mac.",
            "Enforces a global lock after repeated failed handshakes; pairing still locks after five bad codes.",
            "Device keys stay in the Keychain; old on-disk secret mirrors are cleared on load.",
            "Uploads abort cleanly on disconnect; out-of-range chunks and symlink write escapes are rejected.",
            "Directory listings are paginated under the frame size limit; relay prelude waits time out.",
            "Host sandbox no longer grants whole-home read/write for a general shell.",
        ]),
        ReleaseNotes(version: "1.0", items: [
            "Pair an iPhone with a Mac by QR code or a typed code, then reconnect without a password.",
            "Browse, preview, download, and upload files in the folders you choose to share.",
            "Follow transfers with progress, retry, and cancel.",
            "Use a terminal for everyday file commands inside those folders.",
            "See who you are with whoami, a short Mac summary with fetch, and a live monitor with htop or btop.",
            "The monitor shows CPU, memory, swap, disk, network, battery, temperature, and the busiest processes.",
            "Reach the Mac from another network with a saved address or a relay, after pairing once on Wi-Fi.",
            "Choose an icon color, set the terminal font size, and clear the preview cache.",
            "Approve or revoke each iPhone from the Mac.",
        ]),
    ]
}
