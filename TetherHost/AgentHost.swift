import Darwin
import Foundation
import TetherCore

/// The sandboxed host's `HOME` is its container. Agents need the real account
/// so they see `~/.claude`, `~/.cursor`, and the login shell's PATH.
enum AgentEnvironment {
    static var home: String {
        account.home
    }

    static func make(directory: String) -> [String: String] {
        let account = account
        var env = ProcessInfo.processInfo.environment
        env["HOME"] = account.home
        env["USER"] = account.name
        env["LOGNAME"] = account.name
        env["SHELL"] = "/bin/zsh"
        env["PWD"] = directory
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["FORCE_COLOR"] = "1"
        env["LANG"] = env["LANG"] ?? "en_US.UTF-8"
        if env["LC_CTYPE"] == nil { env["LC_CTYPE"] = env["LANG"] }
        let prefix = [
            "\(account.home)/.local/bin",
            "\(account.home)/.claude/local",
            "\(account.home)/.cursor/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
        ].joined(separator: ":")
        let base = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        env["PATH"] = prefix + ":" + base
        return env
    }

    private static var account: (home: String, name: String) {
        guard let pwd = getpwuid(getuid()) else { return (NSHomeDirectory(), NSUserName()) }
        let home = pwd.pointee.pw_dir.map { String(cString: $0) } ?? NSHomeDirectory()
        let name = pwd.pointee.pw_name.map { String(cString: $0) } ?? NSUserName()
        return (home.isEmpty ? NSHomeDirectory() : home, name.isEmpty ? NSUserName() : name)
    }
}

final class LiveAgent {
    let session: PTYSession
    let bridge: TerminalBridge
    let folder: URL
    var scoped: Bool

    init(session: PTYSession, bridge: TerminalBridge, folder: URL, scoped: Bool) {
        self.session = session
        self.bridge = bridge
        self.folder = folder
        self.scoped = scoped
    }
}
