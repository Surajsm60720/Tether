import Foundation

/// Pure rule for when the Mac host should hold a sleep assertion.
public enum SleepPolicy: Sendable {
    /// Stay awake only while the setting is on and a phone is connected or an agent is still running.
    public static func shouldStayAwake(enabled: Bool, connectedDevices: Int, liveAgents: Int) -> Bool {
        enabled && (connectedDevices > 0 || liveAgents > 0)
    }
}
