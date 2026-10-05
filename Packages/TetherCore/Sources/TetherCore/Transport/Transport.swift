import Foundation
import Network

public protocol ByteStream: Sendable {
    func send(_ data: Data) async throws
    func receive(maximumLength: Int) async throws -> Data
    func close() async
}

public final class NWByteStream: ByteStream, @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "app.tether.connection")
    public init(connection: NWConnection) {
        self.connection = connection
    }

    public func start() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let gate = ResumeGate()
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    gate.resume(continuation)
                case .failed(let error):
                    gate.fail(continuation, error)
                case .cancelled:
                    gate.fail(continuation, StreamError.closed)
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }
    }

    public func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }

    public func receive(maximumLength: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: maximumLength) { content, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                if let content, !content.isEmpty {
                    continuation.resume(returning: content)
                    return
                }
                if isComplete {
                    continuation.resume(throwing: StreamError.closed)
                    return
                }
                continuation.resume(returning: Data())
            }
        }
    }

    public func close() async {
        connection.cancel()
    }

    public var remoteDescription: String {
        String(describing: connection.endpoint)
    }
}

private final class ResumeGate: @unchecked Sendable {
    private let lock = NSLock()
    private var resumed = false

    func resume(_ continuation: CheckedContinuation<Void, Error>) {
        lock.lock()
        let should = !resumed
        resumed = true
        lock.unlock()
        if should { continuation.resume() }
    }

    func fail(_ continuation: CheckedContinuation<Void, Error>, _ error: Error) {
        lock.lock()
        let should = !resumed
        resumed = true
        lock.unlock()
        if should { continuation.resume(throwing: error) }
    }
}

final class ChunkQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var chunks: [Data] = []
    private var waiters: [CheckedContinuation<Data, Error>] = []
    private var closed = false

    func push(_ data: Data) {
        lock.lock()
        if closed {
            lock.unlock()
            return
        }
        if waiters.isEmpty {
            chunks.append(data)
            lock.unlock()
            return
        }
        let waiter = waiters.removeFirst()
        lock.unlock()
        waiter.resume(returning: data)
    }

    func pop() async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            switch claim(continuation) {
            case let .ready(chunk):
                continuation.resume(returning: chunk)
            case .closed:
                continuation.resume(throwing: StreamError.closed)
            case .waiting:
                break
            }
        }
    }

    private enum Claim {
        case ready(Data)
        case closed
        case waiting
    }

    private func claim(_ continuation: CheckedContinuation<Data, Error>) -> Claim {
        lock.lock()
        defer { lock.unlock() }
        if closed { return .closed }
        if !chunks.isEmpty { return .ready(chunks.removeFirst()) }
        waiters.append(continuation)
        return .waiting
    }

    func close() {
        lock.lock()
        closed = true
        let pending = waiters
        waiters.removeAll()
        chunks.removeAll()
        lock.unlock()
        for waiter in pending {
            waiter.resume(throwing: StreamError.closed)
        }
    }
}

/// Two linked in-memory streams. Used by unit tests so pairing does not need a network.
public final class MemoryPipe: @unchecked Sendable {
    public let client: any ByteStream
    public let host: any ByteStream

    public init() {
        let toHost = ChunkQueue()
        let toClient = ChunkQueue()
        client = PipeEnd(incoming: toClient, outgoing: toHost, peer: toHost)
        host = PipeEnd(incoming: toHost, outgoing: toClient, peer: toClient)
    }

    public func close() async {
        await client.close()
        await host.close()
    }
}

final class PipeEnd: ByteStream, @unchecked Sendable {
    private let incoming: ChunkQueue
    private let outgoing: ChunkQueue
    private let peer: ChunkQueue
    private var pending = Data()

    init(incoming: ChunkQueue, outgoing: ChunkQueue, peer: ChunkQueue) {
        self.incoming = incoming
        self.outgoing = outgoing
        self.peer = peer
    }

    func send(_ data: Data) async throws {
        outgoing.push(data)
    }

    func receive(maximumLength: Int) async throws -> Data {
        if !pending.isEmpty {
            let count = min(maximumLength, pending.count)
            let slice = Data(pending.prefix(count))
            pending.removeFirst(count)
            return slice
        }
        let chunk = try await incoming.pop()
        if chunk.count <= maximumLength { return chunk }
        pending = Data(chunk.dropFirst(maximumLength))
        return Data(chunk.prefix(maximumLength))
    }

    func close() async {
        outgoing.close()
        incoming.close()
        peer.close()
    }
}

/// Reads one length-prefixed frame from a live stream. Used when the Mac dials the phone
/// before the normal handshake starts.
public final class FrameReader: @unchecked Sendable {
    private let stream: NWByteStream
    private var decoder = FrameDecoder()

    public init(stream: NWByteStream) {
        self.stream = stream
    }

    public func nextPayload() async throws -> Data {
        while true {
            if let payload = try decoder.pop() { return payload }
            let chunk = try await stream.receive(maximumLength: 64 * 1024)
            if chunk.isEmpty {
                await Task.yield()
                continue
            }
            decoder.append(chunk)
        }
    }
}

public enum SessionDial {
    public static func encode(hostId: String, hostName: String) throws -> Data {
        var header = Header()
        header.op = "dial"
        header.hostId = hostId
        header.hostName = hostName
        let message = WireMessage(kind: .request, header: header)
        return try FrameCodec.encode(payload: try message.encode())
    }

    public static func decode(_ payload: Data) throws -> (hostId: String, hostName: String) {
        let message = try WireMessage.decode(payload)
        guard message.header.op == "dial", let hostId = message.header.hostId, !hostId.isEmpty else {
            throw ProtocolFailure.malformed
        }
        return (hostId, message.header.hostName ?? "Mac")
    }
}
