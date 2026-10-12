import Foundation

/// Heartbeat / soft-probe policy for long-lived sessions (especially Tailscale + lid-closed).
///
/// Brief stalls of tens of seconds are normal on cellular↔Tailscale paths; tear down only after
/// repeated failed pings *and* no recent application traffic.
public enum SessionLiveness: Sendable {
    public static let pingInterval: Duration = .seconds(12)
    public static let pingTimeout: Duration = .seconds(30)
    public static let maxConsecutiveMisses = 8

    /// Foreground / path-change probes — longer than LAN so one stall does not look dead.
    public static let softProbeTimeout: Duration = .seconds(10)
    public static let softProbeRetryTimeout: Duration = .seconds(15)

    /// Any decrypted frame within this window counts as alive (skips a soft probe).
    public static let recentTrafficGrace: TimeInterval = 40

    public static func hasRecentTraffic(lastReceived: Date, now: Date = Date(), grace: TimeInterval = recentTrafficGrace) -> Bool {
        now.timeIntervalSince(lastReceived) < grace
    }

    public static func shouldDisconnect(consecutiveMisses: Int, hasRecentTraffic: Bool) -> Bool {
        !hasRecentTraffic && consecutiveMisses >= maxConsecutiveMisses
    }
}
