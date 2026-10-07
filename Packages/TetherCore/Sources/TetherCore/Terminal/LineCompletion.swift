import Foundation

/// One name Tab can insert. Directories stay open so the next Tab can look inside.
public struct CompletionName: Equatable, Sendable {
    public var name: String
    public var isDirectory: Bool

    public init(name: String, isDirectory: Bool) {
        self.name = name
        self.isDirectory = isDirectory
    }
}

public enum CompletionKind: String, Equatable, Sendable {
    case command
    case file
    case folder
}

/// One row in the suggestion dropdown.
public struct CompletionSuggestion: Equatable, Sendable, Identifiable {
    public var id: String { "\(kind.rawValue):\(display)" }
    public var display: String
    public var insert: String
    public var isDirectory: Bool
    public var kind: CompletionKind

    public init(display: String, insert: String, isDirectory: Bool, kind: CompletionKind) {
        self.display = display
        self.insert = insert
        self.isDirectory = isDirectory
        self.kind = kind
    }
}

/// The token under Tab, and the folder that has to be listed before a name can be chosen.
public struct CompletionRequest: Equatable, Sendable {
    public var start: Int
    public var end: Int
    public var command: Bool
    public var directory: String
    public var head: String
    public var prefix: String
    public var quote: Character?
    public var quoteOpen: Bool

    /// Command words are completed from the command list. Anything after that is a path.
    public var listsFiles: Bool { !(command && head.isEmpty) }
}

public struct CompletionOutcome: Equatable, Sendable {
    public var line: String
    public var hint: String
    /// Remaining matches when Tab could not pick a single name. Empty when the line was uniquely filled.
    public var suggestions: [CompletionSuggestion]

    public init(line: String, hint: String, suggestions: [CompletionSuggestion] = []) {
        self.line = line
        self.hint = hint
        self.suggestions = suggestions
    }
}

/// Tab completion for the virtual shell. Matching is case-insensitive, and a path is
/// completed against the folder it names rather than whatever the Files tab is showing.
public enum LineCompletion {
    public static func request(line: String, cwd: String) -> CompletionRequest {
        let piece = span(in: line)
        let parts = pathParts(piece.token)
        let directory = directory(head: parts.head, cwd: cwd)
        return CompletionRequest(
            start: offset(piece.start, in: line),
            end: offset(piece.end, in: line),
            command: piece.command,
            directory: directory,
            head: parts.head,
            prefix: parts.prefix,
            quote: piece.quote,
            quoteOpen: piece.quoteOpen
        )
    }

    /// Candidates for the live suggestion menu (no line rewrite).
    public static func suggestions(
        request: CompletionRequest,
        names: [CompletionName],
        commands: [String]
    ) -> [CompletionSuggestion] {
        if request.prefix == "~", request.head.isEmpty, !request.command {
            return [
                CompletionSuggestion(display: "~/", insert: "~/", isDirectory: true, kind: .folder),
            ]
        }
        if request.prefix.hasPrefix("-"), request.head.isEmpty, !request.command {
            return []
        }
        return pool(request: request, names: names, commands: commands).map {
            suggestion(from: $0, asCommand: !request.listsFiles)
        }
    }

    /// Inserts one picked suggestion into the line (same quoting rules as Tab).
    public static func apply(
        line: String,
        request: CompletionRequest,
        suggestion: CompletionSuggestion
    ) -> String {
        if suggestion.kind == .command {
            let raw = suggestion.insert
            let name = raw.hasSuffix(" ") ? String(raw.dropLast()) : raw
            let trailing = raw.hasSuffix(" ") ? " " : ""
            let replacement = render(
                head: "",
                name: name,
                suffix: "",
                trailing: trailing,
                quote: request.quote,
                close: true
            )
            return replace(line, request: request, with: replacement)
        }
        let suffix = suggestion.isDirectory ? "/" : ""
        let trailing = suggestion.isDirectory ? "" : " "
        let replacement = render(
            head: request.head,
            name: suggestion.display,
            suffix: suffix,
            trailing: trailing,
            quote: request.quote,
            close: true
        )
        return replace(line, request: request, with: replacement)
    }

