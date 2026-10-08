import Foundation

public enum Tokenizer {
    /// Splits a command line on whitespace, honoring quotes and backslash escapes.
    public static func tokens(_ line: String) -> [String] {
        var result: [String] = []
        var current = ""
        var quote: Character?
        var escaping = false
        for character in line {
            if escaping {
                current.append(character)
                escaping = false
                continue
            }
            if character == "\\" {
                escaping = true
                continue
            }
            if let active = quote {
                if character == active {
                    quote = nil
                } else {
                    current.append(character)
                }
                continue
            }
            if character == "\"" || character == "'" {
                quote = character
                continue
            }
            if character.isWhitespace {
                if !current.isEmpty {
                    result.append(current)
                    current = ""
                }
                continue
            }
            current.append(character)
        }
        if !current.isEmpty { result.append(current) }
        return result
    }
}

/// Virtual shell. It never spawns a process and never leaves the shared folders.
public struct TerminalEngine: Sendable {
    public init() {}

    public func execute(line raw: String, cwd: String, files: any FileProvider, context: TerminalContext? = nil) async -> TerminalResult {
        let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let directory = (try? VirtualPath.parse(cwd)) ?? .root
        guard !line.isEmpty else {
            return TerminalResult(cwd: directory.string)
        }
        let tokens = Tokenizer.tokens(line)
        guard let command = tokens.first else {
            return TerminalResult(cwd: directory.string)
        }
        let args = Array(tokens.dropFirst())
        let result: TerminalResult
        switch command {
        case "help": result = help(cwd: directory)
        case "pwd": result = TerminalResult(stdout: directory.string + "\n", cwd: directory.string)
        case "cd": result = await changeDirectory(args, cwd: directory, files: files)
        case "ls": result = await list(args, cwd: directory, files: files)
        case "cat": result = await cat(args, cwd: directory, files: files)
        case "head": result = await headTail(args, cwd: directory, files: files, tail: false)
        case "tail": result = await headTail(args, cwd: directory, files: files, tail: true)
        case "stat": result = await stat(args, cwd: directory, files: files)
        case "du": result = await du(args, cwd: directory, files: files)
        case "find": result = await find(args, cwd: directory, files: files)
        case "tree": result = await tree(args, cwd: directory, files: files)
        case "mkdir": result = await makeDirectory(args, cwd: directory, files: files)
        case "rmdir", "rm": result = await remove(args, cwd: directory, files: files, directoryOnly: command == "rmdir")
        case "cp": result = await transfer(args, cwd: directory, files: files, move: false)
        case "mv": result = await transfer(args, cwd: directory, files: files, move: true)
        case "touch": result = await touch(args, cwd: directory, files: files)
        case "echo": result = TerminalResult(stdout: args.joined(separator: " ") + "\n", cwd: directory.string)
        case "grep": result = await grep(args, cwd: directory, files: files)
        case "wc": result = await wordCount(args, cwd: directory, files: files)
        case "date": result = TerminalResult(stdout: formatDate(Date()) + "\n", cwd: directory.string)
        case "whoami": result = whoami(cwd: directory, context: context)
        case "status": result = status(cwd: directory, context: context)
        case "fetch", "neofetch", "fastfetch": result = fetch(cwd: directory, context: context)
        case "monitor", "htop", "btop":
            result = TerminalResult(cwd: directory.string, action: TerminalAction(type: "monitor"))
        case "open", "preview": result = await actionCommand(command, args: args, cwd: directory, files: files)
        case "get": result = await actionCommand("get", args: args, cwd: directory, files: files)
        case "put": result = await put(cwd: directory, files: files)
        case "clear": result = TerminalResult(cwd: directory.string, action: TerminalAction(type: "clear"))
        case "exit": result = TerminalResult(cwd: directory.string, action: TerminalAction(type: "exit"))
        default:
            result = TerminalResult(
                stdout: "tether: command not found: \(command). Type 'help'.\n",
                cwd: directory.string,
                exit: 127
            )
        }
        return clip(result)
    }

    public static let commandNames = [
        "btop", "cat", "cd", "clear", "cp", "date", "du", "echo", "exit", "fastfetch", "fetch", "find", "get", "grep",
        "head", "help", "htop", "ls", "mkdir", "monitor", "mv", "neofetch", "open", "preview", "put", "pwd", "rm",
        "rmdir", "stat", "status", "tail", "touch", "tree", "wc", "whoami",
    ] + AgentPrograms.completionNames

    private func help(cwd: VirtualPath) -> TerminalResult {
        TerminalResult(stdout: CommandCatalog.printedHelp(), cwd: cwd.string)
    }

