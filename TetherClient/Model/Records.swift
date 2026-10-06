import Foundation
import SwiftData
import TetherCore

@Model
final class PairedHostRecord {
    var hostId: String
    var name: String
    var pairedAt: Date
    var lastConnectedAt: Date?

    init(hostId: String, name: String, pairedAt: Date = Date(), lastConnectedAt: Date? = nil) {
        self.hostId = hostId
        self.name = name
        self.pairedAt = pairedAt
        self.lastConnectedAt = lastConnectedAt
    }
}

@Model
final class RecentRecord {
    var hostId: String
    var path: String
    var openedAt: Date

    init(hostId: String, path: String, openedAt: Date = Date()) {
        self.hostId = hostId
        self.path = path
        self.openedAt = openedAt
    }
}

struct PairedItem: Identifiable, Equatable {
    var id: String
    var name: String
    var pairedAt: Date
    var lastConnectedAt: Date?
}

enum PairPhase: Equatable {
    case scanning
    case connecting
    case waiting
    case success(String)
    case failed(String)
}

enum TransferDirection: String {
    case down
    case up
}

enum TransferState: Equatable {
    case active
    case completed
    case failed
}

struct TransferItem: Identifiable, Equatable {
    var id = UUID()
    var name: String
    var path: String
    var direction: TransferDirection
    var sent: UInt64 = 0
    var total: UInt64 = 0
    var state: TransferState = .active
    var started = Date()
    var retries = 0
    var message: String?
    var localURL: URL?

    var fraction: Double {
        guard total > 0 else { return 0 }
        return min(1, Double(sent) / Double(total))
    }
}

struct FilePreview: Identifiable, Equatable {
    var url: URL
    var title: String
    var id: String { url.path }
}

struct FileInfo: Identifiable, Equatable {
    var entry: FileEntry
    var path: String
    var writable: Bool
    var id: String { path }
}

struct TermLine: Identifiable, Equatable {
    var id = UUID()
    var text: String
    var kind: Kind

    enum Kind { case input, output, error, dim, directory }
}

enum FeedbackCue: Equatable {
    case success
    case warning
    case selection
}

enum FileSort: String, CaseIterable, Identifiable {
    case name, date, size, kind
    var id: String { rawValue }
    var title: String {
        switch self {
        case .name: "Name"
        case .date: "Date"
        case .size: "Size"
        case .kind: "Kind"
        }
    }
}
