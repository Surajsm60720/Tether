#if canImport(ActivityKit)
import ActivityKit
import Foundation
import TetherCore

/// Starts / updates / ends Live Activities for transfers and agents (opportunistic, local-only).
/// Call only from the main actor (ClientStore). Not MainActor-isolated so ActivityKit's
/// non-Sendable `Activity` can be passed into `update`/`end` without region errors.
final class LiveActivityCoordinator: @unchecked Sendable {
    static let shared = LiveActivityCoordinator()

    private var transferActivity: Activity<TetherTransferAttributes>?
    private var agentActivity: Activity<TetherAgentAttributes>?
    private var lastTransferPush = ContinuousClock.now.advanced(by: .seconds(-5))
    private var lastTransferSnapshot: TransferLiveSnapshot?
    private var lastAgentPhase: AgentLivePhase?
    private var lastAgentDetail: String?
    private var lastStatusLabel: String?
    private var agentPulse = false
    private var glyphFrame = 0
    private var transferEndTask: Task<Void, Never>?
    private var agentEndTask: Task<Void, Never>?
    private var glyphTickTask: Task<Void, Never>?

    private var agentProgram: String?
    private var agentDisplayName: String?
    private var agentHostName: String = ""
    private var agentTitle: String?
    private var agentScreenTail: String?
    private var agentStatusLabel: String = "Thinking"

    private init() {}

