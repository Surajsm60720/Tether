import Foundation
import Testing
@testable import TetherCore

@Test func sessionLivenessRecentTrafficWithinGrace() {
    let now = Date()
    let recent = now.addingTimeInterval(-10)
    #expect(SessionLiveness.hasRecentTraffic(lastReceived: recent, now: now, grace: 40))
    let stale = now.addingTimeInterval(-50)
    #expect(!SessionLiveness.hasRecentTraffic(lastReceived: stale, now: now, grace: 40))
}

@Test func sessionLivenessDisconnectRequiresMissesAndNoTraffic() {
    #expect(!SessionLiveness.shouldDisconnect(consecutiveMisses: 3, hasRecentTraffic: false))
    #expect(!SessionLiveness.shouldDisconnect(consecutiveMisses: 8, hasRecentTraffic: true))
    #expect(SessionLiveness.shouldDisconnect(consecutiveMisses: 8, hasRecentTraffic: false))
    #expect(SessionLiveness.shouldDisconnect(
        consecutiveMisses: SessionLiveness.maxConsecutiveMisses,
        hasRecentTraffic: false
    ))
}

@Test func sessionLivenessSoftProbeTimeoutsAreLongerThanLanDefaults() {
    #expect(SessionLiveness.softProbeTimeout >= .seconds(8))
    #expect(SessionLiveness.softProbeRetryTimeout >= SessionLiveness.softProbeTimeout)
    #expect(SessionLiveness.pingTimeout >= .seconds(20))
    #expect(SessionLiveness.maxConsecutiveMisses >= 6)
}
