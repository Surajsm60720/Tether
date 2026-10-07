import Foundation

/// Holds a process activity so macOS does not idle-sleep while a Tether session is active.
final class SleepGuard: @unchecked Sendable {
    private let lock = NSLock()
    private var token: NSObjectProtocol?

    func setActive(_ active: Bool) {
        lock.lock()
        defer { lock.unlock() }
        if active {
            guard token == nil else { return }
            token = ProcessInfo.processInfo.beginActivity(
                options: [.idleSystemSleepDisabled, .suddenTerminationDisabled],
                reason: "Tether session or agent is active"
            )
        } else if let token {
            ProcessInfo.processInfo.endActivity(token)
            self.token = nil
        }
    }
}
