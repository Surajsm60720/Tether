import Foundation

enum L10n {
    static var hostsTitle: String { text("hosts.title", "Your Macs") }
    static var hostsEmptyTitle: String { text("hosts.empty.title", "Looking for your Mac…") }
    static var hostsEmptyBody: String { text("hosts.empty.body", "Open Tether on your Mac and make sure both devices are on the same Wi-Fi.") }
    static var pairWithCode: String { text("hosts.pairCode", "Pair with a code") }
    static var nearby: String { text("hosts.nearby", "Nearby") }
    static var paired: String { text("hosts.paired", "Paired") }
    static var pair: String { text("hosts.pair", "Pair") }
    static var primerTitle: String { text("primer.title", "Find your Mac nearby") }
    static var primerBody: String { text("primer.body", "Tether needs to look for devices on your Wi-Fi network. Your files never leave your local network.") }
    static var continueButton: String { text("primer.continue", "Continue") }
    static var localNetworkOff: String { text("perm.localnetwork.off", "Local Network access is off. Turn it on in Settings to find your Mac.") }
    static var openSettings: String { text("perm.settings", "Open Settings") }
    static var scanTitle: String { text("pair.scan.title", "Scan the code on your Mac") }
    static var enterCode: String { text("pair.enter", "Enter code instead") }
    static var connecting: String { text("pair.connecting", "Connecting…") }
    static var pairWaiting: String { text("pair.waiting", "Waiting for approval on your Mac…") }
    static var filesEmpty: String { text("files.empty", "This folder is empty.") }
    static var readOnly: String { text("files.readonly", "This folder is read-only.") }
    static var keepOpen: String { text("transfers.keepOpen", "Keep Tether open while transferring.") }
    static var termWelcome: String { text("term.welcome", "Tether terminal · type 'help' for commands") }

    static func agentNeedsMac(_ name: String) -> String {
        "\(name) runs on your Mac. Connect to it, then try again."
    }
    static var files: String { text("tab.files", "Files") }
    static var send: String { text("tab.send", "Send") }
    static var terminal: String { text("tab.terminal", "Terminal") }
    static var transfers: String { text("tab.transfers", "Transfers") }
    static var settings: String { text("settings.title", "Settings") }
    static var demo: String { text("settings.demo", "Demo") }

    static func pairSuccess(_ name: String) -> String {
        String(format: text("pair.success", "Paired with %@"), name)
    }

    static func unreachable(_ name: String) -> String {
        String(format: text("net.unreachable", "%@ isn't reachable. Check that both devices are on the same Wi-Fi."), name)
    }

    static func downloadConfirm(_ size: String) -> String {
        "Download \(size)?"
    }

    private static func text(_ key: String, _ fallback: String) -> String {
        Bundle.main.localizedString(forKey: key, value: fallback, table: nil)
    }
}
