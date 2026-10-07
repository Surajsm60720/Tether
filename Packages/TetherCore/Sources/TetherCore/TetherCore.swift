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
}

public enum TetherLog {
    public static let discovery = Logger(subsystem: "app.tether", category: "discovery")
    public static let pairing = Logger(subsystem: "app.tether", category: "pairing")
    public static let transport = Logger(subsystem: "app.tether", category: "transport")
    public static let fs = Logger(subsystem: "app.tether", category: "fs")
    public static let terminal = Logger(subsystem: "app.tether", category: "terminal")
}
