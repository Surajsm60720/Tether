import Foundation
import Network

public enum RelayError: Error, Equatable, Sendable {
    case unreachable
    case rejected
    case busy
    case badPrelude
}

/// Joins a Mac and an iPhone that cannot see each other. Both dial out.
/// After the one-line prelude, the two TCP connections are spliced and the normal Tether handshake runs.
/// The relay never sees the pairing key or file bytes in the clear.
public enum RelayClient {
    public enum Role: Sendable {
        case host
        case client
    }

    public static func open(role: Role, address: RemoteAddress, token: Data) async throws -> NWByteStream {
        let stream = NWByteStream(connection: NWConnection(
            to: address.endpoint,
            using: TetherLink.parameters(allowsCellular: true)
        ))
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    try await stream.start()
                    try await exchange(role: role, token: token, stream: stream)
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(20))
                    throw RelayError.unreachable
                }
                do {
                    try await group.next()
                    group.cancelAll()
                } catch {
                    group.cancelAll()
                    throw error
                }
            }
            return stream
        } catch {
            await stream.close()
            throw error
        }
    }

    private static func exchange(role: Role, token: Data, stream: NWByteStream) async throws {
        guard token.count == 32 else { throw RelayError.badPrelude }
        let verb = role == .host ? "HOST" : "OPEN"
        try await stream.send(Data("\(verb) \(Base64URL.encode(token))\n".utf8))
        var buffer = Data()
        while true {
            let line = try await readLine(from: stream, buffer: &buffer, limit: 80)
            switch line {
            case "GO":
                stream.prefix(buffer)
                return
            case "WAIT":
                continue
            case "BUSY":
                throw RelayError.busy
            case "NO":
                throw RelayError.rejected
            default:
                throw RelayError.badPrelude
            }
        }
    }

    private static func readLine(from stream: NWByteStream, buffer: inout Data, limit: Int) async throws -> String {
        while true {
            if let newline = buffer.firstIndex(of: 10) {
                let line = Data(buffer[..<newline])
                buffer.removeSubrange(..<buffer.index(after: newline))
                var text = String(decoding: line, as: UTF8.self)
                if text.hasSuffix("\r") { text.removeLast() }
                return text
            }
            if buffer.count > limit { throw RelayError.badPrelude }
            let chunk = try await stream.receive(maximumLength: 256)
            if chunk.isEmpty {
                await Task.yield()
                continue
            }
            buffer.append(chunk)
        }
    }
}

public final class RelayServer: @unchecked Sendable {
    public private(set) var port: UInt16 = 0
    private let listener: NWListener
    private let registry = RelayRegistry()
    private let queue = DispatchQueue(label: "app.tether.relay")

    public static func start(port: UInt16 = 0) async throws -> RelayServer {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        let parameters = NWParameters(tls: nil, tcp: tcp)
        let bound: NWEndpoint.Port = port == 0 ? .any : (NWEndpoint.Port(rawValue: port) ?? .any)
        let listener = try NWListener(using: parameters, on: bound)
        let server = RelayServer(listener: listener)
        try await server.waitUntilReady()
        return server
    }

    private init(listener: NWListener) {
        self.listener = listener
    }

    public func stop() {
        listener.cancel()
        Task { await registry.cancelAll() }
    }

    private func waitUntilReady() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let gate = ResumeGate()
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    self?.port = self?.listener.port?.rawValue ?? 0
                    gate.resume(continuation)
                case .failed(let error):
                    gate.fail(continuation, error)
                case .cancelled:
                    gate.fail(continuation, RelayError.unreachable)
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { return }
                Task { await self.accept(connection) }
            }
            listener.start(queue: queue)
        }
        if port == 0 {
            port = listener.port?.rawValue ?? 0
        }
    }

    private func accept(_ connection: NWConnection) async {
        let io = ConnectionIO(connection)
        do {
            try await io.start()
            let line = try await io.readLine(limit: 200)
            let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard parts.count == 2 else {
                try? await io.send(Data("NO\n".utf8))
                io.cancel()
                return
            }
            let kind = String(parts[0])
            guard let token = try? Base64URL.decode(String(parts[1])), token.count == 32 else {
                try? await io.send(Data("NO\n".utf8))
                io.cancel()
                return
            }
            let key = Base64URL.encode(token)
            switch await registry.arrive(kind: kind, token: key, io: io) {
            case let .wait(replaced):
                replaced?.cancel()
                do {
                    try await io.send(Data("WAIT\n".utf8))
                    await io.waitUntilClosed()
                } catch {
                    io.cancel()
                }
                await registry.removeIfWaiting(token: key, io: io)
            case .busy:
                try? await io.send(Data("BUSY\n".utf8))
                io.cancel()
            case .reject:
                try? await io.send(Data("NO\n".utf8))
                io.cancel()
            case let .bridge(host, client, replaced):
                replaced?.cancel()
                do {
                    try await host.send(Data("GO\n".utf8))
                    try await client.send(Data("GO\n".utf8))
                    let toClient = host.takeBuffered()
                    let toHost = client.takeBuffered()
                    await splice(host: host, client: client, toClient: toClient, toHost: toHost)
                } catch {
                    host.cancel()
                    client.cancel()
                }
                await registry.finish(key)
            }
        } catch {
            io.cancel()
        }
    }

    private func splice(host: ConnectionIO, client: ConnectionIO, toClient: Data, toHost: Data) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.forward(from: host, to: client, initial: toClient) }
            group.addTask { await self.forward(from: client, to: host, initial: toHost) }
            _ = await group.next()
            group.cancelAll()
        }
        host.cancel()
        client.cancel()
    }

    private func forward(from source: ConnectionIO, to destination: ConnectionIO, initial: Data) async {
        do {
            if !initial.isEmpty {
                try await destination.send(initial)
            }
            while !Task.isCancelled {
                guard let chunk = try await source.receiveChunk() else { return }
                if chunk.isEmpty { continue }
                try await destination.send(chunk)
            }
        } catch {
            return
        }
    }
}