    private func whoami(cwd: VirtualPath, context: TerminalContext?) -> TerminalResult {
        guard let context else { return fail("whoami: connect to a Mac first.", cwd: cwd) }
        return TerminalResult(stdout: SystemText.whoami(user: context.user, host: context.host, device: context.device), cwd: cwd.string)
    }

    private func status(cwd: VirtualPath, context: TerminalContext?) -> TerminalResult {
        guard let context else { return fail("status: connect to a Mac first.", cwd: cwd) }
        return TerminalResult(
            stdout: SystemText.status(profile: context.profile, folder: cwd.string, device: context.device),
            cwd: cwd.string
        )
    }

    private func fetch(cwd: VirtualPath, context: TerminalContext?) -> TerminalResult {
        guard let context else { return fail("fetch: connect to a Mac first.", cwd: cwd) }
        let text = SystemText.fetch(context.profile)
        // Client opens/refreshes a pinned fetch slot (v2.4) using stdout.
        return TerminalResult(stdout: text, cwd: cwd.string, action: TerminalAction(type: "fetch"))
    }

    private func changeDirectory(_ args: [String], cwd: VirtualPath, files: any FileProvider) async -> TerminalResult {
        let argument = args.first ?? "/"
        guard let path = try? VirtualPath.resolve(argument, from: cwd) else {
            return fail("cd: invalid path", cwd: cwd)
        }
        if path.isRoot { return TerminalResult(cwd: "/") }
        do {
            let entry = try await files.stat(path: path)
            guard entry.kind != .file else { return fail("cd: not a folder: \(path.string)", cwd: cwd) }
            return TerminalResult(cwd: path.string)
        } catch {
            return fail("cd: no such folder: \(path.string)", cwd: cwd)
        }
    }

    private func list(_ args: [String], cwd: VirtualPath, files: any FileProvider) async -> TerminalResult {
        var long = false
        var all = false
        var paths: [String] = []
        var index = 0
        while index < args.count {
            let arg = args[index]
            if arg.hasPrefix("-") && arg != "-" {
                if arg.contains("l") { long = true }
                if arg.contains("a") { all = true }
            } else {
                paths.append(arg)
            }
            index += 1
        }
        let target = paths.first ?? cwd.string
        guard let path = try? VirtualPath.resolve(target, from: cwd) else {
            return fail("ls: invalid path", cwd: cwd)
        }
        do {
            let entries = try await files.list(path: path, offset: 0, limit: TetherCoreInfo.maxListEntries, includeHidden: all)
            if entries.isEmpty { return TerminalResult(cwd: cwd.string) }
            let lines = entries.map { entry -> String in
                let name = entry.kind == .dir ? entry.name + "/" : entry.name
                if !long { return name }
                let kind = entry.kind == .dir ? "d" : (entry.kind == .link ? "l" : "-")
                let size = entry.kind == .dir && entry.size == 0 ? String(entry.childCount ?? 0) : formatBytes(entry.size)
                return "\(kind)  \(size)\t\(formatDate(entry.modified))\t\(name)"
            }
            return TerminalResult(stdout: lines.joined(separator: "\n") + "\n", cwd: cwd.string)
        } catch {
            return fail("ls: \(message(error))", cwd: cwd)
        }
    }

    private func cat(_ args: [String], cwd: VirtualPath, files: any FileProvider) async -> TerminalResult {
        guard let target = args.first else { return fail("cat: missing file", cwd: cwd) }
        guard let path = try? VirtualPath.resolve(target, from: cwd) else { return fail("cat: invalid path", cwd: cwd) }
        do {
            let text = try await readText(path: path, files: files, limit: 1_048_576)
            return TerminalResult(stdout: text.hasSuffix("\n") || text.isEmpty ? text : text + "\n", cwd: cwd.string)
        } catch {
            return fail("cat: \(message(error))", cwd: cwd)
        }
    }

    private func headTail(_ args: [String], cwd: VirtualPath, files: any FileProvider, tail: Bool) async -> TerminalResult {
        var count = 10
        var file: String?
        var index = 0
        while index < args.count {
            let arg = args[index]
            if arg == "-n", index + 1 < args.count {
                count = Int(args[index + 1]) ?? 10
                index += 2
                continue
            }
            if arg.hasPrefix("-"), let value = Int(arg.dropFirst()) {
                count = value
            } else if !arg.hasPrefix("-") {
                file = arg
            }
            index += 1
        }
        count = min(max(count, 0), 1000)
        guard let file else { return fail(tail ? "tail: missing file" : "head: missing file", cwd: cwd) }
        guard let path = try? VirtualPath.resolve(file, from: cwd) else { return fail("invalid path", cwd: cwd) }
        do {
            let text = try await readText(path: path, files: files, limit: 1_048_576)
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            let slice = tail ? Array(lines.suffix(count)) : Array(lines.prefix(count))
            let output = slice.joined(separator: "\n")
            return TerminalResult(stdout: output.isEmpty ? "" : output + "\n", cwd: cwd.string)
        } catch {
            return fail("\(tail ? "tail" : "head"): \(message(error))", cwd: cwd)
        }
    }

