import AppKit
import Darwin
import Foundation
import TetherCore

/// Privilege / lid-ignore status for Settings.
enum SleepPrivilegeStatus: Equatable, Sendable {
    case notInstalled
    /// Files on disk and LaunchAgent loaded in the user gui domain.
    case installed
    /// Plist/script present but `launchctl` has no loaded service (Host must not bootout; re-install).
    case agentNotRunning
    /// Journal claims disablesleep but Host is not the holder (agent should clear soon).
    case recoveryPending
}

/// Holds idle-sleep assertion and, when privileged, lid-close sleep ignore via `pmset`.
///
/// `pmset` goes through a LaunchAgent (unsandboxed). That work must never block the main
/// thread — doing so froze Host at launch.
final class SleepGuard: @unchecked Sendable {
    private let lock = NSLock()
    private let workQueue = DispatchQueue(label: "app.tether.host.sleepguard")
    private var token: NSObjectProtocol?
    private var clamshellHeld = false
    private var clamshellEngaging = false
    private var lowPowerModePrevious: Bool?
    private let journalURL: URL
    private let runner: PmsetRunner
    private var terminateObserver: NSObjectProtocol?
    private var keepaliveTask: Task<Void, Never>?
    private var caffeinateProcess: Process?
    private var lastClamshellError: String?
    var onClamshellChanged: (() -> Void)?

    var isClamshellHeld: Bool {
        lock.lock()
        defer { lock.unlock() }
        return clamshellHeld
    }

    var isClamshellEngaging: Bool {
        lock.lock()
        defer { lock.unlock() }
        return clamshellEngaging
    }

    var clamshellError: String? {
        lock.lock()
        defer { lock.unlock() }
        return lastClamshellError
    }

    init(
        journalURL: URL = SleepJournalStore.defaultURL(),
        runner: PmsetRunner = ProcessPmsetRunner()
    ) {
        self.journalURL = journalURL
        self.runner = runner
        terminateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.setActive(false)
        }
    }

    deinit {
        if let terminateObserver {
            NotificationCenter.default.removeObserver(terminateObserver)
        }
        keepaliveTask?.cancel()
        stopCaffeinate()
    }

    /// - Parameter allowLidClosed: when false (e.g. on battery with saver on), keep idle
    ///   assertion / caffeinate but do not hold `pmset disablesleep`.
    func setActive(_ active: Bool, allowLidClosed: Bool = true) {
        if active {
            lock.lock()
            if token == nil {
                token = ProcessInfo.processInfo.beginActivity(
                    options: [.idleSystemSleepDisabled, .suddenTerminationDisabled],
                    reason: "Tether session or agent is active"
                )
            }
            let alreadyHeld = clamshellHeld
            let alreadyEngaging = clamshellEngaging
            lock.unlock()
            startCaffeinate()
            if allowLidClosed {
                if !alreadyHeld && !alreadyEngaging {
                    scheduleEngageClamshell()
                }
            } else if alreadyHeld || alreadyEngaging || (try? SleepJournalStore.read(from: journalURL)) != nil {
                lock.lock()
                clamshellEngaging = false
                lock.unlock()
                scheduleDisengageClamshell()
            }
        } else {
            lock.lock()
            if let token {
                ProcessInfo.processInfo.endActivity(token)
                self.token = nil
            }
            let shouldClear = clamshellHeld
                || clamshellEngaging
                || (try? SleepJournalStore.read(from: journalURL)) != nil
            clamshellEngaging = false
            lock.unlock()
            stopCaffeinate()
            stopNetworkKeepalive()
            if shouldClear {
                scheduleDisengageClamshell()
            }
        }
    }

    func privilegeStatus() -> SleepPrivilegeStatus {
        lock.lock()
        let held = clamshellHeld
        lock.unlock()
        SleepRecoveryAgent.reconcileMarkerIfNeeded()
        if let journal = try? SleepJournalStore.read(from: journalURL),
           journal.disablesleepEnabled,
           !held,
           SleepPolicy.shouldRecover(journal: journal, isOwnerAlive: ProcessPmsetRunner.isProcessAlive) {
            return .recoveryPending
        }
        guard SleepRecoveryAgent.filesPresent else { return .notInstalled }
        // Sandboxed Host cannot reliably bootstrap; treat unloaded agent as broken install.
        return SleepRecoveryAgent.isAgentLoaded ? .installed : .agentNotRunning
    }

    private func scheduleEngageClamshell() {
        lock.lock()
        clamshellEngaging = true
        lock.unlock()
        workQueue.async { [weak self] in
            self?.engageClamshell()
        }
    }

    private func scheduleDisengageClamshell() {
        workQueue.async { [weak self] in
            self?.disengageClamshell()
        }
    }

    private func engageClamshell() {
        let pid = ProcessInfo.processInfo.processIdentifier
        let journal = SleepJournal(
            ownerPID: pid,
            disablesleepEnabled: true,
            lowPowerModePrevious: nil,
            updatedAt: Date()
        )
        do {
            try SleepJournalStore.write(journal, to: journalURL)
        } catch {
            finishEngage(success: false, error: "Could not write sleep journal: \(error.localizedDescription)")
            return
        }
        guard runner.setDisablesleep(true) else {
            SleepJournalStore.remove(at: journalURL)
            let detail: String
            if !SleepRecoveryAgent.isAgentLoaded {
                detail = "Helper isn’t loaded. Use Repair setup, then Recheck."
            } else {
                detail = "Couldn’t change sleep settings. Repair setup, then Recheck."
            }
            finishEngage(success: false, error: detail)
            return
        }
        finishEngage(success: true, error: nil)
        startNetworkKeepalive()
    }

    private func finishEngage(success: Bool, error: String?) {
        lock.lock()
        clamshellEngaging = false
        if success {
            clamshellHeld = true
            lastClamshellError = nil
            lowPowerModePrevious = nil
        } else {
            clamshellHeld = false
            lastClamshellError = error
        }
        lock.unlock()
        DispatchQueue.main.async { [weak self] in
            self?.onClamshellChanged?()
        }
    }

    private func disengageClamshell() {
        let previous = lock.withLock { lowPowerModePrevious }
            ?? (try? SleepJournalStore.read(from: journalURL))?.lowPowerModePrevious
        _ = runner.setDisablesleep(false)
        if let previous {
            _ = runner.setBatteryLowPowerMode(previous)
        }
        SleepJournalStore.remove(at: journalURL)
        lock.lock()
        lowPowerModePrevious = nil
        clamshellHeld = false
        clamshellEngaging = false
        lastClamshellError = nil
        lock.unlock()
        DispatchQueue.main.async { [weak self] in
            self?.onClamshellChanged?()
        }
    }

    private func startNetworkKeepalive() {
        lock.lock()
        keepaliveTask?.cancel()
        keepaliveTask = Task.detached(priority: .utility) {
            while !Task.isCancelled {
                // One light ping to Tailscale's MagicDNS — enough to nudge Wi‑Fi under the lid
                // without waking radios twice every 15s (previous 1.1.1.1 + 15s interval).
                Self.pingOnce(host: "100.100.100.100")
                let onBattery = !MacPowerSource.isExternallyPowered()
                try? await Task.sleep(for: .seconds(onBattery ? 90 : 45))
            }
        }
        lock.unlock()
    }

    private func stopNetworkKeepalive() {
        lock.lock()
        keepaliveTask?.cancel()
        keepaliveTask = nil
        lock.unlock()
    }

    private static func pingOnce(host: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/sbin/ping")
        process.arguments = ["-c", "1", "-W", "1000", host]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return
        }
    }

    private func startCaffeinate() {
        lock.lock()
        defer { lock.unlock() }
        guard caffeinateProcess == nil else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
        process.arguments = ["-i", "-w", "\(ProcessInfo.processInfo.processIdentifier)"]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
            caffeinateProcess = process
        } catch {
            caffeinateProcess = nil
        }
    }

    private func stopCaffeinate() {
        lock.lock()
        let process = caffeinateProcess
        caffeinateProcess = nil
        lock.unlock()
        process?.terminate()
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}

