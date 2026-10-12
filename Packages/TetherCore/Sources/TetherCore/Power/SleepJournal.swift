import Foundation

/// On-disk record written before Tether enables `pmset disablesleep`.
/// A LaunchAgent uses this to undo the flag if Host dies.
public struct SleepJournal: Codable, Equatable, Sendable {
    public var ownerPID: Int32
    public var disablesleepEnabled: Bool
    /// Prior battery Low Power Mode before Tether turned it on; `nil` if Tether did not change it.
    public var lowPowerModePrevious: Bool?
    public var updatedAt: Date

    public init(
        ownerPID: Int32,
        disablesleepEnabled: Bool,
        lowPowerModePrevious: Bool? = nil,
        updatedAt: Date = Date()
    ) {
        self.ownerPID = ownerPID
        self.disablesleepEnabled = disablesleepEnabled
        self.lowPowerModePrevious = lowPowerModePrevious
        self.updatedAt = updatedAt
    }
}

/// Paths and owner-only I/O for the sleep recovery journal.
public enum SleepJournalStore: Sendable {
    public static let fileName = "sleep-journal.json"
    public static let supportFolderName = "Tether"

    public static func defaultDirectory(fileManager: FileManager = .default) -> URL {
        #if os(macOS)
        // Prefer the real login home so a LaunchAgent outside the sandbox can read the journal.
        let root = RealUserHome.applicationSupport
        #else
        let root = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        #endif
        return root.appendingPathComponent(supportFolderName, isDirectory: true)
    }

    public static func defaultURL(fileManager: FileManager = .default) -> URL {
        defaultDirectory(fileManager: fileManager).appendingPathComponent(fileName)
    }

    public static func ensureDirectory(at directory: URL, fileManager: FileManager = .default) throws {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try? fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o700))],
            ofItemAtPath: directory.path
        )
    }

    public static func write(
        _ journal: SleepJournal,
        to url: URL,
        fileManager: FileManager = .default
    ) throws {
        try ensureDirectory(at: url.deletingLastPathComponent(), fileManager: fileManager)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(journal)
        try data.write(to: url, options: .atomic)
        try? fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: url.path
        )
    }

    public static func read(from url: URL) throws -> SleepJournal? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(SleepJournal.self, from: data)
    }

    public static func remove(at url: URL, fileManager: FileManager = .default) {
        try? fileManager.removeItem(at: url)
    }
}
