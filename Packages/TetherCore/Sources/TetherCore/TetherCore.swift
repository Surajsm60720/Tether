import Foundation
import os

/// Shared, UI-free core used by the Tether host and client apps.
///
/// Networking, crypto, the wire protocol, the virtual filesystem, and the
/// terminal interpreter live here. This module does not import SwiftUI, UIKit, or AppKit.
public enum TetherCoreInfo: Sendable {
    /// Wire protocol version advertised during discovery and the handshake.
    public static let protocolVersion = 1
    /// Bonjour service type. The leading and trailing underscores are required.
    public static let serviceType = "_tether._tcp"
    /// Bonjour type the iPhone advertises so the Mac can find it.
    public static let phoneServiceType = "_tether-phone._tcp"
    /// Bulk transfer chunk. Large enough to fill a fast Wi-Fi link, still under the 1 MiB frame cap.
    public static let chunkSize = 768 * 1024
    /// How many chunk requests stay in flight so the link stays full instead of waiting on each reply.
    public static let transferPipelineDepth = 8
    /// Largest sealed frame accepted on the wire.
    public static let maxFrameBytes = 1 << 20
    /// How long an inbound host connection may take to finish the handshake.
    public static let handshakeTimeoutSeconds: TimeInterval = 15
    /// Unauthenticated inbound sockets the host will hold at once.
    public static let maxPendingHandshakes = 8
    /// Directory listing page size kept well under `maxFrameBytes`.
    public static let maxListEntries = 400
    /// Hard cap on bytes buffered from a host shell (if one is ever used).
    public static let shellOutputCap = 256 * 1024
    /// Reserved share name for phone → Mac Send (always writable when mounted).
    public static let inboxShareName = "Inbox"
    /// Suggested on-disk folder name under Documents when the host creates a default Inbox.
    public static let inboxDefaultFolderName = "Tether Received"
}

/// Helpers for the reserved Inbox share used by phone → Mac Send.
public enum InboxShare: Sendable {
    public static var name: String { TetherCoreInfo.inboxShareName }

    public static func isInbox(_ path: VirtualPath) -> Bool {
        path.components.first == name
    }

    public static func isReservedShareName(_ name: String) -> Bool {
        name.caseInsensitiveCompare(Self.name) == .orderedSame
    }

    /// Virtual path for a file landing in Inbox, e.g. `/Inbox/photo.jpg`.
    public static func path(fileName: String) throws -> VirtualPath {
        let cleaned = (fileName as NSString).lastPathComponent
        guard !cleaned.isEmpty, cleaned != ".", cleaned != ".." else {
            throw PathError.invalid
        }
        return try VirtualPath.parse("/\(name)/\(cleaned)")
    }
}

/// Result of a finished upload, including the final name after conflict rename.
public struct UploadCommit: Sendable, Equatable {
    public var path: VirtualPath
    public var fileName: String

    public init(path: VirtualPath, fileName: String) {
        self.path = path
        self.fileName = fileName
    }
}

public enum TetherLog {
    public static let discovery = Logger(subsystem: "app.tether", category: "discovery")
    public static let pairing = Logger(subsystem: "app.tether", category: "pairing")
    public static let transport = Logger(subsystem: "app.tether", category: "transport")
    public static let fs = Logger(subsystem: "app.tether", category: "fs")
    public static let terminal = Logger(subsystem: "app.tether", category: "terminal")
}
