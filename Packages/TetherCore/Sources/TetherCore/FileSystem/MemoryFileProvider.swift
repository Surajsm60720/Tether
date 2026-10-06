import Foundation

/// In-memory virtual filesystem used by tests and the iOS demo host.
public final class MemoryFileProvider: FileProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var shares: [String: ShareNode] = [:]
    private var uploads: [String: Upload] = [:]

    private func withState<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    public init() {}

    public func addShare(name: String, writable: Bool) {
        withState {
            shares[name] = ShareNode(writable: writable, root: Node.directory(children: [:], mtime: Date()))
        }
    }

    public func writeFile(path: String, data: Data, modified: Date = Date()) throws {
        let virtual = try VirtualPath.parse(path)
        guard virtual.components.count >= 2 else {
            throw ProtocolFailure(code: .badRequest, message: "Choose a file inside a shared folder.")
        }
        try withState {
            let shareName = virtual.components[0]
            guard var share = shares[shareName] else {
                throw ProtocolFailure(code: .notFound, message: "That shared folder isn't here.")
            }
            try share.root.insert(components: Array(virtual.components.dropFirst()), data: data, modified: modified)
            shares[shareName] = share
        }
    }

    public func shares() async -> [ShareInfo] {
        withState {
            shares.keys.sorted().map { ShareInfo(name: $0, writable: shares[$0]?.writable ?? false) }
        }
    }

    public func list(path: VirtualPath, offset: Int, limit: Int, includeHidden: Bool) async throws -> [FileEntry] {
        try withState {
            let entries = try entries(at: path, includeHidden: includeHidden)
            let start = min(max(offset, 0), entries.count)
            let end = min(start + ProviderSupport.clampLimit(limit), entries.count)
            return Array(entries[start..<end])
        }
    }

    public func stat(path: VirtualPath) async throws -> FileEntry {
        try withState {
            if path.isRoot {
                return FileEntry(name: "/", kind: .dir, size: 0, mtime: Date().timeIntervalSince1970, childCount: shares.count)
            }
            return try node(at: path).entry(named: path.components.last ?? "/")
        }
    }

    public func read(path: VirtualPath, offset: UInt64, length: Int) async throws -> ReadChunk {
        try withState {
            guard case let .file(data, _) = try node(at: path) else {
                throw ProtocolFailure(code: .badRequest, message: "That item is a folder.")
            }
            let total = UInt64(data.count)
            if offset >= total {
                return ReadChunk(data: Data(), eof: true, totalSize: total)
            }
            let start = Int(offset)
            let count = min(ProviderSupport.clampRead(length), data.count - start)
            let slice = data.subdata(in: start..<(start + count))
            return ReadChunk(data: slice, eof: start + count >= data.count, totalSize: total)
        }
    }

    public func beginUpload(path: VirtualPath, size: UInt64, overwrite: Bool) async throws -> String {
        try withState {
            let parent = path.parent
            guard !path.isRoot, path.components.count >= 2 else {
                throw ProtocolFailure(code: .badRequest, message: "Choose a folder that allows uploads.")
            }
            guard let share = shares[path.components[0]], share.writable else {
                throw ProtocolFailure(code: .readOnly, message: "This folder is read-only.")
            }
            _ = try node(at: parent)
            let id = UUID().uuidString
            uploads[id] = Upload(path: path, size: size, overwrite: overwrite, data: Data())
            return id
        }
    }

    public func uploadChunk(id: String, offset: UInt64, data: Data) async throws -> UInt64 {
        try withState {
            guard var upload = uploads[id] else {
                throw ProtocolFailure(code: .notFound, message: "That upload is no longer active.")
            }
            let start = Int(offset)
            if upload.data.count < start {
                upload.data.append(Data(repeating: 0, count: start - upload.data.count))
            }
            let end = start + data.count
            if upload.data.count < end {
                upload.data.append(Data(repeating: 0, count: end - upload.data.count))
            }
            upload.data.replaceSubrange(start..<end, with: data)
            uploads[id] = upload
            return UInt64(upload.data.count)
        }
    }

    public func commitUpload(id: String) async throws {
        try withState {
            guard let upload = uploads.removeValue(forKey: id) else {
                throw ProtocolFailure(code: .notFound, message: "That upload is no longer active.")
            }
            guard UInt64(upload.data.count) == upload.size else {
                throw ProtocolFailure(code: .badRequest, message: "The upload ended early.")
            }
            let shareName = upload.path.components[0]
            guard var share = shares[shareName] else {
                throw ProtocolFailure(code: .notFound, message: "That shared folder isn't here.")
            }
            var path = upload.path
            if !upload.overwrite, share.root.contains(Array(path.components.dropFirst())) {
                path = unique(path, in: share.root)
            }
            try share.root.insert(components: Array(path.components.dropFirst()), data: upload.data, modified: Date())
            shares[shareName] = share
        }
    }

    public func abortUpload(id: String) async throws {
        withState {
            uploads.removeValue(forKey: id)
            return ()
        }
    }

    private func entries(at path: VirtualPath, includeHidden: Bool) throws -> [FileEntry] {
        if path.isRoot {
            return shares.keys.sorted().map { name in
                let node = shares[name]?.root
                let count: Int
                if case let .directory(children, _) = node {
                    count = children.count
                } else {
                    count = 0
                }
                return FileEntry(
                    name: name,
                    kind: .dir,
                    size: node?.byteCount() ?? 0,
                    mtime: node?.mtime.timeIntervalSince1970 ?? Date().timeIntervalSince1970,
                    childCount: count
                )
            }
        }
        guard case let .directory(children, _) = try node(at: path) else {
            throw ProtocolFailure(code: .badRequest, message: "That item is not a folder.")
        }
        return children.keys.sorted().compactMap { name in
            if !includeHidden && name.hasPrefix(".") { return nil }
            return children[name]?.entry(named: name)
        }
    }

    private func node(at path: VirtualPath) throws -> Node {
        guard let first = path.components.first, let share = shares[first] else {
            throw ProtocolFailure(code: .notFound, message: "That item isn't here.")
        }
        return try share.root.child(Array(path.components.dropFirst()))
    }

    public func makeDirectory(path: VirtualPath, createParents: Bool) async throws {
        try withState {
            try mutate(path.components[0]) { share in
                try share.root.makeDirectory(Array(path.components.dropFirst()), createParents: createParents)
            }
        }
    }

    public func remove(path: VirtualPath, recursive: Bool) async throws {
        guard path.components.count > 1 else {
            throw ProtocolFailure(code: .denied, message: "That shared folder can't be removed from the phone.")
        }
        try withState {
            try mutate(path.components[0]) { share in
                try share.root.remove(Array(path.components.dropFirst()), recursive: recursive)
            }
        }
    }

    public func moveItem(from: VirtualPath, to: VirtualPath) async throws {
        try withState {
            guard from.components.first == to.components.first else {
                throw ProtocolFailure(code: .badRequest, message: "Move stays inside one shared folder.")
            }
            try mutate(from.components[0]) { share in
                let node = try share.root.child(Array(from.components.dropFirst()))
                try share.root.remove(Array(from.components.dropFirst()), recursive: true)
                try share.root.place(Array(to.components.dropFirst()), node: node)
            }
        }
    }

    public func copyItem(from: VirtualPath, to: VirtualPath) async throws {
        try withState {
            guard from.components.first == to.components.first else {
                throw ProtocolFailure(code: .badRequest, message: "Copy stays inside one shared folder.")
            }
            try mutate(from.components[0]) { share in
                let node = try share.root.child(Array(from.components.dropFirst()))
                try share.root.place(Array(to.components.dropFirst()), node: node)
            }
        }
    }

    public func writeWholeFile(path: VirtualPath, data: Data, append: Bool) async throws {
        try withState {
            try mutate(path.components[0]) { share in
                var payload = data
                if append, let existing = try? share.root.child(Array(path.components.dropFirst())),
                   case let .file(current, _) = existing {
                    payload = current + data
                }
                try share.root.insert(components: Array(path.components.dropFirst()), data: payload, modified: Date())
            }
        }
    }

    private func mutate(_ shareName: String, _ body: (inout ShareNode) throws -> Void) throws {
        guard var share = shares[shareName] else {
            throw ProtocolFailure(code: .notFound, message: "That shared folder isn't here.")
        }
        guard share.writable else {
            throw ProtocolFailure(code: .readOnly, message: "This folder is read-only.")
        }
        guard !shareName.isEmpty else { throw ProtocolFailure.malformed }
        try body(&share)
        shares[shareName] = share
    }

    private func unique(_ path: VirtualPath, in root: Node) -> VirtualPath {
        let name = path.components.last ?? "file"
        let stem = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var number = 2
        var candidate = path
        while root.contains(Array(candidate.components.dropFirst())) {
            let next = ext.isEmpty ? "\(stem) (\(number))" : "\(stem) (\(number)).\(ext)"
            candidate = path.parent.appending(next)
            number += 1
        }
        return candidate
    }
}