    private func stat(_ args: [String], cwd: VirtualPath, files: any FileProvider) async -> TerminalResult {
        guard let target = args.first else { return fail("stat: missing path", cwd: cwd) }
        guard let path = try? VirtualPath.resolve(target, from: cwd) else { return fail("stat: invalid path", cwd: cwd) }
        do {
            let entry = try await files.stat(path: path)
            let kind = entry.kind == .dir ? "folder" : (entry.kind == .link ? "link" : "file")
            let text = """
            \(path.string)
              kind: \(kind)
              size: \(formatBytes(entry.size))
              modified: \(formatDate(entry.modified))

            """
            return TerminalResult(stdout: text, cwd: cwd.string)
        } catch {
            return fail("stat: \(message(error))", cwd: cwd)
        }
    }

    private func du(_ args: [String], cwd: VirtualPath, files: any FileProvider) async -> TerminalResult {
        let human = args.contains("-h")
        let target = args.first { !$0.hasPrefix("-") } ?? cwd.string
        guard let path = try? VirtualPath.resolve(target, from: cwd) else { return fail("du: invalid path", cwd: cwd) }
        var visited = 0
        let started = Date()
        do {
            let size = try await walkSize(path: path, files: files, depth: 0, visited: &visited, started: started)
            let shown = human ? formatBytes(size) : "\(size)"
            return TerminalResult(stdout: "\(shown)\t\(path.string)\n", cwd: cwd.string)
        } catch {
            return fail("du: \(message(error))", cwd: cwd)
        }
    }

    private func find(_ args: [String], cwd: VirtualPath, files: any FileProvider) async -> TerminalResult {
        guard let pattern = args.first else { return fail("find: missing name", cwd: cwd) }
        let rootArg = args.dropFirst().first ?? cwd.string
        guard let root = try? VirtualPath.resolve(rootArg, from: cwd) else { return fail("find: invalid path", cwd: cwd) }
        do {
            let provider = files
            let hits = try await FileSearch.find(
                pattern: pattern,
                root: root,
                match: .wildcard,
                includeDirectories: false,
                list: { path in
                    try await provider.list(path: path, offset: 0, limit: 5000, includeHidden: false)
                }
            )
            let text = hits.isEmpty ? "" : hits.map(\.path).joined(separator: "\n") + "\n"
            return TerminalResult(stdout: text, cwd: cwd.string)
        } catch {
            return fail("find: \(message(error))", cwd: cwd)
        }
    }

    private func tree(_ args: [String], cwd: VirtualPath, files: any FileProvider) async -> TerminalResult {
        var depthLimit = 2
        var pathArg: String?
        var index = 0
        while index < args.count {
            if args[index] == "-L", index + 1 < args.count {
                depthLimit = min(max(Int(args[index + 1]) ?? 2, 0), 6)
                index += 2
                continue
            }
            if !args[index].hasPrefix("-") { pathArg = args[index] }
            index += 1
        }
        let target = pathArg ?? cwd.string
        guard let path = try? VirtualPath.resolve(target, from: cwd) else { return fail("tree: invalid path", cwd: cwd) }
        var lines = [path.string]
        do {
            try await walkTree(path: path, files: files, prefix: "", depth: 0, limit: depthLimit, lines: &lines)
            return TerminalResult(stdout: lines.joined(separator: "\n") + "\n", cwd: cwd.string)
        } catch {
            return fail("tree: \(message(error))", cwd: cwd)
        }
    }

    private func actionCommand(_ type: String, args: [String], cwd: VirtualPath, files: any FileProvider) async -> TerminalResult {
        guard let target = args.first else { return fail("\(type): missing file", cwd: cwd) }
        guard let path = try? VirtualPath.resolve(target, from: cwd) else { return fail("\(type): invalid path", cwd: cwd) }
        do {
            let entry = try await files.stat(path: path)
            guard entry.kind == .file || entry.kind == .link else {
                return fail("\(type): not a file: \(path.string)", cwd: cwd)
            }
            return TerminalResult(cwd: cwd.string, action: TerminalAction(type: type == "preview" ? "open" : type, path: path.string))
        } catch {
            return fail("\(type): \(message(error))", cwd: cwd)
        }
    }

