import Foundation

/// One row in the interactive help picker and the printed `help` catalog.
public struct CommandHelp: Equatable, Sendable, Identifiable {
    public var id: String { name }
    public var name: String
    /// Typed form with placeholders and flags, e.g. `ls [-l] [-a] [path]`.
    public var syntax: String
    /// Short description shown under the syntax.
    public var usage: String
    /// Text inserted into the draft when the row is chosen (often `name` plus a trailing space).
    public var insertPrefix: String

    public init(name: String, syntax: String, usage: String, insertPrefix: String) {
        self.name = name
        self.syntax = syntax
        self.usage = usage
        self.insertPrefix = insertPrefix
    }
}

/// Shared command catalog for the virtual shell help UI and coverage tests.
public enum CommandCatalog {
    /// Built-in virtual commands (not live agents). Keep syntax aligned with `TerminalEngine.help`.
    public static let entries: [CommandHelp] = [
        CommandHelp(name: "help", syntax: "help", usage: "show this list", insertPrefix: "help"),
        CommandHelp(name: "pwd", syntax: "pwd", usage: "print the working folder", insertPrefix: "pwd"),
        CommandHelp(name: "cd", syntax: "cd <dir>", usage: "change folder (~ is /)", insertPrefix: "cd "),
        CommandHelp(name: "ls", syntax: "ls [-l] [-a] [path]", usage: "list a folder", insertPrefix: "ls "),
        CommandHelp(name: "cat", syntax: "cat <file>", usage: "print a text file (up to 1 MB)", insertPrefix: "cat "),
        CommandHelp(name: "head", syntax: "head -n N <file>", usage: "first lines", insertPrefix: "head -n "),
        CommandHelp(name: "tail", syntax: "tail -n N <file>", usage: "last lines", insertPrefix: "tail -n "),
        CommandHelp(name: "stat", syntax: "stat <path>", usage: "details", insertPrefix: "stat "),
        CommandHelp(name: "du", syntax: "du [-h] [path]", usage: "size summary", insertPrefix: "du "),
        CommandHelp(name: "find", syntax: "find <name> [path]", usage: "search by name", insertPrefix: "find "),
        CommandHelp(name: "tree", syntax: "tree [-L N] [path]", usage: "folder tree", insertPrefix: "tree "),
        CommandHelp(name: "mkdir", syntax: "mkdir [-p] <dir>", usage: "create a folder", insertPrefix: "mkdir "),
        CommandHelp(name: "rm", syntax: "rm [-r] <path>", usage: "remove a file or folder", insertPrefix: "rm "),
        CommandHelp(name: "rmdir", syntax: "rmdir <dir>", usage: "remove an empty folder", insertPrefix: "rmdir "),
        CommandHelp(name: "cp", syntax: "cp <from> <to>", usage: "copy inside a shared folder", insertPrefix: "cp "),
        CommandHelp(name: "mv", syntax: "mv <from> <to>", usage: "move or rename", insertPrefix: "mv "),
        CommandHelp(name: "touch", syntax: "touch <file>", usage: "create an empty file", insertPrefix: "touch "),
        CommandHelp(name: "echo", syntax: "echo <text>", usage: "print text", insertPrefix: "echo "),
        CommandHelp(name: "grep", syntax: "grep <text> <file>", usage: "search a text file", insertPrefix: "grep "),
        CommandHelp(name: "wc", syntax: "wc <file>", usage: "line, word, and byte counts", insertPrefix: "wc "),
        CommandHelp(name: "date", syntax: "date", usage: "current time", insertPrefix: "date"),
        CommandHelp(name: "whoami", syntax: "whoami", usage: "Mac account and this iPhone", insertPrefix: "whoami"),
        CommandHelp(name: "status", syntax: "status", usage: "host, folder, and uptime", insertPrefix: "status"),
        CommandHelp(name: "fetch", syntax: "fetch", usage: "Mac summary (neofetch, fastfetch)", insertPrefix: "fetch"),
        CommandHelp(name: "neofetch", syntax: "neofetch", usage: "Mac summary", insertPrefix: "neofetch"),
        CommandHelp(name: "fastfetch", syntax: "fastfetch", usage: "Mac summary", insertPrefix: "fastfetch"),
        CommandHelp(name: "htop", syntax: "htop", usage: "live CPU and memory", insertPrefix: "htop"),
        CommandHelp(name: "btop", syntax: "btop", usage: "live CPU and memory", insertPrefix: "btop"),
        CommandHelp(name: "monitor", syntax: "monitor", usage: "live CPU and memory", insertPrefix: "monitor"),
        CommandHelp(name: "open", syntax: "open <file>", usage: "preview on this iPhone", insertPrefix: "open "),
        CommandHelp(name: "preview", syntax: "preview <file>", usage: "preview on this iPhone", insertPrefix: "preview "),
        CommandHelp(name: "get", syntax: "get <file>", usage: "download to this iPhone", insertPrefix: "get "),
        CommandHelp(name: "put", syntax: "put", usage: "upload into this folder", insertPrefix: "put"),
        CommandHelp(name: "clear", syntax: "clear", usage: "clear the screen", insertPrefix: "clear"),
        CommandHelp(name: "exit", syntax: "exit", usage: "leave the terminal", insertPrefix: "exit"),
    ]

    /// Live agent launch names, shown after the built-ins in the help picker.
    public static var agentEntries: [CommandHelp] {
        AgentPrograms.completionNames.map { name in
            CommandHelp(
                name: name,
                syntax: name,
                usage: "\(AgentPrograms.displayName(name)), live on this iPhone",
                insertPrefix: name
            )
        }
    }

    public static var all: [CommandHelp] { entries + agentEntries }

    public static func entry(named name: String) -> CommandHelp? {
        all.first { $0.name == name }
    }

    /// Printed `help` body (syntax column + description), plus the usual footer notes.
    public static func printedHelp() -> String {
        let rows = all.map { ($0.syntax, $0.usage) }
        let width = rows.map(\.0.count).max() ?? 20
        var lines = rows.map { syntax, usage in
            let pad = String(repeating: " ", count: max(2, width + 2 - syntax.count))
            return syntax + pad + usage
        }
        lines.append("")
        lines.append("Other Mac commands, including pipes, run on your Mac.")
        lines.append("claude, agent, and codex open the real program, with this iPhone as the screen.")
        lines.append("")
        return lines.joined(separator: "\n") + "\n"
    }
}
