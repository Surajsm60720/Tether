import Foundation

enum L10n {
    static var appName: String { text("app.name", "Tether") }
    static var notSharing: String { text("host.notSharing", "Not sharing yet") }
    static var sharingPaused: String { text("host.paused", "Sharing is paused") }
    static var pair: String { text("host.pair", "Pair new iPhone…") }
    static var settings: String { text("host.settings", "Settings…") }
    static var quit: String { text("host.quit", "Quit") }
    static var addFolder: String { text("host.addFolder", "Add folder…") }
    static var sharedFolders: String { text("host.folders", "Shared folders") }
    static var connectedDevices: String { text("host.devices", "Connected devices") }
    static var disconnect: String { text("host.disconnect", "Disconnect") }
    static var readOnly: String { text("files.readonly", "Read only") }
    static var canUpload: String { text("host.canUpload", "Can upload") }
    static var pairScan: String { text("pair.scan.mac", "Scan this with Tether on your iPhone.") }
    static var pairWaiting: String { text("pair.waiting.mac", "Waiting for iPhone…") }
    static var pairSuccess: String { text("pair.success.mac", "Paired") }
    static var welcomeTitle: String { text("welcome.title", "Share a folder") }
    static var welcomeBody: String { text("welcome.body", "Pick a folder your iPhone can browse. Nothing is shared until you choose it.") }
    static var allowTitle: String { text("host.alert.title", "Allow “%@” to access your shared folders?") }
    static var general: String { text("settings.general", "General") }
    static var folders: String { text("settings.folders", "Folders") }
    static var devices: String { text("settings.devices", "Devices") }
    static var activity: String { text("settings.activity", "Activity") }
    static var macName: String { text("settings.macName", "Mac name") }
    static var launchAtLogin: String { text("settings.login", "Launch at login") }
    static var requireApproval: String { text("settings.approval", "Require approval each session") }
    static var revoke: String { text("settings.revoke", "Revoke") }
    static var clear: String { text("settings.clear", "Clear") }
    static var staleBookmark: String { text("host.stale", "A shared folder needs to be chosen again.") }

    static func status(folders: Int, devices: Int) -> String {
        String(format: text("host.status", "Sharing %d folders · %d device connected"), folders, devices)
    }

    static func allowBody(shares: String) -> String {
        String(format: text("host.alert.body", "It will be able to browse and download from: %@."), shares)
    }

    static func allowUpload(shares: String) -> String {
        String(format: text("host.alert.upload", "It can also add files to: %@."), shares)
    }

    static func wantsToConnect(_ name: String) -> String {
        String(format: text("pair.wants", "%@ wants to connect"), name)
    }

    private static func text(_ key: String, _ fallback: String) -> String {
        Bundle.main.localizedString(forKey: key, value: fallback, table: nil)
    }
}
