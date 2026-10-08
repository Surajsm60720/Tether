import Foundation

/// Coding agents that should take over the phone as a live terminal.
/// Anything else stays in the virtual interpreter or the one-shot shell.
public enum AgentPrograms {
    /// Bare command names only (lowercased). Paths like `./claude` are rejected.
    public static let names: Set<String> = [
        "agent", "aider", "amp", "claude", "codex", "copilot", "crush", "cursor", "cursor-agent",
        "gemini", "goose", "grok", "opencode", "pi", "qwen", "sgpt",
    ]

    public static var completionNames: [String] { names.sorted() }

    /// The program to launch, when this line should become a live session.
    /// Shell syntax stays on the one-shot path so a live session cannot be turned into a script.
    /// Path-shaped tokens (`./claude`, `/tmp/claude`, `~/bin/claude`) are rejected so a planted
    /// binary in a share cannot become a live PTY.
    public static func programName(in line: String) -> String? {
        launchParts(in: line)?.program
    }

    /// Safe argv pieces for a live agent: allowlisted bare name plus remaining arguments.
    public static func launchParts(in line: String) -> (program: String, arguments: [String])? {
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
        // Bare names only — no absolute, relative, or home-relative paths.
        if raw.contains("/") || raw.contains("\\") || raw.hasPrefix("~") || raw == "." || raw == ".." {
            return nil
        }
        let base = raw.lowercased()
        guard names.contains(base) else { return nil }
        return (base, Array(tokens.dropFirst()))
    }

    /// Login-shell script built from a sanitized allowlisted command (never the raw phone line).
    public static func shellScript(line: String, directory: String) -> String? {
        guard let parts = launchParts(in: line) else { return nil }
        var command = parts.program
        for argument in parts.arguments {
            command += " " + shellQuote(argument)
        }
        return "cd \(shellQuote(directory)) && exec \(command)"
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
