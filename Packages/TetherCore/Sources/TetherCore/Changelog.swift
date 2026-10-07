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
    public static let current = "2.1"

    public static let releases: [ReleaseNotes] = [
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
