import Foundation
import Testing
@testable import TetherCore

@Test func terminalOutPolicyInteractiveHoldIsShort() {
    #expect(TerminalOutPolicy.holdMilliseconds(pendingBytes: 32, msSinceLastFlush: nil) == TerminalOutPolicy.interactiveHoldMs)
    #expect(TerminalOutPolicy.holdMilliseconds(pendingBytes: 32, msSinceLastFlush: 200) == TerminalOutPolicy.interactiveHoldMs)
}

@Test func terminalOutPolicyStreamingHoldGathersAgentTraffic() {
    #expect(
        TerminalOutPolicy.holdMilliseconds(pendingBytes: 512, msSinceLastFlush: 20)
            == TerminalOutPolicy.streamingHoldMs
    )
}

@Test func terminalOutPolicySkipsHoldWhenSoftCapReached() {
    #expect(
        TerminalOutPolicy.holdMilliseconds(
            pendingBytes: TerminalOutPolicy.softCapBytes,
            msSinceLastFlush: 10
        ) == 0
    )
}

@Test func terminalOutPolicyTakeCountNeverExceedsHardCap() {
    #expect(TerminalOutPolicy.takeCount(pendingBytes: 0) == 0)
    #expect(TerminalOutPolicy.takeCount(pendingBytes: 100) == 100)
    #expect(
        TerminalOutPolicy.takeCount(pendingBytes: TerminalOutPolicy.hardCapBytes * 3)
            == TerminalOutPolicy.hardCapBytes
    )
}
