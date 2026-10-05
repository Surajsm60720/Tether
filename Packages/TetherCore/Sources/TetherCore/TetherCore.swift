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
    /// Default file chunk size. Offsets are 64-bit so larger files can resume later.
    public static let chunkSize = 256 * 1024
    /// Largest sealed frame accepted on the wire.
    public static let maxFrameBytes = 1 << 20
}

public enum TetherLog {
    public static let discovery = Logger(subsystem: "app.tether", category: "discovery")
    public static let pairing = Logger(subsystem: "app.tether", category: "pairing")
    public static let transport = Logger(subsystem: "app.tether", category: "transport")
    public static let fs = Logger(subsystem: "app.tether", category: "fs")
    public static let terminal = Logger(subsystem: "app.tether", category: "terminal")
}