    private func put(cwd: VirtualPath, files: any FileProvider) async -> TerminalResult {
        if cwd.isRoot {
            return fail("put: choose a folder that allows uploads", cwd: cwd)
        }
        let shares = await files.shares()
        guard let share = shares.first(where: { $0.name == cwd.components.first }), share.writable else {
            return fail("This folder is read-only. Choose a folder that allows uploads.", cwd: cwd)
        }
        return TerminalResult(cwd: cwd.string, action: TerminalAction(type: "put", path: cwd.string))
    }

    private func readText(path: VirtualPath, files: any FileProvider, limit: Int) async throws -> String {
        let entry = try await files.stat(path: path)
        guard entry.kind == .file || entry.kind == .link else {
            throw ProtocolFailure(code: .badRequest, message: "that item is a folder")
        }
        if entry.size > UInt64(limit) {
            throw ProtocolFailure(code: .tooLarge, message: "file is larger than 1 MB")
        }
        var data = Data()
        var offset: UInt64 = 0
        while data.count < limit {
            let chunk = try await files.read(path: path, offset: offset, length: TetherCoreInfo.chunkSize)
            data.append(chunk.data)
            if chunk.data.contains(0) {
                throw ProtocolFailure(code: .badRequest, message: "binary file")
            }
            offset += UInt64(chunk.data.count)
            if chunk.eof || chunk.data.isEmpty { break }
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw ProtocolFailure(code: .badRequest, message: "binary file")
        }
        return text
    }

    private func walkSize(path: VirtualPath, files: any FileProvider, depth: Int, visited: inout Int, started: Date) async throws -> UInt64 {
        if depth > 8 || visited > 4000 || Date().timeIntervalSince(started) > 5 { return 0 }
        visited += 1
        let entry = try await files.stat(path: path)
        if entry.kind == .file || entry.kind == .link { return entry.size }
        let children = try await files.list(path: path, offset: 0, limit: 5000, includeHidden: true)
        var total: UInt64 = 0
        for child in children where !child.name.hasPrefix(".tether-upload-") {
            total += try await walkSize(path: path.appending(child.name), files: files, depth: depth + 1, visited: &visited, started: started)
        }
        return total
    }

    private func walkTree(path: VirtualPath, files: any FileProvider, prefix: String, depth: Int, limit: Int, lines: inout [String]) async throws {
        guard depth < limit, lines.count < 2000 else { return }
        let children = try await files.list(path: path, offset: 0, limit: 1000, includeHidden: false)
        for (index, child) in children.enumerated() {
            let last = index == children.count - 1
            let branch = last ? "└── " : "├── "
            let name = child.kind == .dir ? child.name + "/" : child.name
            lines.append(prefix + branch + name)
            if child.kind == .dir {
                let next = prefix + (last ? "    " : "│   ")
                try await walkTree(path: path.appending(child.name), files: files, prefix: next, depth: depth + 1, limit: limit, lines: &lines)
            }
        }
    }

    private func makeDirectory(_ args: [String], cwd: VirtualPath, files: any FileProvider) async -> TerminalResult {
        let parents = args.contains("-p")
        guard let target = args.last, !target.hasPrefix("-") else { return fail("mkdir: missing folder", cwd: cwd) }
        guard let path = try? VirtualPath.resolve(target, from: cwd), path.components.count > 1 else {
            return fail("mkdir: invalid path", cwd: cwd)
        }
        do {
            try await files.makeDirectory(path: path, createParents: parents)
            return TerminalResult(cwd: cwd.string)
        } catch {
            return fail("mkdir: \(message(error))", cwd: cwd)
        }
    }

    private func remove(_ args: [String], cwd: VirtualPath, files: any FileProvider, directoryOnly: Bool) async -> TerminalResult {
        let recursive = args.contains { $0.hasPrefix("-") && $0.contains("r") }
        guard let target = args.last, !target.hasPrefix("-") else { return fail("rm: missing path", cwd: cwd) }
        guard let path = try? VirtualPath.resolve(target, from: cwd), path.components.count > 1 else {
            return fail("rm: invalid path", cwd: cwd)
        }
        do {
            if directoryOnly {
                let entry = try await files.stat(path: path)
                guard entry.kind == .dir else { return fail("rmdir: not a folder", cwd: cwd) }
            }
            try await files.remove(path: path, recursive: directoryOnly ? false : recursive)
            return TerminalResult(cwd: cwd.string)
        } catch {
            return fail("rm: \(message(error))", cwd: cwd)
        }
    }

