import Foundation

/// Maps virtual paths onto real directories. Every client path is sanitized before it touches disk.
public final class DiskFileProvider: FileProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var mounts: [MountedShare]
    private var uploads: [String: DiskUpload] = [:]

    public init(shares: [MountedShare] = []) {
        self.mounts = shares
    }

    public func setShares(_ shares: [MountedShare]) {
        sync { mounts = shares }
    }

    public func shares() async -> [ShareInfo] {
        sync { mounts.map { ShareInfo(name: $0.name, writable: $0.writable) } }
    }

    private func sync<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    public func list(path: VirtualPath, offset: Int, limit: Int, includeHidden: Bool) async throws -> [FileEntry] {
        let budget = MeasureBudget()
        if path.isRoot {
            let mounts = sync { self.mounts }
            let entries = mounts.map { share in
                directoryEntry(name: share.name, url: share.root, budget: budget, includeHidden: includeHidden)
            }
            let start = min(max(offset, 0), entries.count)
            return Array(entries[start..<min(start + ProviderSupport.clampLimit(limit), entries.count)])
        }
        let located = try locate(path, leafMustExist: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: located.url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ProtocolFailure(code: .badRequest, message: "That item is not a folder.")
        }
        let options: FileManager.DirectoryEnumerationOptions = includeHidden ? [] : [.skipsHiddenFiles]
        let urls = try FileManager.default.contentsOfDirectory(at: located.url, includingPropertiesForKeys: Array(Self.metaKeys), options: options)
        let sorted = urls.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        let entries = sorted.compactMap { url -> FileEntry? in
            if url.lastPathComponent.hasPrefix(".tether-upload-") { return nil }
            return entry(for: url, budget: budget, includeHidden: includeHidden)
        }
        let start = min(max(offset, 0), entries.count)
        let end = min(start + ProviderSupport.clampLimit(limit), entries.count)
        return Array(entries[start..<end])
    }

    public func stat(path: VirtualPath) async throws -> FileEntry {
        let budget = MeasureBudget()
        if path.isRoot {
            let mounts = sync { self.mounts }
            var size: UInt64 = 0
            var complete = true
            for share in mounts {
                let measured = contentsSize(of: share.root, budget: budget, includeHidden: false)
                size += measured.bytes
                if !measured.complete { complete = false }
            }
            return FileEntry(name: "/", kind: .dir, size: complete ? size : 0, mtime: Date().timeIntervalSince1970, childCount: mounts.count)
        }
        let located = try locate(path, leafMustExist: true)
        guard let entry = entry(for: located.url, budget: budget, includeHidden: false) else {
            throw ProtocolFailure(code: .notFound, message: "That item isn't here.")
        }
        return entry
    }

    public func read(path: VirtualPath, offset: UInt64, length: Int) async throws -> ReadChunk {
        let located = try locate(path, leafMustExist: true)
        let handle = try FileHandle(forReadingFrom: located.url)
        defer { try? handle.close() }
        let total = try handle.seekToEnd()
        if offset >= total {
            return ReadChunk(data: Data(), eof: true, totalSize: total)
        }
        try handle.seek(toOffset: offset)
        let count = ProviderSupport.clampRead(length)
        let data = try handle.read(upToCount: count) ?? Data()
        return ReadChunk(data: data, eof: offset + UInt64(data.count) >= total, totalSize: total)
    }

    public func beginUpload(path: VirtualPath, size: UInt64, overwrite: Bool) async throws -> String {
        guard path.components.count >= 2, let name = path.components.last else {
            throw ProtocolFailure(code: .badRequest, message: "Choose a folder that allows uploads.")
        }
        let parent = try locate(path.parent, leafMustExist: true)
        guard parent.share.writable else {
            throw ProtocolFailure(code: .readOnly, message: "This folder is read-only.")
        }
        let finalURL = uniqueDestination(directory: parent.url, name: name, overwrite: overwrite)
        let tempURL = parent.url.appendingPathComponent(".tether-upload-\(UUID().uuidString).partial")
        FileManager.default.createFile(atPath: tempURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: tempURL)
        let upload = DiskUpload(handle: handle, tempURL: tempURL, finalURL: finalURL, expected: size, received: 0)
        let id = UUID().uuidString
        sync { uploads[id] = upload }
        return id
    }

    public func uploadChunk(id: String, offset: UInt64, data: Data) async throws -> UInt64 {
        let upload = try takeUpload(id)
        try upload.handle.seek(toOffset: offset)
        try upload.handle.write(contentsOf: data)
        upload.received = max(upload.received, offset + UInt64(data.count))
        return upload.received
    }

    public func commitUpload(id: String) async throws {
        let upload = try takeUpload(id, remove: true)
        try upload.handle.close()
        guard upload.received == upload.expected else {
            try? FileManager.default.removeItem(at: upload.tempURL)
            throw ProtocolFailure(code: .badRequest, message: "The upload ended early.")
        }
        if FileManager.default.fileExists(atPath: upload.finalURL.path) {
            try FileManager.default.removeItem(at: upload.finalURL)
        }
        try FileManager.default.moveItem(at: upload.tempURL, to: upload.finalURL)
    }

    public func abortUpload(id: String) async throws {
        guard let upload = try? takeUpload(id, remove: true) else { return }
        try? upload.handle.close()
        try? FileManager.default.removeItem(at: upload.tempURL)
    }

    /// Real URL for a virtual path, used by the host for thumbnails. Still rejects escapes.
    public func fileURL(for path: VirtualPath) throws -> URL {
        try locate(path, leafMustExist: true).url
    }

    private func takeUpload(_ id: String, remove: Bool = false) throws -> DiskUpload {
        try sync {
            guard let upload = remove ? uploads.removeValue(forKey: id) : uploads[id] else {
                throw ProtocolFailure(code: .notFound, message: "That upload is no longer active.")
            }
            return upload
        }
    }

    private func locate(_ path: VirtualPath, leafMustExist: Bool) throws -> Location {
        guard let shareName = path.components.first else {
            throw ProtocolFailure(code: .badRequest, message: "Choose a shared folder.")
        }
        let share = sync { mounts.first { $0.name == shareName } }
        guard let share else {
            throw ProtocolFailure(code: .notFound, message: "That shared folder isn't here.")
        }
        let root = share.root.standardizedFileURL.resolvingSymlinksInPath()
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else {
            throw ProtocolFailure(code: .notFound, message: "That shared folder isn't available. Add it again on your Mac.")
        }
        let relative = Array(path.components.dropFirst())
        var current = root
        if relative.isEmpty {
            return Location(share: share, url: root)
        }
        let walk = leafMustExist ? relative : Array(relative.dropLast())
        for part in walk {
            let next = current.appendingPathComponent(part)
            let resolved = next.resolvingSymlinksInPath().standardizedFileURL
            guard Self.contains(resolved, in: root) else {
                throw ProtocolFailure(code: .outsideShare, message: "That path isn't available.")
            }
            current = resolved
        }
        if !leafMustExist, let leaf = relative.last {
            let next = current.appendingPathComponent(leaf).standardizedFileURL
            guard Self.contains(next, in: root) else {
                throw ProtocolFailure(code: .outsideShare, message: "That path isn't available.")
            }
            current = next
        }
        return Location(share: share, url: current)
    }

    public func makeDirectory(path: VirtualPath, createParents: Bool) async throws {
        guard let shareName = path.components.first, path.components.count > 1 else {
            throw ProtocolFailure(code: .badRequest, message: "Choose a folder inside a share.")
        }
        let share = try locate(VirtualPath(components: [shareName]), leafMustExist: true)
        guard share.share.writable else {
            throw ProtocolFailure(code: .readOnly, message: "This folder is read-only.")
        }
        var url = share.url
        for part in path.components.dropFirst() {
            url = url.appendingPathComponent(part)
            guard Self.contains(url, in: share.url) else {
                throw ProtocolFailure(code: .outsideShare, message: "That path isn't available.")
            }
        }
        if !createParents, !FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path) {
            throw ProtocolFailure(code: .notFound, message: "That folder isn't here.")
        }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: createParents)
    }

    public func remove(path: VirtualPath, recursive: Bool) async throws {
        guard path.components.count > 1 else {
            throw ProtocolFailure(code: .denied, message: "That shared folder can't be removed from the phone.")
        }
        let located = try locate(path, leafMustExist: true)
        guard located.share.writable else {
            throw ProtocolFailure(code: .readOnly, message: "This folder is read-only.")
        }
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: located.url.path, isDirectory: &isDir)
        if isDir.boolValue, !recursive {
            let kids = try FileManager.default.contentsOfDirectory(atPath: located.url.path)
            if !kids.isEmpty {
                throw ProtocolFailure(code: .badRequest, message: "That folder is not empty.")
            }
        }
        try FileManager.default.removeItem(at: located.url)
    }

    public func moveItem(from: VirtualPath, to: VirtualPath) async throws {
        let source = try locate(from, leafMustExist: true)
        let destination = try locate(to, leafMustExist: false)
        guard destination.share.writable else {
            throw ProtocolFailure(code: .readOnly, message: "This folder is read-only.")
        }
        if FileManager.default.fileExists(atPath: destination.url.path) {
            try FileManager.default.removeItem(at: destination.url)
        }
        try FileManager.default.moveItem(at: source.url, to: destination.url)
    }

    public func copyItem(from: VirtualPath, to: VirtualPath) async throws {
        let source = try locate(from, leafMustExist: true)
        let destination = try locate(to, leafMustExist: false)
        guard destination.share.writable else {
            throw ProtocolFailure(code: .readOnly, message: "This folder is read-only.")
        }
        if FileManager.default.fileExists(atPath: destination.url.path) {
            try FileManager.default.removeItem(at: destination.url)
        }
        try FileManager.default.copyItem(at: source.url, to: destination.url)
    }

    public func writeWholeFile(path: VirtualPath, data: Data, append: Bool) async throws {
        let parent = try locate(path.parent, leafMustExist: true)
        guard parent.share.writable else {
            throw ProtocolFailure(code: .readOnly, message: "This folder is read-only.")
        }
        let url = try locate(path, leafMustExist: false).url
        if append, FileManager.default.fileExists(atPath: url.path) {
            let handle = try FileHandle(forWritingTo: url)
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.close()
        } else {
            try data.write(to: url, options: .atomic)
        }
    }

    private static let metaKeys: Set<URLResourceKey> = [
        .isDirectoryKey, .isSymbolicLinkKey, .isPackageKey, .isAliasFileKey,
        .fileSizeKey, .totalFileSizeKey, .contentModificationDateKey,
        .creationDateKey, .typeIdentifierKey, .nameKey,
    ]

    private func directoryEntry(name: String, url: URL, budget: MeasureBudget, includeHidden: Bool) -> FileEntry {
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .creationDateKey, .typeIdentifierKey])
        let options: FileManager.DirectoryEnumerationOptions = includeHidden ? [] : [.skipsHiddenFiles]
        let children = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: options))?.count
        let measured = contentsSize(of: url, budget: budget, includeHidden: includeHidden)
        return FileEntry(
            name: name,
            kind: .dir,
            size: measured.complete ? measured.bytes : 0,
            mtime: values?.contentModificationDate?.timeIntervalSince1970 ?? Date().timeIntervalSince1970,
            uti: values?.typeIdentifier,
            childCount: children,
            created: values?.creationDate?.timeIntervalSince1970
        )
    }

    private func entry(for url: URL, budget: MeasureBudget, includeHidden: Bool) -> FileEntry? {
        let values = try? url.resourceValues(forKeys: Self.metaKeys)
        let name = values?.name ?? url.lastPathComponent
        if values == nil {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
                return directoryEntry(name: name, url: url, budget: budget, includeHidden: includeHidden)
            }
        }
        let mtime = values?.contentModificationDate?.timeIntervalSince1970
            ?? attributeDate(url, key: .modificationDate)
            ?? Date().timeIntervalSince1970
        let created = values?.creationDate?.timeIntervalSince1970 ?? attributeDate(url, key: .creationDate)
        if values?.isSymbolicLink == true || values?.isAliasFile == true {
            return FileEntry(
                name: name,
                kind: .link,
                size: Self.reportedBytes(values, url: url),
                mtime: mtime,
                uti: values?.typeIdentifier,
                created: created
            )
        }
        if values?.isDirectory == true {
            return directoryEntry(name: name, url: url, budget: budget, includeHidden: includeHidden)
        }
        return FileEntry(
            name: name,
            kind: .file,
            size: Self.reportedBytes(values, url: url),
            mtime: mtime,
            uti: values?.typeIdentifier,
            created: created
        )
    }

    /// Logical size, then allocated size, then the file attributes. Packages and some
    /// document bundles report a nil `fileSize` until one of the later sources is tried.
    private static func reportedBytes(_ values: URLResourceValues?, url: URL) -> UInt64 {
        let logical = values?.fileSize ?? 0
        let stored = values?.totalFileSize ?? 0
        let best = max(logical, stored)
        if best > 0 { return UInt64(best) }
        if let number = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber, number.uint64Value > 0 {
            return number.uint64Value
        }
        return UInt64(best)
    }

    private func attributeDate(_ url: URL, key: FileAttributeKey) -> TimeInterval? {
        guard let date = (try? FileManager.default.attributesOfItem(atPath: url.path))?[key] as? Date else { return nil }
        return date.timeIntervalSince1970
    }

    /// Sums visible file bytes. Stops early on huge trees and reports the walk as incomplete
    /// so the caller does not publish a misleading partial size.
    private func contentsSize(of url: URL, budget: MeasureBudget, includeHidden: Bool) -> (bytes: UInt64, complete: Bool) {
        if budget.exhausted { return (0, false) }
        let options: FileManager.DirectoryEnumerationOptions = includeHidden ? [] : [.skipsHiddenFiles]
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isAliasFileKey, .fileSizeKey, .totalFileSizeKey],
            options: options
        ) else {
            return (0, false)
        }
        var total: UInt64 = 0
        var complete = true
        for child in urls where !child.lastPathComponent.hasPrefix(".tether-upload-") {
            if budget.exhausted {
                complete = false
                break
            }
            budget.remaining -= 1
            let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isAliasFileKey, .fileSizeKey, .totalFileSizeKey])
            if values?.isSymbolicLink == true || values?.isAliasFile == true {
                total += Self.reportedBytes(values, url: child)
                continue
            }
            if values?.isDirectory == true {
                let nested = contentsSize(of: child, budget: budget, includeHidden: includeHidden)
                total += nested.bytes
                if !nested.complete { complete = false }
                continue
            }
            total += Self.reportedBytes(values, url: child)
        }
        return (total, complete)
    }

    private func uniqueDestination(directory: URL, name: String, overwrite: Bool) -> URL {
        let desired = directory.appendingPathComponent(name)
        if overwrite || !FileManager.default.fileExists(atPath: desired.path) {
            return desired
        }
        let stem = desired.deletingPathExtension().lastPathComponent
        let ext = desired.pathExtension
        var number = 2
        while true {
            let candidate = ext.isEmpty ? "\(stem) (\(number))" : "\(stem) (\(number)).\(ext)"
            let url = directory.appendingPathComponent(candidate)
            if !FileManager.default.fileExists(atPath: url.path) { return url }
            number += 1
        }
    }

    static func contains(_ url: URL, in root: URL) -> Bool {
        let rootPath = root.standardizedFileURL.resolvingSymlinksInPath().path
        let path = url.standardizedFileURL.path
        if path == rootPath { return true }
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        return path.hasPrefix(prefix)
    }
}

private struct Location {
    var share: MountedShare
    var url: URL
}

private final class MeasureBudget {
    var remaining = 20_000
    var deadline = Date().addingTimeInterval(2)
    var exhausted: Bool { remaining <= 0 || Date() >= deadline }
}

private final class DiskUpload: @unchecked Sendable {
    let handle: FileHandle
    let tempURL: URL
    let finalURL: URL
    let expected: UInt64
    var received: UInt64

    init(handle: FileHandle, tempURL: URL, finalURL: URL, expected: UInt64, received: UInt64) {
        self.handle = handle
        self.tempURL = tempURL
        self.finalURL = finalURL
        self.expected = expected
        self.received = received
    }
}
