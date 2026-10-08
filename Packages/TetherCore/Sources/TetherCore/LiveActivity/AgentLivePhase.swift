import Foundation

/// Coarse live-agent state for Dynamic Island / Live Activities.
/// Island **chip text** comes from `AgentStatusReading.label` (Thinking / Working / …);
/// `shortLabel` is only a fallback.
public enum AgentLivePhase: String, Codable, Sendable, CaseIterable {
    case opening
    case thinking
    case waiting
    case writing
    case paused
    case exited

    public var shortLabel: String {
        switch self {
        case .opening: "Starting"
        case .thinking: "Thinking"
        case .waiting: "Waiting"
        case .writing: "Editing"
        case .paused: "Paused"
        case .exited: "Done"
        }
    }

    public var symbolName: String {
        switch self {
        case .opening: "hourglass"
        case .thinking: "sparkles"
        case .waiting: "hand.raised.fill"
        case .writing: "pencil"
        case .paused: "pause.fill"
        case .exited: "checkmark.circle.fill"
        }
    }

    /// Whether the CLI thinking glyph animation should run.
    public var animatesThinkingGlyph: Bool {
        self == .thinking || self == .writing
    }

    /// SF Symbol fallback when a brand asset is missing.
    public static func brandSymbol(for program: String) -> String {
        switch program.lowercased() {
        case "claude": "brain.head.profile"
        case "cursor", "cursor-agent", "agent": "chevron.left.forwardslash.chevron.right"
        case "codex": "doc.text"
        case "gemini": "sparkle"
        case "copilot": "person.crop.circle.badge.checkmark"
        case "aider": "wrench.and.screwdriver"
        case "goose": "leaf"
        case "opencode": "chevron.left.forwardslash.chevron.right"
        default: "terminal.fill"
        }
    }

    /// Asset catalog image name in the Live Activity widget extension.
    public static func brandAssetName(for program: String) -> String {
        switch program.lowercased() {
        case "claude": "AgentClaude"
        case "cursor", "cursor-agent", "agent": "AgentCursor"
        case "codex": "AgentCodex"
        case "gemini": "AgentGemini"
        case "copilot": "AgentCopilot"
        default: "AgentDefault"
        }
    }
}

public enum AgentLivePhaseResolver {
    /// Resolve phase + chip label from lifecycle + live PTY status scrape.
    public static func resolveReading(
        received: Bool,
        paused: Bool,
        exited: Bool,
        title: String?,
        recentlyWrote: Bool,
        idleFor: Duration = .seconds(0),
        screenTail: String? = nil
    ) -> AgentStatusReading {
        if exited { return AgentStatusReading(phase: .exited, label: "Done") }
        if paused { return AgentStatusReading(phase: .paused, label: "Paused") }
        if !received { return AgentStatusReading(phase: .opening, label: "Starting") }

        return AgentScreenHint.reading(
            title: title,
            screenTail: screenTail,
            idleFor: idleFor,
            recentlyWrote: recentlyWrote
        )
    }

    /// Convenience when only the phase enum is needed.
    public static func resolve(
        received: Bool,
        paused: Bool,
        exited: Bool,
        title: String?,
        recentlyWrote: Bool,
        idleFor: Duration = .seconds(0),
        screenTail: String? = nil
    ) -> AgentLivePhase {
        resolveReading(
            received: received,
            paused: paused,
            exited: exited,
            title: title,
            recentlyWrote: recentlyWrote,
            idleFor: idleFor,
            screenTail: screenTail
        ).phase
    }

    public static func detail(
        reading: AgentStatusReading,
        title: String?,
        hostName: String
    ) -> String {
        if let snippet = reading.detail, !snippet.isEmpty {
            return snippet
        }
        return detail(phase: reading.phase, title: title, hostName: hostName)
    }

    public static func detail(
        phase: AgentLivePhase,
        title: String?,
        hostName: String
    ) -> String {
        let host = hostName.trimmingCharacters(in: .whitespacesAndNewlines)
        switch phase {
        case .opening:
            return host.isEmpty ? "Starting on Mac…" : "Starting · \(shortHost(host))"
        case .thinking:
            if let title = cleanedTitle(title), !looksLikeGenericStatus(title) {
                return truncate(title, limit: 28)
            }
            return host.isEmpty ? "Working on Mac…" : "On · \(shortHost(host))"
        case .waiting:
            return "Waiting for your input"
        case .writing:
            if let title = cleanedTitle(title), !looksLikeGenericStatus(title) {
                return truncate(title, limit: 28)
            }
            return host.isEmpty ? "Editing files" : "Editing · \(shortHost(host))"
        case .paused:
            return "Reopen Tether to resume"
        case .exited:
            return "Session finished"
        }
    }

    private static func cleanedTitle(_ title: String?) -> String? {
        guard let title else { return nil }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func looksLikeGenericStatus(_ title: String) -> Bool {
        let lower = title.lowercased()
        let generics = ["thinking", "thinking…", "thinking...", "working", "running", "spinner"]
        return generics.contains(lower)
    }

    private static func truncate(_ value: String, limit: Int) -> String {
        guard value.count > limit else { return value }
        let end = value.index(value.startIndex, offsetBy: max(0, limit - 1))
        return String(value[..<end]) + "…"
    }

    private static func shortHost(_ host: String) -> String {
        var value = host
        if let range = value.range(of: #"'s\s+"#, options: .regularExpression) {
            value = String(value[range.upperBound...])
        }
        return truncate(value, limit: 18)
    }
}