    private func transfer(_ args: [String], cwd: VirtualPath, files: any FileProvider, move: Bool) async -> TerminalResult {
        let paths = args.filter { !$0.hasPrefix("-") }
        guard paths.count >= 2, let sourceArg = paths.first, let destArg = paths.last else {
            return fail(move ? "mv: need a source and a destination" : "cp: need a source and a destination", cwd: cwd)
        }
        guard let source = try? VirtualPath.resolve(sourceArg, from: cwd),
              let destination = try? VirtualPath.resolve(destArg, from: cwd),
              source.components.count > 1, destination.components.count > 1 else {
            return fail("invalid path", cwd: cwd)
        }
        do {
            if move {
                try await files.moveItem(from: source, to: destination)
            } else {
                try await files.copyItem(from: source, to: destination)
            }
            return TerminalResult(cwd: cwd.string)
        } catch {
            return fail("\(move ? "mv" : "cp"): \(message(error))", cwd: cwd)
        }
    }

    private func touch(_ args: [String], cwd: VirtualPath, files: any FileProvider) async -> TerminalResult {
        guard let target = args.last, !target.hasPrefix("-") else { return fail("touch: missing file", cwd: cwd) }
        guard let path = try? VirtualPath.resolve(target, from: cwd), path.components.count > 1 else {
            return fail("touch: invalid path", cwd: cwd)
        }
        do {
            if (try? await files.stat(path: path)) == nil {
                try await files.writeWholeFile(path: path, data: Data(), append: false)
            }
            return TerminalResult(cwd: cwd.string)
        } catch {
            return fail("touch: \(message(error))", cwd: cwd)
        }
    }

    private func grep(_ args: [String], cwd: VirtualPath, files: any FileProvider) async -> TerminalResult {
        let ignoreCase = args.contains { $0 == "-i" }
        let positional = args.filter { !$0.hasPrefix("-") }
        guard positional.count >= 2, let pattern = positional.first, let file = positional.last else {
            return fail("grep: usage is grep <text> <file>", cwd: cwd)
        }
        guard let path = try? VirtualPath.resolve(file, from: cwd) else { return fail("grep: invalid path", cwd: cwd) }
        do {
            let text = try await readText(path: path, files: files, limit: 1_048_576)
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            let hits = lines.filter { line in
                ignoreCase ? line.localizedCaseInsensitiveContains(pattern) : line.contains(pattern)
            }
            let output = hits.isEmpty ? "" : hits.joined(separator: "\n") + "\n"
            return TerminalResult(stdout: output, cwd: cwd.string, exit: hits.isEmpty ? 1 : 0)
        } catch {
            return fail("grep: \(message(error))", cwd: cwd)
        }
    }

    private func wordCount(_ args: [String], cwd: VirtualPath, files: any FileProvider) async -> TerminalResult {
        guard let target = args.last, !target.hasPrefix("-") else { return fail("wc: missing file", cwd: cwd) }
        guard let path = try? VirtualPath.resolve(target, from: cwd) else { return fail("wc: invalid path", cwd: cwd) }
        do {
            let text = try await readText(path: path, files: files, limit: 1_048_576)
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false).count
            let words = text.split { $0.isWhitespace }.count
            return TerminalResult(stdout: "\(lines)\t\(words)\t\(text.utf8.count)\t\(path.components.last ?? path.string)\n", cwd: cwd.string)
        } catch {
            return fail("wc: \(message(error))", cwd: cwd)
        }
    }

    private func clip(_ result: TerminalResult) -> TerminalResult {
        var copy = result
        let cap = 256 * 1024
        if copy.stdout.utf8.count > cap {
            copy.stdout = String(copy.stdout.prefix(cap)) + "\n… output truncated\n"
        }
        if copy.stderr.utf8.count > cap {
            copy.stderr = String(copy.stderr.prefix(cap))
        }
        return copy
    }

    private func fail(_ text: String, cwd: VirtualPath) -> TerminalResult {
        TerminalResult(stderr: text + "\n", cwd: cwd.string, exit: 1)
    }

    private func message(_ error: Error) -> String {
        (error as? ProtocolFailure)?.message ?? "couldn't read that item"
    }

    private func formatBytes(_ bytes: UInt64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var value = Double(bytes)
        var unit = 0
        while value >= 1024, unit < units.count - 1 {
            value /= 1024
            unit += 1
        }
        if unit == 0 { return "\(bytes) B" }
        return String(format: "%.1f %@", value, units[unit])
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }
}
