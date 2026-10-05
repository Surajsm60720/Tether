import Foundation

/// Frame kind stored in the first byte of a plaintext message.
public enum MessageKind: UInt8, Sendable, Equatable {
    case request = 0x01
    case response = 0x02
    case event = 0x03
}

public enum Op {
    public static let ping = "ping"
    public static let shares = "shares"
    public static let list = "list"
    public static let stat = "stat"
    public static let thumb = "thumb"
    public static let read = "read"
    public static let writeBegin = "write.begin"
    public static let writeChunk = "write.chunk"
    public static let writeCommit = "write.commit"
    public static let writeAbort = "write.abort"
    public static let termExec = "term.exec"
    public static let auth = "auth"
    public static let authOK = "auth.ok"
    public static let pairRequest = "pair.request"
    public static let pairComplete = "pair.complete"
    public static let clientHello = "client.hello"
    public static let hostHello = "host.hello"
}

public enum ErrorCode: String, Codable, Sendable, Equatable {
    case unauthorized
    case notFound
    case denied
    case outsideShare
    case readOnly
    case tooLarge
    case badRequest
    case busy
    case internalError = "internal"
}

/// User-readable protocol error. `message` never includes a real absolute path.
public struct ProtocolFailure: Error, Codable, Sendable, Equatable, LocalizedError {
    public var code: ErrorCode
    public var message: String

    public init(code: ErrorCode, message: String) {
        self.code = code
        self.message = message
    }

    public var errorDescription: String? { message }

    public static let malformed = ProtocolFailure(
        code: .badRequest,
        message: "The other device sent something Tether couldn't read."
    )
    public static let oversize = ProtocolFailure(
        code: .tooLarge,
        message: "That transfer is larger than Tether allows in one piece."
    )
    public static let timeout = ProtocolFailure(
        code: .busy,
        message: "The Mac took too long to respond."
    )
    public static let closed = ProtocolFailure(
        code: .internalError,
        message: "The connection closed."
    )
    public static let expired = ProtocolFailure(
        code: .unauthorized,
        message: "That code has expired. Create a new one on your Mac."
    )
    public static let locked = ProtocolFailure(
        code: .unauthorized,
        message: "Too many attempts. Try again in a few minutes."
    )
    public static let revoked = ProtocolFailure(
        code: .unauthorized,
        message: "This Mac removed your iPhone. Pair again to reconnect."
    )
    public static let denied = ProtocolFailure(
        code: .denied,
        message: "The Mac didn't allow this iPhone."
    )
}

public enum EntryKind: String, Codable, Sendable, Equatable {
    case file
    case dir
    case link
}

public struct FileEntry: Codable, Sendable, Equatable, Identifiable {
    public var name: String
    public var kind: EntryKind
    public var size: UInt64
    public var mtime: TimeInterval
    public var uti: String?
    /// Number of immediate children when the host already knows it.
    public var childCount: Int?

    public var id: String { name }

    public init(
        name: String,
        kind: EntryKind,
        size: UInt64,
        mtime: TimeInterval,
        uti: String? = nil,
        childCount: Int? = nil
    ) {
        self.name = name
        self.kind = kind
        self.size = size
        self.mtime = mtime
        self.uti = uti
        self.childCount = childCount
    }

    public var modified: Date { Date(timeIntervalSince1970: mtime) }
}

public struct ShareInfo: Codable, Sendable, Equatable, Identifiable {
    public var name: String
    public var writable: Bool
    public var id: String { name }

    public init(name: String, writable: Bool) {
        self.name = name
        self.writable = writable
    }
}

public struct ReadChunk: Sendable, Equatable {
    public var data: Data
    public var eof: Bool
    public var totalSize: UInt64

    public init(data: Data, eof: Bool, totalSize: UInt64) {
        self.data = data
        self.eof = eof
        self.totalSize = totalSize
    }
}

public struct TerminalAction: Codable, Sendable, Equatable {
    public var type: String
    public var path: String?

    public init(type: String, path: String? = nil) {
        self.type = type
        self.path = path
    }
}