// MARK: - pmset

protocol PmsetRunner: Sendable {
    func canRunPasswordless() -> Bool
    func setDisablesleep(_ enabled: Bool) -> Bool
    func readBatteryLowPowerMode() -> Bool?
    func setBatteryLowPowerMode(_ enabled: Bool) -> Bool
}

struct ProcessPmsetRunner: PmsetRunner {
    private static let pmset = "/usr/bin/pmset"
    private static let sudo = "/usr/bin/sudo"

    func canRunPasswordless() -> Bool {
        SleepRecoveryAgent.filesPresent
    }

    func setDisablesleep(_ enabled: Bool) -> Bool {
        if SleepRecoveryAgent.requestDisablesleep(enabled) {
            return true
        }
        return runSudoPmset(arguments: ["-a", "disablesleep", enabled ? "1" : "0"])
    }

    func readBatteryLowPowerMode() -> Bool? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.pmset)
        process.arguments = ["-g", "custom"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        var inBattery = false
        var batteryValue: Bool?
        var anyValue: Bool?
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("Battery Power") {
                inBattery = true
                continue
            }
            if trimmed.hasPrefix("AC Power") || trimmed.hasPrefix("UPS Power") {
                inBattery = false
                continue
            }
            if trimmed.contains("lowpowermode") {
                let enabled = trimmed.hasSuffix("1")
                anyValue = enabled
                if inBattery { batteryValue = enabled }
            }
        }
        return batteryValue ?? anyValue
    }

    func setBatteryLowPowerMode(_ enabled: Bool) -> Bool {
        runSudoPmset(arguments: ["-b", "lowpowermode", enabled ? "1" : "0"])
    }

    static func isProcessAlive(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        return kill(pid, 0) == 0
    }

    private func runSudoPmset(arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.sudo)
        process.arguments = ["-n", Self.pmset] + arguments
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return false
        }
        return process.terminationStatus == 0
    }
}

