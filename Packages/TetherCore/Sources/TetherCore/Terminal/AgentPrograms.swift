import Foundation

/// Coding agents that should take over the phone as a live terminal.
/// Anything else stays in the virtual interpreter or the one-shot shell.
public enum AgentPrograms {
    /// Command names, compared against the program only (the last path piece, lowercased).
    public static let names: Set<String> = [
        "agent", "aider", "amp", "claude", "codex", "copilot", "crush", "cursor", "cursor-agent",
        "gemini", "goose", "grok", "opencode", "pi", "qwen", "sgpt",
    ]

    public static var completionNames: [String] { names.sorted() }

    /// The program to launch, when this line should become a live session.
    /// Shell syntax stays on the one-shot path so a live session cannot be turned into a script.
    public static func programName(in line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.contains(where: { $0.isNewline || ($0.asciiValue ?? 1) < 32 }) { return nil }
        if TerminalSyntax.requiresShell(trimmed) { return nil }
        var tokens = Tokenizer.tokens(trimmed)
        while let first = tokens.first?.lowercased() {
            if first == "sudo" {
                tokens.removeFirst()
                while let flag = tokens.first, flag.hasPrefix("-") { tokens.removeFirst() }
                continue
            }
            if first == "exec" || first == "command" || first == "nohup" {
                tokens.removeFirst()
                continue
            }
            break
        }
        guard let raw = tokens.first else { return nil }
        let base = URL(fileURLWithPath: raw).lastPathComponent.lowercased()
        return names.contains(base) ? base : nil
    }

    /// Login-shell script. The directory is quoted. `line` must already have passed `programName`.
    public static func shellScript(line: String, directory: String) -> String {
        "cd \(shellQuote(directory)) && exec \(line)"
    }

    public static func displayName(_ program: String) -> String {
        switch program.lowercased() {
        case "claude": "Claude Code"
        case "cursor", "cursor-agent", "agent": "Cursor"
        case "codex": "Codex"
        case "aider": "Aider"
        case "gemini": "Gemini"
        case "opencode": "OpenCode"
        case "copilot": "Copilot"
        case "goose": "Goose"
        default: program
        }
    }

    public static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
