import Foundation

/// App Group handoff from the iOS Share Extension into the main Tether client.
public enum ShareInboxQueue: Sendable {
    public static let appGroupID = "group.app.tether.client"
    public static let pendingFolderName = "PendingSend"
    public static let manifestName = "manifest.json"

    public struct Manifest: Codable, Sendable, Equatable {
        public var files: [String]
        public var createdAt: TimeInterval

        public init(files: [String], createdAt: TimeInterval = Date().timeIntervalSince1970) {
            self.files = files
            self.createdAt = createdAt
        }
    }

    public static func containerURL() -> URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID)
    }

    public static func pendingDirectory() throws -> URL {
        guard let root = containerURL() else {
            throw ProtocolFailure(code: .internalError, message: "Share inbox isn't available on this device.")
        }
        let directory = root.appendingPathComponent(pendingFolderName, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// Copies shared items into the App Group and writes a manifest the main app drains.
    public static func enqueue(fileURLs: [URL]) throws {
        let directory = try pendingDirectory()
        var names: [String] = []
        for url in fileURLs {
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            let name = uniqueName(url.lastPathComponent, in: directory, used: &names)
            let destination = directory.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: url, to: destination)
            names.append(name)
        }
        guard !names.isEmpty else { return }
        let manifest = Manifest(files: names)
        let data = try JSONEncoder().encode(manifest)
        try data.write(to: directory.appendingPathComponent(manifestName), options: .atomic)
    }

    public static func hasPending() -> Bool {
        guard let root = containerURL() else { return false }
        let manifestURL = root
            .appendingPathComponent(pendingFolderName, isDirectory: true)
            .appendingPathComponent(manifestName)
        return FileManager.default.fileExists(atPath: manifestURL.path)
    }

    /// Returns pending file URLs and clears the manifest. Caller should delete each file after upload.
    public static func drainPending() throws -> [URL] {
        let directory = try pendingDirectory()
        let manifestURL = directory.appendingPathComponent(manifestName)
        guard FileManager.default.fileExists(atPath: manifestURL.path) else { return [] }
        let data = try Data(contentsOf: manifestURL)
        let manifest = try JSONDecoder().decode(Manifest.self, from: data)
        try? FileManager.default.removeItem(at: manifestURL)
        return manifest.files.map { directory.appendingPathComponent($0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    public static func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    private static func uniqueName(_ preferred: String, in directory: URL, used: inout [String]) -> String {
        var candidate = preferred.isEmpty ? "file" : preferred
        var number = 2
        while used.contains(candidate) || FileManager.default.fileExists(atPath: directory.appendingPathComponent(candidate).path) {
            let stem = (preferred as NSString).deletingPathExtension
            let ext = (preferred as NSString).pathExtension
            candidate = ext.isEmpty ? "\(stem) (\(number))" : "\(stem) (\(number)).\(ext)"
            number += 1
        }
        return candidate
    }
}
