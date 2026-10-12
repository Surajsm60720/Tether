import AppKit
import Darwin
import Foundation
import TetherCore

enum SleepPrivilegeInstallOutcome: Equatable {
    case openedTerminal
    case failed(String)
}

/// Materializes embedded installer scripts outside the app sandbox and runs them in Terminal.
///
/// Sandboxed `Application Support` lives under `~/Library/Containers/…`; Terminal cannot
/// execute those scripts ("Operation not permitted"). Scripts go to `/private/tmp` instead.
enum SleepPrivilegeInstaller {
    /// Opens Terminal to run the installer (user enters their password once).
    @discardableResult
    static func runInstallInTerminal() -> SleepPrivilegeInstallOutcome {
        runInTerminal(primary: SleepPrivilegeScripts.installFileName)
    }

    /// Opens Terminal to remove sudoers + recovery agent.
    @discardableResult
    static func runUninstallInTerminal() -> SleepPrivilegeInstallOutcome {
        runInTerminal(primary: SleepPrivilegeScripts.uninstallFileName)
    }

    private static func runInTerminal(primary: String) -> SleepPrivilegeInstallOutcome {
        let script: URL
        do {
            script = try materializeScripts().appendingPathComponent(primary)
        } catch {
            return .failed("Could not prepare the installer on disk: \(error.localizedDescription)")
        }
        guard FileManager.default.fileExists(atPath: script.path) else {
            return .failed("Installer script missing after prepare.")
        }

        _ = run("/usr/bin/xattr", arguments: ["-cr", script.deletingLastPathComponent().path])

        if openTerminalWithAppleScript(script: script) {
            return .openedTerminal
        }
        if openTerminalWithOsascript(script: script) {
            return .openedTerminal
        }

        let command = "/bin/bash \(shellQuote(script.path))"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
        return .failed(
            """
            Could not open Terminal automatically.

            The install command was copied to your clipboard. Paste it into Terminal and press Return:

            \(command)
            """
        )
    }

    /// Writes scripts under `/private/tmp` (entitled + executable by Terminal).
    private static func materializeScripts() throws -> URL {
        let support = URL(fileURLWithPath: "/private/tmp/tether-host-installer-\(getuid())", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o755))],
            ofItemAtPath: support.path
        )
        let files: [(String, String)] = [
            (SleepPrivilegeScripts.installFileName, SleepPrivilegeScripts.install),
            (SleepPrivilegeScripts.uninstallFileName, SleepPrivilegeScripts.uninstall),
            (SleepPrivilegeScripts.recoveryFileName, SleepPrivilegeScripts.recovery),
        ]
        for (name, body) in files {
            let url = support.appendingPathComponent(name)
            try body.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o755))],
                ofItemAtPath: url.path
            )
        }
        return support
    }

    private static func openTerminalWithAppleScript(script: URL) -> Bool {
        let command = "clear; /bin/bash \(shellQuote(script.path)); status=$?; echo; echo \"Press Return to close.\"; read; exit $status"
        let source = """
        tell application "Terminal"
            activate
            do script "\(escapeForAppleScript(command))"
        end tell
        """
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        return result != nil && error == nil
    }

    private static func openTerminalWithOsascript(script: URL) -> Bool {
        let command = "clear; /bin/bash \(shellQuote(script.path)); status=$?; echo; echo \"Press Return to close.\"; read; exit $status"
        let source = """
        tell application "Terminal"
            activate
            do script "\(escapeForAppleScript(command))"
        end tell
        """
        return run("/usr/bin/osascript", arguments: ["-e", source])
    }

    @discardableResult
    private static func run(_ executable: String, arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    private static func shellQuote(_ path: String) -> String {
        "'\(path.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private static func escapeForAppleScript(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