    public static func complete(
        line: String,
        request: CompletionRequest,
        names: [CompletionName],
        commands: [String]
    ) -> CompletionOutcome {
        if request.prefix == "~", request.head.isEmpty, !request.command {
            let replacement = render(head: "", name: "~/", suffix: "", trailing: "", quote: request.quote, close: false)
            return CompletionOutcome(line: replace(line, request: request, with: replacement), hint: "")
        }
        if request.prefix.hasPrefix("-"), request.head.isEmpty, !request.command {
            return CompletionOutcome(line: line, hint: "")
        }

        let matches = pool(request: request, names: names, commands: commands)
        guard !matches.isEmpty else {
            let hint = request.prefix.isEmpty ? "" : (request.listsFiles ? "No matching file or folder" : "No matching command")
            return CompletionOutcome(line: line, hint: hint)
        }
        if matches.count == 1 {
            let only = matches[0]
            let suffix = only.isDirectory ? "/" : ""
            let trailing = only.isDirectory ? "" : " "
            let replacement = render(
                head: request.head,
                name: only.name,
                suffix: suffix,
                trailing: trailing,
                quote: request.quote,
                close: true
            )
            return CompletionOutcome(line: replace(line, request: request, with: replacement), hint: "")
        }

        let shared = sharedPrefix(matches.map(\.name))
        let grew = shared.count > request.prefix.count
        let corrected = shared.count == request.prefix.count && shared != request.prefix
        let candidates = matches.map { suggestion(from: $0, asCommand: !request.listsFiles) }
        // Always return every match; the phone UI scrolls the dropdown. Hint only nudges when Tab was used.
        let countHint = candidates.count > 8 ? "\(candidates.count) matches · scroll the list above" : ""
        guard grew || corrected else {
            return CompletionOutcome(line: line, hint: countHint, suggestions: candidates)
        }
        let replacement = render(
            head: request.head,
            name: shared,
            suffix: "",
            trailing: "",
            quote: request.quote,
            close: false
        )
        return CompletionOutcome(
            line: replace(line, request: request, with: replacement),
            hint: countHint,
            suggestions: candidates
        )
    }

