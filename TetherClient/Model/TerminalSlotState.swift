import Foundation
import TetherCore

/// Runtime state for one Terminal tab slot (virtual, agent, monitor, or fetch).
@MainActor
final class TerminalSlotState: Identifiable {
    let id: String
    var kind: TerminalSlotKind
    var lines: [TermLine]
    var cwd: String
    var history: [String]
    var historyIndex: Int
    var agentProgram: String?
    var agentLine: String?
    var agentSessionID: String?
    var agentSurface: AgentSurface?
    var agentExited = false
    var agentExitCode = 0
    var agentError: String?
    var agentReceived = false
    var agentPaused = false
    var agentHostID: String?
    var agentColumns = 80
    var agentRows = 24
    var agentPending = Data()
    var agentOutbound = Data()
    var agentGeneration = 0
    var agentFlushScheduled = false
    var agentLastPaint = ContinuousClock.now.advanced(by: .seconds(-5))
    var agentLastByteAt = ContinuousClock.now.advanced(by: .seconds(-5))
    var agentWriteFailures = 0
    var agentOpenTask: Task<Void, Never>?
    var agentWriteScheduled = false
    var agentWriteChain: Task<Void, Never> = Task {}
    var agentIdlePublishTask: Task<Void, Never>?
    var agentNeedsYou = false
    var fetchText: String?

    init(
        id: String = UUID().uuidString,
        kind: TerminalSlotKind = .virtual,
        lines: [TermLine] = [],
        cwd: String = "/"
    ) {
        self.id = id
        self.kind = kind
        self.lines = lines
        self.cwd = cwd
        self.history = []
        self.historyIndex = 0
    }

    var title: String {
        TerminalSlotBook.shortTitle(kind: kind, cwd: cwd, program: agentProgram)
    }

    var isLiveAgent: Bool {
        kind == .agent && agentProgram != nil && !agentExited
    }

    var meta: TerminalSlotMeta {
        TerminalSlotMeta(
            id: id,
            kind: kind,
            title: title,
            agentSessionID: agentSessionID,
            agentProgram: agentProgram,
            agentLine: agentLine,
            agentHostID: agentHostID,
            cwd: cwd,
            agentNeedsYou: agentNeedsYou
        )
    }

    static func virtualWelcome(text: String) -> TerminalSlotState {
        TerminalSlotState(lines: [TermLine(text: text, kind: .dim)], cwd: "/")
    }
}
