import Foundation

public enum PathError: Error, Equatable {
    case notAbsolute
    case emptySegment
    case escapes
    case invalid
}

/// A POSIX virtual path. Components never contain `.`, `..`, or empty segments.
public struct VirtualPath: Hashable, Sendable, Codable {
    public let components: [String]

    public init(components: [String]) {
        self.components = components
    }

    public static let root = VirtualPath(components: [])

    public var isRoot: Bool { components.isEmpty }

    public var string: String {
        components.isEmpty ? "/" : "/" + components.joined(separator: "/")
    }

    public var parent: VirtualPath {
        guard !components.isEmpty else { return .root }
        return VirtualPath(components: Array(components.dropLast()))
    }

    public func appending(_ name: String) -> VirtualPath {
        VirtualPath(components: components + [name])
    }

    /// Parses an absolute virtual path. Rejects `..`, empty segments, NUL, and encoded escapes.
    public static func parse(_ raw: String) throws -> VirtualPath {
        let text = raw.precomposedStringWithCanonicalMapping.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty || text == "/" || text == "~" { return .root }
        if text.count > 4096 || text.contains("\0") { throw PathError.invalid }
        guard text.hasPrefix("/") else { throw PathError.notAbsolute }
        var trimmed = text
        while trimmed.count > 1 && trimmed.hasSuffix("/") {
            trimmed.removeLast()
        }
        let parts = String(trimmed.dropFirst()).components(separatedBy: "/")
        var clean: [String] = []
        for part in parts {
            if part.isEmpty { throw PathError.emptySegment }
            if part == "." { continue }
            if part == ".." || Self.decodesToEscape(part) { throw PathError.escapes }
            if part.count > 255 || part.contains("\\") || part.contains("/") { throw PathError.invalid }
            clean.append(part)
        }
        return VirtualPath(components: clean)
    }

    /// Resolves a terminal argument against a working directory, collapsing `.` and `..`.
    public static func resolve(_ argument: String, from cwd: VirtualPath) throws -> VirtualPath {
        let raw = argument.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.isEmpty { return cwd }
        if raw == "~" || raw == "/" { return .root }
        let absolute: String
        if raw.hasPrefix("/") || raw == "~" || raw.hasPrefix("~/") {
            absolute = raw == "~" ? "/" : (raw.hasPrefix("~/") ? "/" + raw.dropFirst(2) : raw)
        } else if cwd.isRoot {
            absolute = "/" + raw
        } else {
            absolute = cwd.string + "/" + raw
        }
        let text = absolute.precomposedStringWithCanonicalMapping
        if text.contains("\0") { throw PathError.invalid }
        var trimmed = text
        while trimmed.count > 1 && trimmed.hasSuffix("/") { trimmed.removeLast() }
        let parts = trimmed == "/" ? [] : String(trimmed.dropFirst()).components(separatedBy: "/")
        var clean: [String] = []
        for part in parts {
            if part.isEmpty { throw PathError.emptySegment }
            if part == "." { continue }
            if part == ".." {
                if !clean.isEmpty { clean.removeLast() }
                continue
            }
            if Self.decodesToEscape(part) { throw PathError.escapes }
            if part.count > 255 || part.contains("\\") { throw PathError.invalid }
            clean.append(part)
        }
        return VirtualPath(components: clean)
    }

    private static func decodesToEscape(_ part: String) -> Bool {
        guard part.contains("%") else { return false }
        var current = part
        for _ in 0..<3 {
            guard let decoded = current.removingPercentEncoding, decoded != current else { break }
            current = decoded
        }
        if current == ".." || current == "." { return true }
        if current.contains("/") || current.contains("\\") || current.contains("\0") { return true }
        return false
    }
}

public struct MountedShare: Sendable, Equatable {
    public var name: String
    public var root: URL
    public var writable: Bool

    public init(name: String, root: URL, writable: Bool) {
        self.name = name
        self.root = root
        self.writable = writable
    }
}

public protocol FileProvider: Sendable {
    func shares() async -> [ShareInfo]
    func list(path: VirtualPath, offset: Int, limit: Int, includeHidden: Bool) async throws -> [FileEntry]
    func stat(path: VirtualPath) async throws -> FileEntry
    func read(path: VirtualPath, offset: UInt64, length: Int) async throws -> ReadChunk
    func beginUpload(path: VirtualPath, size: UInt64, overwrite: Bool) async throws -> String
    func uploadChunk(id: String, offset: UInt64, data: Data) async throws -> UInt64
    func commitUpload(id: String) async throws
    func abortUpload(id: String) async throws
    func makeDirectory(path: VirtualPath, createParents: Bool) async throws
    func remove(path: VirtualPath, recursive: Bool) async throws
    func moveItem(from: VirtualPath, to: VirtualPath) async throws
    func copyItem(from: VirtualPath, to: VirtualPath) async throws
    func writeWholeFile(path: VirtualPath, data: Data, append: Bool) async throws
}

extension FileProvider {
    func makeDirectory(path: VirtualPath, createParents: Bool) async throws {
        throw ProtocolFailure(code: .readOnly, message: "This folder is read-only.")
    }

    func remove(path: VirtualPath, recursive: Bool) async throws {
        throw ProtocolFailure(code: .readOnly, message: "This folder is read-only.")
    }

    func moveItem(from: VirtualPath, to: VirtualPath) async throws {
        throw ProtocolFailure(code: .readOnly, message: "This folder is read-only.")
    }

    func copyItem(from: VirtualPath, to: VirtualPath) async throws {
        throw ProtocolFailure(code: .readOnly, message: "This folder is read-only.")
    }

    func writeWholeFile(path: VirtualPath, data: Data, append: Bool) async throws {
        throw ProtocolFailure(code: .readOnly, message: "This folder is read-only.")
    }

    func failure(_ error: Error) -> ProtocolFailure {
        if let failure = error as? ProtocolFailure { return failure }
        if let path = error as? PathError {
            switch path {
            case .escapes, .notAbsolute:
                return ProtocolFailure(code: .outsideShare, message: "That path isn't available.")
            case .emptySegment, .invalid:
                return ProtocolFailure.malformed
            }
        }
        return ProtocolFailure(code: .internalError, message: "Something went wrong reading that item.")
    }
}

enum ProviderSupport {
    static func clampLimit(_ limit: Int) -> Int {
        if limit <= 0 { return 1000 }
        return min(limit, 5000)
    }

    static func clampRead(_ length: Int) -> Int {
        min(max(length, 0), TetherCoreInfo.chunkSize)
    }
}
