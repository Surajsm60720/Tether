import Foundation

/// One hit from a live walk of shared folders. Paths are virtual (`/Share/…`).
public struct FileSearchHit: Equatable, Sendable, Identifiable {
    public var path: String
    public var entry: FileEntry

    public var id: String { path }

    public init(path: String, entry: FileEntry) {
        self.path = path
        self.entry = entry
    }

    /// Parent folder path for display under the name.
    public var folder: String {
        (try? VirtualPath.parse(path))?.parent.string ?? "/"
    }
}

public enum FileSearchMatch: Equatable, Sendable {
    /// Shell-style `*` / `?` (case-insensitive), as used by the `find` command.
    case wildcard
    /// Substring match (case-insensitive), as used by the Files search field.
    case substring
}

/// Live name search under a virtual root. Walks via `list` on demand — no background index.
public enum FileSearch {
    public static let maxResults = 500
    public static let maxDepth = 12
    public static let maxVisited = 8_000
    public static let timeLimit: TimeInterval = 8

    public static func find(
        pattern: String,
        root: VirtualPath = .root,
        match: FileSearchMatch = .substring,
        includeDirectories: Bool = true,
        list: @Sendable (VirtualPath) async throws -> [FileEntry]
    ) async throws -> [FileSearchHit] {
        let trimmed = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        var hits: [FileSearchHit] = []
        var visited = 0
        let started = Date()
        try await walk(
            path: root,
            pattern: trimmed,
            match: match,
            includeDirectories: includeDirectories,
            list: list,
            depth: 0,
            hits: &hits,
            visited: &visited,
            started: started
        )
        return hits
    }

    private static func walk(
        path: VirtualPath,
        pattern: String,
        match: FileSearchMatch,
        includeDirectories: Bool,
        list: @Sendable (VirtualPath) async throws -> [FileEntry],
        depth: Int,
        hits: inout [FileSearchHit],
        visited: inout Int,
        started: Date
    ) async throws {
        if hits.count >= maxResults || depth > maxDepth || visited > maxVisited
            || Date().timeIntervalSince(started) > timeLimit
        {
            return
        }
        visited += 1
        let children = try await list(path)
        for child in children {
            if hits.count >= maxResults { return }
            let childPath = path.appending(child.name)
            let isDir = child.kind == .dir
            if matches(pattern, name: child.name, style: match), includeDirectories || !isDir {
                hits.append(FileSearchHit(path: childPath.string, entry: child))
            }
            if isDir {
                try await walk(
                    path: childPath,
                    pattern: pattern,
                    match: match,
                    includeDirectories: includeDirectories,
                    list: list,
                    depth: depth + 1,
                    hits: &hits,
                    visited: &visited,
                    started: started
                )
            }
        }
    }

    private static func matches(_ pattern: String, name: String, style: FileSearchMatch) -> Bool {
        switch style {
        case .substring:
            return name.localizedCaseInsensitiveContains(pattern)
        case .wildcard:
            let expression = "^" + NSRegularExpression.escapedPattern(for: pattern)
                .replacingOccurrences(of: "\\*", with: ".*")
                .replacingOccurrences(of: "\\?", with: ".") + "$"
            return name.range(of: expression, options: [.regularExpression, .caseInsensitive]) != nil
        }
    }
}