enum SleepRecoveryAgent {
    static let label = "com.tether.host.sleep-recovery"
    static let markerFileName = "sleep-privilege.installed"
    static let recoveryFileName = "tether-sleep-recovery.sh"
    static let requestFileName = "sleep-control.request"
    static let resultFileName = "sleep-control.result"

    static var plistURL: URL {
        RealUserHome.launchAgents.appendingPathComponent("\(label).plist")
    }

    static var supportDirectory: URL {
        RealUserHome.applicationSupport.appendingPathComponent("Tether", isDirectory: true)
    }

    static var recoveryScriptURL: URL {
        supportDirectory.appendingPathComponent(recoveryFileName)
    }

    static var markerURL: URL {
        supportDirectory.appendingPathComponent(markerFileName)
    }

    static var requestURL: URL {
        supportDirectory.appendingPathComponent(requestFileName)
    }

    static var resultURL: URL {
        supportDirectory.appendingPathComponent(resultFileName)
    }

    static var agentPresent: Bool {
        FileManager.default.fileExists(atPath: plistURL.path)
    }

    static var recoveryPresent: Bool {
        FileManager.default.fileExists(atPath: recoveryScriptURL.path)
    }

    static var markerPresent: Bool {
        FileManager.default.fileExists(atPath: markerURL.path)
    }

    static var filesPresent: Bool {
        agentPresent && recoveryPresent
    }

    static var isInstalled: Bool { filesPresent }

    static func reconcileMarkerIfNeeded() {
        guard filesPresent, !markerPresent else { return }
        try? supportDirectory.createIfNeeded()
        try? Data("installed\n".utf8).write(to: markerURL, options: .atomic)
    }

    /// Ask the unsandboxed LaunchAgent to run pmset. Safe to call off the main thread.
    static func requestDisablesleep(_ enabled: Bool) -> Bool {
        do {
            try ensureAgentFilesPresent()
        } catch {
            return false
        }
        // Never bootout/bootstrap from the sandboxed app — that unloads a working agent
        // and then fails with EIO, leaving lid-closed awake permanently broken.
        guard isAgentLoaded else { return false }
        try? FileManager.default.removeItem(at: resultURL)
        do {
            try "\(enabled ? "1" : "0")\n".write(to: requestURL, atomically: true, encoding: .utf8)
        } catch {
            return false
        }
        kickstartAgent()
        let deadline = Date().addingTimeInterval(2.5)
        while Date() < deadline {
            if let text = try? String(contentsOf: resultURL, encoding: .utf8) {
                if text.hasPrefix("ok") { return true }
                if text.hasPrefix("fail") { return false }
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return false
    }

    /// Ensure control-channel script/plist exist. Does **not** load the agent (Terminal install does).
    static func ensureAgentFilesPresent() throws {
        try supportDirectory.createIfNeeded()
        let script = (try? String(contentsOf: recoveryScriptURL, encoding: .utf8)) ?? ""
        let plist = (try? String(contentsOf: plistURL, encoding: .utf8)) ?? ""
        let needsScript = !script.contains("sleep-control.request")
        let needsPlist = !plist.contains("WatchPaths")
        if needsScript || needsPlist {
            try deployAgentFiles()
        }
    }

    static var isAgentLoaded: Bool {
        let uid = getuid()
        return runLaunchctl(["print", "gui/\(uid)/\(label)"])
    }

    static func deployAgentFiles() throws {
        try supportDirectory.createIfNeeded()
        try SleepPrivilegeScripts.recovery.write(to: recoveryScriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o700))],
            ofItemAtPath: recoveryScriptURL.path
        )
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
        	<key>Label</key>
        	<string>\(label)</string>
        	<key>ProgramArguments</key>
        	<array>
        		<string>/bin/bash</string>
        		<string>\(recoveryScriptURL.path)</string>
        	</array>
        	<key>WatchPaths</key>
        	<array>
        		<string>\(requestURL.path)</string>
        	</array>
        	<key>StartInterval</key>
        	<integer>60</integer>
        	<key>ThrottleInterval</key>
        	<integer>1</integer>
        	<key>RunAtLoad</key>
        	<true/>
        	<key>StandardOutPath</key>
        	<string>/tmp/tether-sleep-recovery.log</string>
        	<key>StandardErrorPath</key>
        	<string>/tmp/tether-sleep-recovery.log</string>
        </dict>
        </plist>
        """
        try plist.write(to: plistURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o644))],
            ofItemAtPath: plistURL.path
        )
        // Best-effort: quarantine on these files makes launchctl bootstrap return EIO.
        clearQuarantine(at: supportDirectory.path)
        clearQuarantine(at: plistURL.path)
    }

    private static func clearQuarantine(at path: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        process.arguments = ["-cr", path]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try? process.run()
        process.waitUntilExit()
    }

    private static func kickstartAgent() {
        let uid = getuid()
        // Kickstart only — never bootout from the app (sandbox cannot bootstrap back).
        _ = runLaunchctl(["kickstart", "-k", "gui/\(uid)/\(label)"])
    }

    @discardableResult
    private static func runLaunchctl(_ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
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
}

private extension URL {
    func createIfNeeded() throws {
        try FileManager.default.createDirectory(at: self, withIntermediateDirectories: true)
    }
}