private struct ShareNode {
    var writable: Bool
    var root: Node
}

private struct Upload {
    var path: VirtualPath
    var size: UInt64
    var overwrite: Bool
    var data: Data
}

private indirect enum Node {
    case directory(children: [String: Node], mtime: Date)
    case file(data: Data, mtime: Date)

    var mtime: Date {
        switch self {
        case let .directory(_, mtime), let .file(_, mtime): mtime
        }
    }

    func byteCount() -> UInt64 {
        switch self {
        case let .file(data, _):
            return UInt64(data.count)
        case let .directory(children, _):
            return children.values.reduce(0) { $0 + $1.byteCount() }
        }
    }

    func entry(named name: String) -> FileEntry {
        switch self {
        case let .directory(children, mtime):
            return FileEntry(name: name, kind: .dir, size: byteCount(), mtime: mtime.timeIntervalSince1970, childCount: children.count)
        case let .file(data, mtime):
            return FileEntry(name: name, kind: .file, size: UInt64(data.count), mtime: mtime.timeIntervalSince1970)
        }
    }

    func child(_ components: [String]) throws -> Node {
        if components.isEmpty { return self }
        guard case let .directory(children, _) = self, let next = children[components[0]] else {
            throw ProtocolFailure(code: .notFound, message: "That item isn't here.")
        }
        return try next.child(Array(components.dropFirst()))
    }

    func contains(_ components: [String]) -> Bool {
        (try? child(components)) != nil
    }

    mutating func insert(components: [String], data: Data, modified: Date) throws {
        guard let name = components.first else { return }
        if components.count == 1 {
            guard case var .directory(children, _) = self else {
                throw ProtocolFailure(code: .badRequest, message: "That item is not a folder.")
            }
            children[name] = .file(data: data, mtime: modified)
            self = .directory(children: children, mtime: modified)
            return
        }
        guard case .directory(var children, let mtime) = self else {
            throw ProtocolFailure(code: .badRequest, message: "That item is not a folder.")
        }
        var next = children[name] ?? .directory(children: [:], mtime: modified)
        try next.insert(components: Array(components.dropFirst()), data: data, modified: modified)
        children[name] = next
        self = .directory(children: children, mtime: mtime)
    }

    mutating func makeDirectory(_ components: [String], createParents: Bool) throws {
        guard let name = components.first else { return }
        guard case .directory(var children, let mtime) = self else {
            throw ProtocolFailure(code: .badRequest, message: "That item is not a folder.")
        }
        if components.count == 1 {
            if case .file = children[name] {
                throw ProtocolFailure(code: .badRequest, message: "A file with that name is already there.")
            }
            if children[name] == nil {
                children[name] = .directory(children: [:], mtime: Date())
            }
            self = .directory(children: children, mtime: mtime)
            return
        }
        if children[name] == nil {
            guard createParents else {
                throw ProtocolFailure(code: .notFound, message: "That folder isn't here.")
            }
            children[name] = .directory(children: [:], mtime: Date())
        }
        var next = children[name] ?? .directory(children: [:], mtime: Date())
        try next.makeDirectory(Array(components.dropFirst()), createParents: createParents)
        children[name] = next
        self = .directory(children: children, mtime: mtime)
    }

    mutating func remove(_ components: [String], recursive: Bool) throws {
        guard let name = components.first else { return }
        guard case .directory(var children, let mtime) = self else {
            throw ProtocolFailure(code: .badRequest, message: "That item is not a folder.")
        }
        if components.count == 1 {
            guard let node = children[name] else {
                throw ProtocolFailure(code: .notFound, message: "That item isn't here.")
            }
            if case let .directory(kids, _) = node, !kids.isEmpty, !recursive {
                throw ProtocolFailure(code: .badRequest, message: "That folder is not empty.")
            }
            children.removeValue(forKey: name)
            self = .directory(children: children, mtime: mtime)
            return
        }
        guard var next = children[name] else {
            throw ProtocolFailure(code: .notFound, message: "That item isn't here.")
        }
        try next.remove(Array(components.dropFirst()), recursive: recursive)
        children[name] = next
        self = .directory(children: children, mtime: mtime)
    }

    mutating func place(_ components: [String], node: Node) throws {
        guard let name = components.first else { return }
        guard case .directory(var children, let mtime) = self else {
            throw ProtocolFailure(code: .badRequest, message: "That item is not a folder.")
        }
        if components.count == 1 {
            children[name] = node
            self = .directory(children: children, mtime: mtime)
            return
        }
        var next = children[name] ?? .directory(children: [:], mtime: Date())
        try next.place(Array(components.dropFirst()), node: node)
        children[name] = next
        self = .directory(children: children, mtime: mtime)
    }
}