    func syncTransfers(
        items: [TransferItem],
        hostName: String,
        force: Bool = false
    ) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            endTransfer(dismissImmediately: true)
            return
        }

        let activeInputs = items.filter { $0.state == .active }.map(Self.input(from:))
        let completedCount = items.filter {
            $0.state == .completed && $0.message != "Cancelled"
        }.count
        let finished = items
            .filter { $0.state != .active }
            .sorted { $0.started > $1.started }
            .first
            .map(Self.input(from:))

        guard let snapshot = TransferLiveSnapshotBuilder.build(
            active: activeInputs,
            completedCount: completedCount,
            finishedPrimary: activeInputs.isEmpty ? finished : nil
        ) else {
            endTransfer(dismissImmediately: true)
            return
        }

        let now = ContinuousClock.now
        let elapsed = lastTransferPush.duration(to: now)
        let changedMeaningfully =
            lastTransferSnapshot?.phase != snapshot.phase
            || lastTransferSnapshot?.fileName != snapshot.fileName
            || lastTransferSnapshot?.batchCompleted != snapshot.batchCompleted
            || lastTransferSnapshot?.batchTotal != snapshot.batchTotal
            || abs((lastTransferSnapshot?.fraction ?? -1) - snapshot.fraction) >= 0.01
        guard force || changedMeaningfully || elapsed >= .milliseconds(1000) else { return }

        lastTransferPush = now
        lastTransferSnapshot = snapshot
        let state = TetherTransferAttributes.ContentState(from: snapshot)
        let relevance: Double = agentActivity == nil ? 70 : 40
        let content = ActivityContent(state: state, staleDate: nil, relevanceScore: relevance)

        if let activity = transferActivity {
            Task { await activity.update(content) }
        } else if snapshot.phase == .active || snapshot.phase == .paused {
            let attributes = TetherTransferAttributes(hostName: hostName)
            transferActivity = try? Activity.request(attributes: attributes, content: content, pushType: nil)
        }

        switch snapshot.phase {
        case .active, .paused:
            transferEndTask?.cancel()
            transferEndTask = nil
        case .completed:
            scheduleTransferEnd(after: .seconds(4))
        case .failed:
            scheduleTransferEnd(after: .seconds(5))
        }
    }

    func syncAgent(
        program: String?,
        displayName: String?,
        received: Bool,
        paused: Bool,
        exited: Bool,
        title: String?,
        recentlyWrote: Bool,
        idleFor: Duration = .seconds(0),
        screenTail: String? = nil,
        hostName: String,
        force: Bool = false
    ) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            endAgent(dismissImmediately: true)
            return
        }
        guard let program, let displayName else {
            endAgent(dismissImmediately: true)
            return
        }

        let reading = AgentLivePhaseResolver.resolveReading(
            received: received,
            paused: paused,
            exited: exited,
            title: title,
            recentlyWrote: recentlyWrote,
            idleFor: idleFor,
            screenTail: screenTail
        )
        let phase = reading.phase
        let statusLabel = reading.label

        // Attributes.program is immutable — recreate the activity when the agent switches
        // so Claude never keeps Gemini’s spark from a prior session.
        let programChanged = agentProgram != nil && agentProgram != program
        if programChanged {
            endAgent(dismissImmediately: true)
        }

        agentProgram = program
        agentDisplayName = displayName
        agentHostName = hostName
        agentTitle = title
        agentScreenTail = screenTail
        agentStatusLabel = statusLabel

        let detail = AgentThinkingGlyph.detail(
            program: program,
            phase: phase,
            frame: glyphFrame,
            title: title,
            hostName: hostName,
            statusLabel: statusLabel,
            readingDetail: reading.detail
        )
        let phaseChanged = phase != lastAgentPhase
        let statusChanged = statusLabel != lastStatusLabel
        // Expand Island / Lock Screen banner when the agent first needs input.
        let shouldAlert = reading.wantsAttention && (phaseChanged || statusChanged)
        guard force || programChanged || phaseChanged || statusChanged || detail != lastAgentDetail else {
            if phase.animatesThinkingGlyph { ensureGlyphTicker() }
            return
        }

        if phaseChanged || statusChanged {
            agentPulse.toggle()
            if !phase.animatesThinkingGlyph { glyphFrame = 0 }
        }
        lastAgentPhase = phase
        lastAgentDetail = detail
        lastStatusLabel = statusLabel
        pushAgentState(
            program: program,
            displayName: displayName,
            phase: phase,
            statusLabel: statusLabel,
            detail: detail,
            hostName: hostName,
            alert: shouldAlert
        )

        if phase.animatesThinkingGlyph {
            ensureGlyphTicker()
        } else {
            stopGlyphTicker()
        }

        if phase == .exited {
            scheduleAgentEnd(after: .seconds(5))
        } else {
            agentEndTask?.cancel()
            agentEndTask = nil
        }
    }

    func markBackgroundExpired(transfers: inout [TransferItem], hostName: String, hasLiveAgent: Bool) {
        // Caller already failed active transfers with keep-open copy; Island shows paused.
        let pausedCompleted = transfers.filter { $0.state == .completed }.count
        if let snapshot = TransferLiveSnapshotBuilder.build(
            active: [],
            completedCount: pausedCompleted,
            finishedPrimary: transfers
                .filter { $0.message == L10n.keepOpen }
                .sorted { $0.started > $1.started }
                .first
                .map {
                    TransferLiveSnapshotBuilder.Input(
                        name: $0.name,
                        isUpload: $0.direction == .up,
                        sent: $0.sent,
                        total: $0.total,
                        started: $0.started,
                        state: .paused
                    )
                }
        ) {
            lastTransferSnapshot = snapshot
            lastTransferPush = ContinuousClock.now
            let state = TetherTransferAttributes.ContentState(from: snapshot)
            let content = ActivityContent(state: state, staleDate: nil, relevanceScore: 40)
            if let activity = transferActivity {
                Task { await activity.update(content) }
            } else {
                let attributes = TetherTransferAttributes(hostName: hostName)
                transferActivity = try? Activity.request(attributes: attributes, content: content, pushType: nil)
            }
            scheduleTransferEnd(after: .seconds(8))
        }

        if hasLiveAgent, let activity = agentActivity {
            stopGlyphTicker()
            let program = activity.content.state.program.isEmpty
                ? (agentProgram ?? activity.attributes.program)
                : activity.content.state.program
            let state = TetherAgentAttributes.ContentState(
                program: program,
                displayName: activity.content.state.displayName,
                phase: .paused,
                statusLabel: "Paused",
                detail: AgentLivePhaseResolver.detail(phase: .paused, title: nil, hostName: hostName),
                hostName: hostName,
                pulse: agentPulse,
                glyphFrame: glyphFrame
            )
            lastAgentPhase = .paused
            lastAgentDetail = state.detail
            lastStatusLabel = "Paused"
            agentStatusLabel = "Paused"
            Task { await activity.update(ActivityContent(state: state, staleDate: nil, relevanceScore: 95)) }
        }
    }

    func endAll() {
        endTransfer(dismissImmediately: true)
        endAgent(dismissImmediately: true)
    }

    private func scheduleTransferEnd(after delay: Duration) {
        transferEndTask?.cancel()
        transferEndTask = Task {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            endTransfer(dismissImmediately: false)
        }
    }

    private func scheduleAgentEnd(after delay: Duration) {
        agentEndTask?.cancel()
        agentEndTask = Task {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            endAgent(dismissImmediately: false)
        }
    }

    func endTransfer(dismissImmediately: Bool) {
        transferEndTask?.cancel()
        transferEndTask = nil
        lastTransferSnapshot = nil
        guard let activity = transferActivity else { return }
        transferActivity = nil
        Task {
            await activity.end(nil, dismissalPolicy: dismissImmediately ? .immediate : .default)
        }
    }

    func endAgent(dismissImmediately: Bool) {
        stopGlyphTicker()
        agentEndTask?.cancel()
        agentEndTask = nil
        lastAgentPhase = nil
        lastAgentDetail = nil
        lastStatusLabel = nil
        agentProgram = nil
        agentDisplayName = nil
        agentTitle = nil
        agentScreenTail = nil
        agentStatusLabel = "Thinking"
        glyphFrame = 0
        guard let activity = agentActivity else { return }
        agentActivity = nil
        Task {
            await activity.end(nil, dismissalPolicy: dismissImmediately ? .immediate : .default)
        }
    }

    private func pushAgentState(
        program: String,
        displayName: String,
        phase: AgentLivePhase,
        statusLabel: String,
        detail: String,
        hostName: String,
        alert: Bool = false
    ) {
        let state = TetherAgentAttributes.ContentState(
            program: program,
            displayName: displayName,
            phase: phase,
            statusLabel: statusLabel,
            detail: detail,
            hostName: hostName,
            pulse: agentPulse,
            glyphFrame: glyphFrame
        )
        // Waiting-for-input gets max relevance so the Island prefers the agent over transfers.
        let relevance: Double = alert || phase == .waiting ? 100 : 95
        let content = ActivityContent(state: state, staleDate: nil, relevanceScore: relevance)
        let alertConfig: AlertConfiguration? = alert
            ? AlertConfiguration(
                title: "\(displayName) needs you",
                body: "Waiting for your input — tap to open Terminal",
                sound: .default
            )
            : nil

        if let activity = agentActivity {
            // Attributes can’t change — if they drifted, replace the activity.
            if activity.attributes.program != program {
                agentActivity = nil
                Task { await activity.end(nil, dismissalPolicy: .immediate) }
                let attributes = TetherAgentAttributes(program: program)
                agentActivity = try? Activity.request(attributes: attributes, content: content, pushType: nil)
            } else {
                Task { await activity.update(content, alertConfiguration: alertConfig) }
            }
        } else {
            let attributes = TetherAgentAttributes(program: program)
            agentActivity = try? Activity.request(attributes: attributes, content: content, pushType: nil)
        }
    }

    private func ensureGlyphTicker() {
        guard glyphTickTask == nil else { return }
        glyphTickTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let program = self.agentProgram ?? "claude"
                let style = AgentThinkingGlyph.style(for: program)
                try? await Task.sleep(for: style.tickInterval)
                guard !Task.isCancelled else { return }
                guard let phase = self.lastAgentPhase, phase.animatesThinkingGlyph else { return }
                guard let displayName = self.agentDisplayName, let prog = self.agentProgram else { return }

                // Keep the last scraped status — fresh PTY scrapes arrive via syncAgent.
                let statusLabel = self.agentStatusLabel
                self.glyphFrame &+= 1
                self.agentPulse.toggle()
                let detail = AgentThinkingGlyph.detail(
                    program: prog,
                    phase: phase,
                    frame: self.glyphFrame,
                    title: self.agentTitle,
                    hostName: self.agentHostName,
                    statusLabel: statusLabel
                )
                self.lastAgentDetail = detail
                self.pushAgentState(
                    program: prog,
                    displayName: displayName,
                    phase: phase,
                    statusLabel: statusLabel,
                    detail: detail,
                    hostName: self.agentHostName,
                    alert: false
                )
            }
        }
    }

    private func stopGlyphTicker() {
        glyphTickTask?.cancel()
        glyphTickTask = nil
    }

    private static func input(from item: TransferItem) -> TransferLiveSnapshotBuilder.Input {
        let phase: TransferLivePhase = switch item.state {
        case .active: .active
        case .completed: .completed
        case .failed: .failed
        }
        return TransferLiveSnapshotBuilder.Input(
            name: item.name,
            isUpload: item.direction == .up,
            sent: item.sent,
            total: item.total,
            started: item.started,
            state: phase
        )
    }

}
#endif
