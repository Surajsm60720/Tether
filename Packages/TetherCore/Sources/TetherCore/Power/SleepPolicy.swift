import Foundation

/// Pure rule for when the Mac host should hold a sleep assertion / lid-ignore.
public enum SleepPolicy: Sendable {
    /// Stay awake while the setting is on and something needs the Mac online:
    /// a phone session, a live agent, or (optional) remote listening for Tailscale / other networks.
    public static func shouldStayAwake(
        enabled: Bool,
        connectedDevices: Int,
        liveAgents: Int,
        keepRemoteReachable: Bool = false
    ) -> Bool {
        enabled && (connectedDevices > 0 || liveAgents > 0 || keepRemoteReachable)
    }

    /// Clear `disablesleep` when a journal claims it and the owning Host process is gone.
    /// Agent processes alone never keep the flag on.
    public static func shouldRecover(
        journal: SleepJournal?,
        isOwnerAlive: (Int32) -> Bool
    ) -> Bool {
        guard let journal, journal.disablesleepEnabled else { return false }
        return !isOwnerAlive(journal.ownerPID)
    }
}
