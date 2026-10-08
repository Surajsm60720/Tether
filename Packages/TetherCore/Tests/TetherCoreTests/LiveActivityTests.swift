import Foundation
import Testing
@testable import TetherCore

@Test func agentPhaseResolveLifecycle() {
    #expect(AgentLivePhaseResolver.resolve(
        received: false, paused: false, exited: false, title: nil, recentlyWrote: false
    ) == .opening)
    #expect(AgentLivePhaseResolver.resolve(
        received: true, paused: true, exited: false, title: nil, recentlyWrote: false
    ) == .paused)
    #expect(AgentLivePhaseResolver.resolve(
        received: true, paused: false, exited: true, title: nil, recentlyWrote: true
    ) == .exited)
}

@Test func agentStatusScrapesBottomUp() {
    // Stale Thinking in scrollback must lose to fresher Editing at the bottom.
    let tail = """
    ✽ Thinking…
    some earlier chatter
    Writing App.swift
    """
    let reading = AgentScreenHint.reading(title: nil, screenTail: tail, recentlyWrote: true)
    #expect(reading.label == "Editing")
    #expect(reading.phase == .writing)

    #expect(AgentScreenHint.reading(
        title: nil, screenTail: "Working on your request…", recentlyWrote: true
    ).label == "Working")

    #expect(AgentScreenHint.reading(
        title: nil, screenTail: "Running bash command", recentlyWrote: true
    ).label == "Running")

    #expect(AgentScreenHint.reading(
        title: nil, screenTail: "✳ Thinking…", recentlyWrote: true
    ).label == "Thinking")

    let needsYou = AgentScreenHint.reading(
        title: nil, screenTail: "Do you want to allow this?", recentlyWrote: false
    )
    #expect(needsYou.label == "Needs you")
    #expect(needsYou.wantsAttention)
    #expect(needsYou.detail == "Waiting for your input")

    #expect(AgentScreenHint.reading(
        title: nil, screenTail: "Approve plan to continue", recentlyWrote: true
    ).wantsAttention)

    // Soft idle prompt → Waiting (no alert)
    let soft = AgentScreenHint.reading(
        title: nil, screenTail: "How can I help you today?",
        idleFor: .seconds(2), recentlyWrote: false
    )
    #expect(soft.label == "Waiting")
    #expect(!soft.wantsAttention)
}

@Test func agentPhaseFollowsScreenCues() {
    #expect(AgentLivePhaseResolver.resolveReading(
        received: true, paused: false, exited: false, title: nil, recentlyWrote: true,
        screenTail: "Writing App.swift"
    ).label == "Editing")

    #expect(AgentLivePhaseResolver.resolveReading(
        received: true, paused: false, exited: false, title: "Thinking…", recentlyWrote: true,
        screenTail: "Thinking…\nEdited 2 files"
    ).label == "Editing")
}

@Test func agentPhaseWordingIsImmersive() {
    #expect(AgentLivePhase.writing.shortLabel == "Editing")
    #expect(AgentLivePhase.thinking.shortLabel == "Thinking")
    #expect(AgentLivePhase.exited.shortLabel == "Done")
    #expect(AgentLivePhaseResolver.detail(phase: .writing, title: nil, hostName: "Suraj's MacBook Air")
        == "Editing · MacBook Air")
    #expect(AgentLivePhaseResolver.detail(phase: .paused, title: nil, hostName: "X")
        == "Reopen Tether to resume")
}

@Test func transferSnapshotBatchLabel() {
    let now = Date()
    let small = TransferLiveSnapshotBuilder.Input(
        name: "a.txt", isUpload: false, sent: 90, total: 100, started: now, state: .active
    )
    let large = TransferLiveSnapshotBuilder.Input(
        name: "big.bin", isUpload: true, sent: 10, total: 1_000_000, started: now, state: .active
    )
    let snap = TransferLiveSnapshotBuilder.build(
        active: [small, large],
        completedCount: 2,
        finishedPrimary: nil,
        now: now
    )
    #expect(snap?.fileName == "big.bin")
    #expect(snap?.batchCompleted == 2)
    #expect(snap?.batchTotal == 4)
    #expect(snap?.batchLabel == "2 of 4")
    #expect(snap?.trailingCompact.contains("2/4") == true)
}

@Test func transferSnapshotHidesBatchForSingleFile() {
    let now = Date()
    let one = TransferLiveSnapshotBuilder.Input(
        name: "solo.pdf", isUpload: false, sent: 1, total: 2, started: now, state: .active
    )
    let snap = TransferLiveSnapshotBuilder.build(
        active: [one],
        completedCount: 0,
        finishedPrimary: nil,
        now: now
    )
    #expect(snap?.batchLabel == "")
    #expect(snap?.trailingCompact == "50%")
}

@Test func brandSymbolsAreStable() {
    #expect(AgentLivePhase.brandAssetName(for: "claude") == "AgentClaude")
    #expect(AgentLivePhase.brandAssetName(for: "cursor-agent") == "AgentCursor")
    #expect(AgentLivePhase.brandAssetName(for: "gemini") == "AgentGemini")
    #expect(AgentLivePhase.thinking.animatesThinkingGlyph)
    #expect(AgentLivePhase.writing.animatesThinkingGlyph)
    #expect(!AgentLivePhase.waiting.animatesThinkingGlyph)
}

@Test func thinkingGlyphsMatchCLIFrames() {
    #expect(AgentThinkingGlyph.style(for: "claude") == .claude)
    let claudeBases = AgentThinkingGlyph.claudeFrames.map { frame -> String in
        String(frame.unicodeScalars.filter { $0.value != 0xFE0E }.map(Character.init))
    }
    #expect(claudeBases == ["·", "✢", "✳", "✶", "✻", "✽"])
    #expect(AgentThinkingGlyph.claudeFrames.allSatisfy { $0.unicodeScalars.contains(where: { $0.value == 0xFE0E }) })
    #expect(AgentThinkingGlyph.geminiFrames.count == 10)
    #expect(AgentThinkingGlyph.style(for: "codex").tickInterval == .seconds(2))
    let mask = AgentThinkingGlyph.style(for: "gemini").brailleSixDotMask(frame: 0)
    #expect(mask == 0x0B)
}
