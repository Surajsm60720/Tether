import Foundation

/// Live status scraped from the PTY for Island labels — phase + short word, never raw transcript.
public struct AgentStatusReading: Equatable, Sendable {
    public var phase: AgentLivePhase
    /// Chip text: Thinking / Working / Running / Editing / Needs you / Waiting / …
    public var label: String
    /// Optional one-line context (already truncated / scrubbed).
    public var detail: String?
    /// Fire a Live Activity alert (expands Island / Lock Screen banner).
    public var wantsAttention: Bool

    public init(
        phase: AgentLivePhase,
        label: String,
        detail: String? = nil,
        wantsAttention: Bool = false
    ) {
        self.phase = phase
        self.label = label
        self.detail = detail
        self.wantsAttention = wantsAttention
    }
}

/// Coarse activity cues from the live PTY. Keyword match only — transcript is never copied out.
public enum AgentScreenHint: Sendable {
    /// Tail of `plainText()` used for cue matching (last ~2 KB).
    public static func tail(from plainText: String, maxChars: Int = 2_000) -> String {
        let trimmed = plainText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > maxChars else { return trimmed }
        return String(trimmed.suffix(maxChars))
    }

    /// Walk the screen **bottom-up** so the freshest status wins (stale “Thinking” in scrollback loses).
    public static func reading(
        title: String?,
        screenTail: String?,
        idleFor: Duration = .seconds(0),
        recentlyWrote: Bool = false
    ) -> AgentStatusReading {
        // Screen body first (bottom-up). OSC title is often sticky/stale — only a fallback.
        if let screenTail {
            let lines = screenTail.split(whereSeparator: \.isNewline).map(String.init)
            for raw in lines.reversed() {
                let line = normalize(raw)
                guard !line.isEmpty else { continue }
                if let hit = matchLine(line) { return hit }
            }
        }
        if let title {
            let line = normalize(title)
            if !line.isEmpty, let hit = matchLine(line) { return hit }
        }

        if idleFor >= .milliseconds(1_500), !recentlyWrote {
            return AgentStatusReading(phase: .waiting, label: "Waiting", detail: "Waiting for you")
        }
        if recentlyWrote {
            return AgentStatusReading(phase: .thinking, label: "Working")
        }
        return AgentStatusReading(phase: .thinking, label: "Thinking")
    }

    /// Back-compat for tests / callers that only want a phase.
    public static func suggestedPhase(title: String?, screenTail: String?) -> AgentLivePhase? {
        let hay = [title, screenTail].compactMap { $0 }.joined()
        guard !hay.isEmpty else { return nil }
        for raw in hay.split(whereSeparator: \.isNewline).reversed() {
            if matchLine(normalize(String(raw))) != nil {
                return reading(title: title, screenTail: screenTail).phase
            }
        }
        return nil
    }

    // MARK: - Line matching (most specific first)

    private static func matchLine(_ line: String) -> AgentStatusReading? {
        // Needs user input / approval — alert the Island.
        if containsAny(line, [
            "waiting for permission", "waiting for approval", "waiting for your",
            "permission", "do you want", "allow this", "allow?",
            "approve", "approval", "confirm", "confirmation",
            "yes / no", "yes/no", "(y/n)", "y/n", "press enter",
            "needs input", "user input", "awaiting input", "awaiting approval",
            "review plan", "accept plan", "reject plan", "approve plan",
            "plan approval", "run this command", "execute this",
            "proceed?", "continue?", "shall i", "may i",
            "trust this", "always allow", "ask every time",
        ]) {
            return AgentStatusReading(
                phase: .waiting,
                label: "Needs you",
                detail: "Waiting for your input",
                wantsAttention: true
            )
        }

        // Soft idle / prompt — no alert.
        if containsAny(line, [
            "your turn", "how can i help", "what would you like", "ready for",
            "awaiting",
        ]) {
            return AgentStatusReading(
                phase: .waiting,
                label: "Waiting",
                detail: "Waiting for you",
                wantsAttention: false
            )
        }

        // Editing / writing files
        if containsAny(line, [
            "editing", "edited", "writing", "wrote ", "write(", "write ",
            "update(", "updating", "creating", "created", "applying", "applied",
            "patching", "saving", "saved", "diff ", "modified", "file written",
            "files written", "edit ", "str_replace", "apply_patch", "search_replace",
            "write_file", "create_file",
        ]) {
            return AgentStatusReading(phase: .writing, label: "Editing", detail: snippet(line))
        }

        // Running tools / commands
        if containsAny(line, [
            "running", "executing", "execute", "bash", "shell", "terminal",
            "command", "tool call", "calling tool", "using tool", "spawn",
        ]) {
            return AgentStatusReading(phase: .thinking, label: "Running", detail: snippet(line))
        }

        // Active work that isn't file edits
        if containsAny(line, [
            "working", "following instructions", "on it", "busy",
            "processing", "generating", "compiling", "reticulat",
            "exploring", "reading", "grepping", "searching", "listing",
            "fetching", "downloading", "indexing",
        ]) {
            return AgentStatusReading(phase: .thinking, label: "Working", detail: snippet(line))
        }

        // Classic thinking / reasoning
        if containsAny(line, [
            "thinking", "reasoning", "planning", "analyzing", "analysing",
            "considering", "pondering", "reflecting",
        ]) {
            return AgentStatusReading(phase: .thinking, label: "Thinking", detail: snippet(line))
        }

        return nil
    }

    private static func normalize(_ raw: String) -> String {
        var s = raw.lowercased()
        let noise = CharacterSet(charactersIn: "·✢✳✶✻✽⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏✦✧•●○◉▶▷▸▹")
        s = String(s.unicodeScalars.filter { !noise.contains($0) })
        s = s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func containsAny(_ line: String, _ cues: [String]) -> Bool {
        cues.contains { line.contains($0) }
    }

    private static func snippet(_ line: String, limit: Int = 28) -> String? {
        var s = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if s.contains("/users/") || s.contains("/home/") || s.contains("~/") {
            return nil
        }
        if s.count > limit {
            let end = s.index(s.startIndex, offsetBy: limit - 1)
            s = String(s[..<end]) + "…"
        }
        return s
    }
}
