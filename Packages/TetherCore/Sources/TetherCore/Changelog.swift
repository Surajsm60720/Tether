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
    public static let current = "1.1"

    public static let releases: [ReleaseNotes] = [
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
