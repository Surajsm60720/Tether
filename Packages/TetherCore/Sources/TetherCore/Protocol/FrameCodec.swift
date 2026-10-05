import Foundation

/// Length-prefixed frames: `[UInt32 big-endian length][payload]`.
public enum FrameCodec {
    public static func encode(payload: Data) throws -> Data {
        guard payload.count <= TetherCoreInfo.maxFrameBytes else {
            throw ProtocolFailure.oversize
        }
        var frame = Data(capacity: 4 + payload.count)
        frame.appendUInt32(UInt32(payload.count))
        frame.append(payload)
        return frame
    }
}

/// Incremental decoder for a TCP byte stream. Not thread-safe; own it from one task.
public struct FrameDecoder: Sendable {
    private var buffer = Data()

    public init() {}

    public mutating func append(_ chunk: Data) {
        buffer.append(chunk)
    }

    /// Returns the next payload, or `nil` when more bytes are needed.
    public mutating func pop() throws -> Data? {
        guard buffer.count >= 4 else { return nil }
        let length = buffer.uint32(at: 0)
        guard length > 0 else { throw ProtocolFailure.malformed }
        guard Int(length) <= TetherCoreInfo.maxFrameBytes else { throw ProtocolFailure.oversize }
        let total = 4 + Int(length)
        guard buffer.count >= total else { return nil }
        let payload = buffer.subdata(in: 4..<total)
        buffer.removeSubrange(0..<total)
        return payload
    }
}