    private static func pool(
        request: CompletionRequest,
        names: [CompletionName],
        commands: [String]
    ) -> [CompletionName] {
        let hidden = request.prefix.hasPrefix(".")
        if request.listsFiles {
            return names
                .filter { matches(request.prefix, name: $0.name, hidden: hidden) }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
        return commands
            .filter { matches(request.prefix, name: $0, hidden: true) }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .map { CompletionName(name: $0, isDirectory: false) }
    }

    private static func suggestion(from name: CompletionName, asCommand: Bool) -> CompletionSuggestion {
        if name.isDirectory {
            return CompletionSuggestion(
                display: name.name,
                insert: name.name + "/",
                isDirectory: true,
                kind: .folder
            )
        }
        if asCommand {
            if let help = CommandCatalog.entry(named: name.name) {
                return CompletionSuggestion(
                    display: name.name,
                    insert: help.insertPrefix,
                    isDirectory: false,
                    kind: .command
                )
            }
            return CompletionSuggestion(
                display: name.name,
                insert: name.name,
                isDirectory: false,
                kind: .command
            )
        }
        return CompletionSuggestion(
            display: name.name,
            insert: name.name,
            isDirectory: false,
            kind: .file
        )
    }

    private static func pathParts(_ token: String) -> (head: String, prefix: String) {
        guard let slash = token.lastIndex(of: "/") else { return ("", token) }
        let prefix = String(token[token.index(after: slash)...])
        return (String(token[...slash]), prefix)
    }

    private static func directory(head: String, cwd: String) -> String {
        let base = (try? VirtualPath.parse(cwd)) ?? .root
        if head.isEmpty { return base.string }
        var probe = head
        if probe.hasSuffix("/") { probe.removeLast() }
        if probe.isEmpty { return "/" }
        let expanded = expandTilde(probe)
        return (try? VirtualPath.resolve(expanded, from: base))?.string ?? base.string
    }

    /// The virtual shell maps `~` to `/`, the top of the shared folders.
    private static func expandTilde(_ path: String) -> String {
        if path == "~" { return "/" }
        if path.hasPrefix("~/") { return "/" + path.dropFirst(2) }
        return path
    }

    private static func matches(_ prefix: String, name: String, hidden: Bool) -> Bool {
        if !hidden, name.hasPrefix(".") { return false }
        if prefix.isEmpty { return true }
        return name.range(of: prefix, options: [.anchored, .caseInsensitive, .diacriticInsensitive]) != nil
    }

    private static func sharedPrefix(_ names: [String]) -> String {
        guard var limit = names.first else { return "" }
        for name in names.dropFirst() {
            var kept = ""
            for (left, right) in zip(limit, name) {
                guard String(left).compare(String(right), options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame else { break }
                kept.append(left)
            }
            limit = kept
            if limit.isEmpty { break }
        }
        return limit
    }

    private static func render(
        head: String,
        name: String,
        suffix: String,
        trailing: String,
        quote: Character?,
        close: Bool
    ) -> String {
        let core = head + name + suffix
        let finish = close || !suffix.isEmpty || !trailing.isEmpty
        if let quote {
            return quoted(core, mark: quote, close: finish) + trailing
        }
        if core.contains(where: { $0.isWhitespace || "\"'\\".contains($0) }) {
            return quoted(core, mark: "\"", close: finish) + trailing
        }
        return core + trailing
    }

    private static func quoted(_ text: String, mark: Character, close: Bool) -> String {
        let body: String
        if mark == "'" {
            body = text.replacingOccurrences(of: "'", with: "'\\''")
        } else {
            body = text
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
        }
        let open = String(mark)
        return close ? open + body + open : open + body
    }

    private static func replace(_ line: String, request: CompletionRequest, with text: String) -> String {
        guard request.start >= 0, request.end >= request.start, request.end <= line.count else { return line }
        let start = line.index(line.startIndex, offsetBy: request.start)
        let end = line.index(line.startIndex, offsetBy: request.end)
        var copy = line
        copy.replaceSubrange(start..<end, with: text)
        return copy
    }

    private static func offset(_ index: String.Index, in line: String) -> Int {
        line.distance(from: line.startIndex, to: index)
    }

    private static func span(in line: String) -> (start: String.Index, end: String.Index, token: String, quote: Character?, quoteOpen: Bool, command: Bool) {
        var start = line.startIndex
        var token = ""
        var quote: Character?
        var quoteOpen = false
        var escaping = false
        var command = true
        var inToken = false
        var index = line.startIndex

        func begin(_ at: String.Index) {
            if !inToken {
                start = at
                token = ""
                quote = nil
                quoteOpen = false
                inToken = true
            }
        }

        while index < line.endIndex {
            let character = line[index]
            if escaping {
                begin(index)
                token.append(character)
                escaping = false
                index = line.index(after: index)
                continue
            }
            if character == "\\", quote != "'" {
                begin(index)
                escaping = true
                index = line.index(after: index)
                continue
            }
            if let active = quote {
                if character == active {
                    quoteOpen = false
                    index = line.index(after: index)
                    continue
                }
                token.append(character)
                index = line.index(after: index)
                continue
            }
            if character == "\"" || character == "'" {
                begin(index)
                quote = character
                quoteOpen = true
                index = line.index(after: index)
                continue
            }
            if character.isWhitespace {
                if inToken {
                    command = false
                    inToken = false
                    token = ""
                    quote = nil
                    quoteOpen = false
                }
                index = line.index(after: index)
                start = index
                continue
            }
            begin(index)
            token.append(character)
            index = line.index(after: index)
        }
        return (start, line.endIndex, inToken ? token : "", inToken ? quote : nil, inToken && quoteOpen, command)
    }
}