public struct TerminalResult: Codable, Sendable, Equatable {
    public var stdout: String
    public var stderr: String
    public var cwd: String
    public var exit: Int
    public var action: TerminalAction?

    public init(
        stdout: String = "",
        stderr: String = "",
        cwd: String,
        exit: Int = 0,
        action: TerminalAction? = nil
    ) {
        self.stdout = stdout
        self.stderr = stderr
        self.cwd = cwd
        self.exit = exit
        self.action = action
    }
}

/// JSON header shared by hellos, requests, and responses.
/// Absent fields are omitted. Unknown fields are ignored.
public struct Header: Codable, Sendable, Equatable {
    public var op: String?
    public var requestId: UInt64?
    public var ok: Bool?
    public var error: ProtocolFailure?
    public var v: Int?
    public var deviceId: String?
    public var deviceName: String?
    public var nonceC: Data?
    public var nonceH: Data?
    public var mode: String?
    /// `full` uses the 32-byte pairing secret from the QR code.
    /// `short` uses the first 10 bytes, which is all the manual code carries.
    public var material: String?
    public var hostId: String?
    public var hostName: String?
    public var deviceKey: Data?
    public var path: String?
    public var offset: UInt64?
    public var length: Int?
    public var limit: Int?
    public var maxPixel: Int?
    public var size: UInt64?
    public var overwrite: Bool?
    public var uploadId: String?
    public var received: UInt64?
    public var eof: Bool?
    public var totalSize: UInt64?
    public var cwd: String?
    public var line: String?
    public var stdout: String?
    public var stderr: String?
    public var exit: Int?
    public var action: TerminalAction?
    public var shares: [ShareInfo]?
    public var entries: [FileEntry]?
    public var entry: FileEntry?
    public var all: Bool?

    public init() {}
}

public struct WireMessage: Sendable, Equatable {
    public var kind: MessageKind
    public var header: Header
    public var body: Data

    public init(kind: MessageKind, header: Header = Header(), body: Data = Data()) {
        self.kind = kind
        self.header = header
        self.body = body
    }

    public func encode() throws -> Data {
        let headerData: Data
        do {
            headerData = try JSONEncoder().encode(header)
        } catch {
            throw ProtocolFailure.malformed
        }
        var out = Data(capacity: 5 + headerData.count + body.count)
        out.append(kind.rawValue)
        out.appendUInt32(UInt32(headerData.count))
        out.append(headerData)
        out.append(body)
        return out
    }

    public static func decode(_ data: Data) throws -> WireMessage {
        guard data.count >= 5, let kind = MessageKind(rawValue: data[data.startIndex]) else {
            throw ProtocolFailure.malformed
        }
        let headerLength = data.uint32(at: 1)
        let headerStart = 5
        let headerEnd = headerStart + Int(headerLength)
        guard headerLength <= data.count, headerEnd <= data.count else {
            throw ProtocolFailure.malformed
        }
        let headerData = data.subdata(in: headerStart..<headerEnd)
        let header: Header
        do {
            header = try JSONDecoder().decode(Header.self, from: headerData)
        } catch {
            throw ProtocolFailure.malformed
        }
        let body = headerEnd < data.count ? data.subdata(in: headerEnd..<data.count) : Data()
        return WireMessage(kind: kind, header: header, body: body)
    }
}

public enum StreamError: Error, Sendable, Equatable {
    case closed
    case failed(String)
}

extension Data {
    func uint32(at offset: Int) -> UInt32 {
        let start = index(startIndex, offsetBy: offset)
        return (UInt32(self[start]) << 24)
            | (UInt32(self[start + 1]) << 16)
            | (UInt32(self[start + 2]) << 8)
            | UInt32(self[start + 3])
    }

    mutating func appendUInt32(_ value: UInt32) {
        append(UInt8((value >> 24) & 0xff))
        append(UInt8((value >> 16) & 0xff))
        append(UInt8((value >> 8) & 0xff))
        append(UInt8(value & 0xff))
    }
}