private final class ConnectionIO: @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "app.tether.relay.io")
    private var buffer = Data()

    init(_ connection: NWConnection) {
        self.connection = connection
    }

    func start() async throws {
        try await withTaskCancellationHandler {
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
        } onCancel: {
            self.connection.cancel()
        }
    }

    func readLine(limit: Int) async throws -> String {
        while true {
            if let newline = buffer.firstIndex(of: 10) {
                let line = Data(buffer[..<newline])
                buffer.removeSubrange(..<buffer.index(after: newline))
                var text = String(decoding: line, as: UTF8.self)
                if text.hasSuffix("\r") { text.removeLast() }
                return text
            }
            if buffer.count > limit { throw RelayError.badPrelude }
            guard let chunk = try await receiveChunk() else { throw RelayError.unreachable }
            if chunk.isEmpty { continue }
            buffer.append(chunk)
        }
    }

    func takeBuffered() -> Data {
        let extra = buffer
        buffer.removeAll(keepingCapacity: false)
        return extra
    }

    func send(_ data: Data) async throws {
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

    func receiveChunk() async throws -> Data? {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data?, Error>) in
                let gate = OnceGate<Data?>()
                connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { content, _, isComplete, error in
                    if let error {
                        gate.fail(continuation, error)
                        return
                    }
                    if let content, !content.isEmpty {
                        gate.resume(continuation, returning: content)
                        return
                    }
                    if isComplete {
                        gate.resume(continuation, returning: nil)
                        return
                    }
                    gate.resume(continuation, returning: Data())
                }
            }
        } onCancel: {
            self.connection.cancel()
        }
    }

    func waitUntilClosed() async {
        if isClosed { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let gate = CloseGate()
            connection.stateUpdateHandler = { state in
                switch state {
                case .cancelled, .failed:
                    gate.resume(continuation)
                default:
                    break
                }
            }
            if self.isClosed { gate.resume(continuation) }
        }
    }

    private var isClosed: Bool {
        switch connection.state {
        case .cancelled, .failed: true
        default: false
        }
    }

    func cancel() {
        connection.cancel()
    }
}

private final class CloseGate: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func resume(_ continuation: CheckedContinuation<Void, Never>) {
        lock.lock()
        let should = !done
        done = true
        lock.unlock()
        if should { continuation.resume() }
    }
}

private final class OnceGate<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func resume(_ continuation: CheckedContinuation<T, Error>, returning value: T) {
        lock.lock()
        let should = !done
        done = true
        lock.unlock()
        if should { continuation.resume(returning: value) }
    }

    func fail(_ continuation: CheckedContinuation<T, Error>, _ error: Error) {
        lock.lock()
        let should = !done
        done = true
        lock.unlock()
        if should { continuation.resume(throwing: error) }
    }
}

private actor RelayRegistry {
    private struct Slot {
        var host: ConnectionIO?
        var client: ConnectionIO?
        var busy = false
    }

    enum Arrival: Sendable {
        case wait(ConnectionIO?)
        case busy
        case reject
        case bridge(host: ConnectionIO, client: ConnectionIO, replaced: ConnectionIO?)
    }

    private var slots: [String: Slot] = [:]

    func arrive(kind: String, token: String, io: ConnectionIO) -> Arrival {
        var slot = slots[token] ?? Slot()
        if slot.busy { return .busy }
        switch kind {
        case "HOST":
            let replaced = slot.host
            slot.host = io
            if let client = slot.client {
                slot.host = nil
                slot.client = nil
                slot.busy = true
                slots[token] = slot
                return .bridge(host: io, client: client, replaced: replaced)
            }
            slots[token] = slot
            return .wait(replaced)
        case "OPEN":
            let replaced = slot.client
            slot.client = io
            if let host = slot.host {
                slot.host = nil
                slot.client = nil
                slot.busy = true
                slots[token] = slot
                return .bridge(host: host, client: io, replaced: replaced)
            }
            slots[token] = slot
            return .wait(replaced)
        default:
            return .reject
        }
    }

    func finish(_ token: String) {
        slots[token] = nil
    }

    func removeIfWaiting(token: String, io: ConnectionIO) {
        guard var slot = slots[token], !slot.busy else { return }
        if slot.host === io { slot.host = nil }
        if slot.client === io { slot.client = nil }
        if slot.host == nil, slot.client == nil {
            slots[token] = nil
        } else {
            slots[token] = slot
        }
    }

    func cancelAll() {
        let pending = slots
        slots.removeAll()
        for slot in pending.values {
            slot.host?.cancel()
            slot.client?.cancel()
        }
    }
}
