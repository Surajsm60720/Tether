import CryptoKit
import Foundation

public struct ApprovalRequest: Sendable {
    public var deviceId: String
    public var deviceName: String
    public var shares: [ShareInfo]
    public var pairing: Bool

    public init(deviceId: String, deviceName: String, shares: [ShareInfo], pairing: Bool) {
        self.deviceId = deviceId
        self.deviceName = deviceName
        self.shares = shares
        self.pairing = pairing
    }
}

/// Host-side callbacks. Implementations must be safe to call off the main thread.
public protocol HostServing: Sendable {
    var hostId: String { get }
    func hostName() -> String
    func currentOffer() -> PairingOffer?
    func consumeOffer()
    func deviceKey(for deviceId: String) -> SymmetricKey?
    func rememberDevice(id: String, name: String, key: SymmetricKey)
    func sessionApprovalRequired() -> Bool
    func decide(_ request: ApprovalRequest) async -> Bool
    func note(_ event: String)
    func connected(deviceId: String, name: String)
    func disconnected(deviceId: String)
    func files() -> any FileProvider
    func thumbnail(virtualPath: String, maxPixel: Int) async -> Data?
    var abuse: AbuseGuard { get }
    func watchConnection(for deviceId: String, close: @escaping @Sendable () -> Void)
    func ignoreConnection(for deviceId: String)
    /// Runs a command the virtual interpreter does not implement, on the Mac.
    func runShell(line: String, cwd: String) async -> TerminalResult?
}

public enum HandshakeMode: Sendable {
    case pair(PairingPayload)
    case session(hostId: String, key: SymmetricKey)

    var secret: SymmetricKey {
        switch self {
        case let .pair(payload): payload.secret
        case let .session(_, key): key
        }
    }

    var expectedHostId: String {
        switch self {
        case let .pair(payload): payload.hostId
        case let .session(hostId, _): hostId
        }
    }

    var wire: String {
        switch self {
        case .pair: SessionMode.pair.rawValue
        case .session: SessionMode.session.rawValue
        }
    }

    var material: String? {
        if case let .pair(payload) = self { return payload.material.rawValue }
        return nil
    }
}

public enum HostConnection {
    public static func serve(stream: any ByteStream, remote: String, server: any HostServing) async {
        let session = HostSession(stream: stream, remote: remote, server: server)
        await session.run()
    }
}

private actor HostSession {
    private let stream: any ByteStream
    private let remote: String
    private let server: any HostServing
    private var decoder = FrameDecoder()
    private var channel: SecureChannel?
    private var closed = false
    private var deviceId = ""
    private var deviceName = ""
    private let terminal = TerminalEngine()
    private let sampler = SystemSampler()

    init(stream: any ByteStream, remote: String, server: any HostServing) {
        self.stream = stream
        self.remote = remote
        self.server = server
    }

    func run() async {
        var announced = false
        do {
            let identity = try await handshake()
            deviceId = identity.id
            deviceName = identity.name
            announced = true
            let closer = stream
            server.watchConnection(for: identity.id) {
                Task { await closer.close() }
            }
            server.connected(deviceId: deviceId, name: deviceName)
            server.note("\(deviceName) connected")
            while !closed {
                let message = try await nextMessage()
                try await handle(message)
            }
        } catch {
            TetherLog.transport.debug("host session closed")
        }
        if announced {
            server.ignoreConnection(for: deviceId)
            server.disconnected(deviceId: deviceId)
            server.note("\(deviceName) disconnected")
        }
        await stream.close()
    }

    private func handshake() async throws -> (id: String, name: String) {
        let hello = try await nextMessage()
        guard hello.header.op == Op.clientHello, hello.header.v == TetherCoreInfo.protocolVersion else {
            await reject(ProtocolFailure(code: .badRequest, message: "This Mac speaks a different Tether version."))
            throw ProtocolFailure.malformed
        }
        guard let deviceId = hello.header.deviceId, !deviceId.isEmpty, let nonceC = hello.header.nonceC, nonceC.count == 32 else {
            await reject(ProtocolFailure.malformed)
            throw ProtocolFailure.malformed
        }
        let mode = SessionMode(rawValue: hello.header.mode ?? "") ?? .session
        let secret: SymmetricKey
        switch mode {
        case .pair:
            if server.abuse.isPairingLocked() {
                await reject(ProtocolFailure.locked)
                throw ProtocolFailure.locked
            }
            guard let offer = server.currentOffer(), !offer.isExpired else {
                await reject(ProtocolFailure.expired)
                throw ProtocolFailure.expired
            }
            let material = PairMaterial(rawValue: hello.header.material ?? "") ?? .full
            secret = offer.secret(for: material)
        case .session:
            guard let key = server.deviceKey(for: deviceId) else {
                await reject(ProtocolFailure.revoked)
                throw ProtocolFailure.revoked
            }
            secret = key
        }

        let nonceH = SymmetricKey.random().raw
        var reply = Header()
        reply.op = Op.hostHello
        reply.v = TetherCoreInfo.protocolVersion
        reply.hostId = server.hostId
        reply.hostName = server.hostName()
        reply.nonceH = nonceH
        try await send(WireMessage(kind: .response, header: reply))
        channel = SecureChannel(role: .host, secret: secret, nonceC: nonceC, nonceH: nonceH)

        let auth: WireMessage
        do {
            auth = try await nextMessage()
        } catch {
            server.abuse.recordHandshakeFailure(remote)
            if mode == .pair { server.abuse.recordPairingFailure() }
            throw error
        }
        guard auth.header.op == Op.auth else {
            server.abuse.recordHandshakeFailure(remote)
            throw ProtocolFailure(code: .unauthorized, message: "Couldn't verify the connection.")
        }

        if mode == .session && server.sessionApprovalRequired() {
            let shares = await server.files().shares()
            let allowed = await server.decide(ApprovalRequest(
                deviceId: deviceId,
                deviceName: hello.header.deviceName ?? deviceId,
                shares: shares,
                pairing: false
            ))
            if !allowed {
                await reject(ProtocolFailure.denied)
                throw ProtocolFailure.denied
            }
        }

        var ok = Header()
        ok.op = Op.authOK
        ok.requestId = auth.header.requestId
        ok.ok = true
        try await send(WireMessage(kind: .response, header: ok))

        if mode == .pair {
            let request = try await nextMessage()
            guard request.header.op == Op.pairRequest else { throw ProtocolFailure.malformed }
            let name = request.header.deviceName ?? hello.header.deviceName ?? "iPhone"
            let shares = await server.files().shares()
            let allowed = await server.decide(ApprovalRequest(deviceId: deviceId, deviceName: name, shares: shares, pairing: true))
            guard allowed else {
                await reject(ProtocolFailure.denied, requestId: request.header.requestId)
                throw ProtocolFailure.denied
            }
            let key = SymmetricKey.random()
            server.rememberDevice(id: deviceId, name: name, key: key)
            server.consumeOffer()
            var done = Header()
            done.op = Op.pairComplete
            done.requestId = request.header.requestId
            done.ok = true
            done.hostId = server.hostId
            done.hostName = server.hostName()
            done.deviceKey = key.raw
            try await send(WireMessage(kind: .response, header: done))
            return (deviceId, name)
        }

        let name = hello.header.deviceName ?? "iPhone"
        return (deviceId, name)
    }

    private func handle(_ message: WireMessage) async throws {
        do {
            try await dispatch(message)
        } catch {
            let failure = (error as? ProtocolFailure) ?? ProtocolFailure(
                code: .internalError,
                message: "Something went wrong."
            )
            await reject(failure, requestId: message.header.requestId)
        }
    }

    private func dispatch(_ message: WireMessage) async throws {
        let files = server.files()
        var header = Header()
        header.requestId = message.header.requestId
        header.ok = true
        let op = message.header.op ?? ""
        switch op {
        case Op.ping:
            try await send(WireMessage(kind: .response, header: header))
        case Op.shares:
            header.shares = await files.shares()
            try await send(WireMessage(kind: .response, header: header))
        case Op.list:
            let path = try VirtualPath.parse(message.header.path ?? "/")
            let entries = try await files.list(
                path: path,
                offset: Int(message.header.offset ?? 0),
                limit: message.header.limit ?? 1000,
                includeHidden: message.header.all ?? false
            )
            header.entries = entries
            server.note("Listed \(path.string)")
            try await send(WireMessage(kind: .response, header: header))
        case Op.stat:
            let path = try VirtualPath.parse(message.header.path ?? "/")
            header.entry = try await files.stat(path: path)
            try await send(WireMessage(kind: .response, header: header))
        case Op.read:
            let path = try VirtualPath.parse(message.header.path ?? "")
            let chunk = try await files.read(path: path, offset: message.header.offset ?? 0, length: message.header.length ?? TetherCoreInfo.chunkSize)
            header.eof = chunk.eof
            header.totalSize = chunk.totalSize
            if message.header.offset == 0 { server.note("Read \(path.string)") }
            try await send(WireMessage(kind: .response, header: header, body: chunk.data))
        case Op.thumb:
            let path = message.header.path ?? ""
            let pixels = message.header.maxPixel ?? 200
            guard let jpeg = await server.thumbnail(virtualPath: path, maxPixel: pixels), !jpeg.isEmpty else {
                throw ProtocolFailure(code: .notFound, message: "No preview for that item.")
            }
            let body = jpeg.prefix(256 * 1024)
            try await send(WireMessage(kind: .response, header: header, body: Data(body)))
        case Op.writeBegin:
            let path = try VirtualPath.parse(message.header.path ?? "")
            let upload = try await files.beginUpload(path: path, size: message.header.size ?? 0, overwrite: message.header.overwrite ?? false)
            header.uploadId = upload
            server.note("Upload started \(path.string)")
            try await send(WireMessage(kind: .response, header: header))
        case Op.writeChunk:
            guard let id = message.header.uploadId else { throw ProtocolFailure.malformed }
            header.received = try await files.uploadChunk(id: id, offset: message.header.offset ?? 0, data: message.body)
            try await send(WireMessage(kind: .response, header: header))
        case Op.writeCommit:
            guard let id = message.header.uploadId else { throw ProtocolFailure.malformed }
            try await files.commitUpload(id: id)
            server.note("Upload finished")
            try await send(WireMessage(kind: .response, header: header))
        case Op.writeAbort:
            if let id = message.header.uploadId {
                try await files.abortUpload(id: id)
            }
            try await send(WireMessage(kind: .response, header: header))
        case Op.sysInfo:
            let shares = await files.shares()
            header.systemProfile = SystemProbe.profile(hostName: server.hostName(), shareCount: shares.count)
            try await send(WireMessage(kind: .response, header: header))
        case Op.sysStats:
            header.systemStats = await sampler.stats()
            try await send(WireMessage(kind: .response, header: header))
        case Op.termExec:
            let cwd = message.header.cwd ?? "/"
            let line = message.header.line ?? ""
            let result: TerminalResult
            if TerminalSyntax.requiresShell(line), let shell = await server.runShell(line: line, cwd: cwd) {
                result = shell
            } else {
                let shares = await files.shares()
                let profile = SystemProbe.profile(hostName: server.hostName(), shareCount: shares.count)
                let context = TerminalContext(
                    user: profile.user,
                    host: server.hostName(),
                    device: deviceName.isEmpty ? "this iPhone" : deviceName,
                    profile: profile
                )
                let virtual = await terminal.execute(line: line, cwd: cwd, files: files, context: context)
                if virtual.exit == 127, let shell = await server.runShell(line: line, cwd: cwd) {
                    result = shell
                } else {
                    result = virtual
                }
            }
            header.stdout = result.stdout
            header.stderr = result.stderr
            header.cwd = result.cwd
            header.exit = result.exit
            header.action = result.action
            server.note("Terminal")
            try await send(WireMessage(kind: .response, header: header))
        default:
            throw ProtocolFailure(code: .badRequest, message: "That request isn't supported.")
        }
    }

    private func reject(_ failure: ProtocolFailure, requestId: UInt64? = nil) async {
        var header = Header()
        header.ok = false
        header.error = failure
        header.requestId = requestId
        try? await send(WireMessage(kind: .response, header: header))
    }

    private func send(_ message: WireMessage) async throws {
        var payload = try message.encode()
        if var crypto = channel {
            payload = try crypto.seal(payload)
            channel = crypto
        }
        try await stream.send(try FrameCodec.encode(payload: payload))
    }

    private func nextMessage() async throws -> WireMessage {
        while !closed {
            if let payload = try decoder.pop() {
                if var crypto = channel {
                    let plain = try crypto.open(payload)
                    channel = crypto
                    return try WireMessage.decode(plain)
                }
                return try WireMessage.decode(payload)
            }
            let chunk = try await stream.receive(maximumLength: 64 * 1024)
            if chunk.isEmpty {
                await Task.yield()
                continue
            }
            decoder.append(chunk)
        }
        throw StreamError.closed
    }
}

public actor ClientConnection {
    private let stream: any ByteStream
    private var decoder = FrameDecoder()
    private var channel: SecureChannel?
    private var waiters: [UInt64: WaitBox] = [:]
    private var nextID: UInt64 = 1
    private var closed = false
    private var loop: Task<Void, Never>?
    private var heartbeat: Task<Void, Never>?
    private var lastReceived = Date()
    private var disconnectHandler: (@Sendable () -> Void)?

    public private(set) var hostId: String = ""
    public private(set) var hostName: String = ""
    public private(set) var receivedDeviceKey: Data?

    public init(stream: any ByteStream) {
        self.stream = stream
    }

    public var onDisconnect: (@Sendable () -> Void)? {
        get { disconnectHandler }
        set { disconnectHandler = newValue }
    }

    public static func establish(
        stream: any ByteStream,
        deviceId: String,
        deviceName: String,
        mode: HandshakeMode
    ) async throws -> ClientConnection {
        let connection = ClientConnection(stream: stream)
        try await connection.handshake(deviceId: deviceId, deviceName: deviceName, mode: mode)
        await connection.startBackground()
        return connection
    }

    public func ping() async throws {
        var header = Header()
        header.op = Op.ping
        _ = try await roundTrip(header, timeout: .seconds(10))
    }

    public func shares() async throws -> [ShareInfo] {
        var header = Header()
        header.op = Op.shares
        let reply = try await roundTrip(header, timeout: .seconds(10))
        return reply.header.shares ?? []
    }

    public func list(path: String, offset: Int = 0, limit: Int = 1000, includeHidden: Bool = false) async throws -> [FileEntry] {
        var header = Header()
        header.op = Op.list
        header.path = path
        header.offset = UInt64(offset)
        header.limit = limit
        header.all = includeHidden
        let reply = try await roundTrip(header, timeout: .seconds(10))
        return reply.header.entries ?? []
    }

    public func stat(path: String) async throws -> FileEntry {
        var header = Header()
        header.op = Op.stat
        header.path = path
        let reply = try await roundTrip(header, timeout: .seconds(10))
        guard let entry = reply.header.entry else { throw ProtocolFailure(code: .notFound, message: "That item isn't here.") }
        return entry
    }

    public func read(path: String, offset: UInt64, length: Int) async throws -> ReadChunk {
        var header = Header()
        header.op = Op.read
        header.path = path
        header.offset = offset
        header.length = length
        let reply = try await roundTrip(header, timeout: .seconds(30))
        return ReadChunk(data: reply.body, eof: reply.header.eof ?? true, totalSize: reply.header.totalSize ?? UInt64(reply.body.count))
    }

    public func thumbnail(path: String, maxPixel: Int) async throws -> Data {
        var header = Header()
        header.op = Op.thumb
        header.path = path
        header.maxPixel = maxPixel
        let reply = try await roundTrip(header, timeout: .seconds(15))
        return reply.body
    }

    public func download(
        path: String,
        to destination: URL,
        progress: @escaping @Sendable (UInt64, UInt64) -> Void
    ) async throws {
        let temp = destination.appendingPathExtension("partial")
        FileManager.default.createFile(atPath: temp.path, contents: nil)
        let handle = try FileHandle(forWritingTo: temp)
        var finished = false
        defer {
            try? handle.close()
            if !finished { try? FileManager.default.removeItem(at: temp) }
        }
        let first = try await read(path: path, offset: 0, length: TetherCoreInfo.chunkSize)
        let total = first.totalSize
        if !first.data.isEmpty {
            try handle.write(contentsOf: first.data)
            progress(UInt64(first.data.count), total)
        }
        var completed = UInt64(first.data.count)
        if !first.eof, completed < total {
            var nextRequest = completed
            var inflight: [UInt64: Task<ReadChunk, Error>] = [:]
            func fill() {
                while inflight.count < TetherCoreInfo.transferPipelineDepth, nextRequest < total {
                    let offset = nextRequest
                    let length = Int(min(UInt64(TetherCoreInfo.chunkSize), total - offset))
                    nextRequest += UInt64(length)
                    inflight[offset] = Task {
                        try await self.read(path: path, offset: offset, length: length)
                    }
                }
            }
            fill()
            while completed < total {
                if Task.isCancelled {
                    inflight.values.forEach { $0.cancel() }
                    throw CancellationError()
                }
                guard let task = inflight.removeValue(forKey: completed) else {
                    throw ProtocolFailure(code: .internalError, message: "The download ended early.")
                }
                let chunk = try await task.value
                if chunk.data.isEmpty {
                    throw ProtocolFailure(code: .internalError, message: "The download ended early.")
                }
                try handle.write(contentsOf: chunk.data)
                completed += UInt64(chunk.data.count)
                progress(completed, total)
                fill()
            }
        }
        if Task.isCancelled {
            try? FileManager.default.removeItem(at: temp)
            throw CancellationError()
        }
        guard total == 0 || completed == total else {
            try? FileManager.default.removeItem(at: temp)
            throw ProtocolFailure(code: .internalError, message: "The download ended early.")
        }
        try handle.close()
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: temp, to: destination)
        finished = true
    }

    public func upload(
        file: URL,
        toDirectory directory: String,
        fileName: String,
        overwrite: Bool = false,
        progress: @escaping @Sendable (UInt64, UInt64) -> Void
    ) async throws {
        let values = try file.resourceValues(forKeys: [.fileSizeKey])
        let size = UInt64(values.fileSize ?? 0)
        let virtual = directory == "/" ? "/\(fileName)" : directory + "/" + fileName
        var begin = Header()
        begin.op = Op.writeBegin
        begin.path = virtual
        begin.size = size
        begin.overwrite = overwrite
        let started = try await roundTrip(begin, timeout: .seconds(15))
        guard let uploadId = started.header.uploadId else {
            throw ProtocolFailure(code: .internalError, message: "The Mac didn't accept the upload.")
        }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var sent: UInt64 = 0
        var confirmed: UInt64 = 0
        var window: [(count: Int, task: Task<Void, Error>)] = []
        do {
            while confirmed < size {
                while window.count < TetherCoreInfo.transferPipelineDepth, sent < size {
                    if Task.isCancelled { throw CancellationError() }
                    let data = try handle.read(upToCount: TetherCoreInfo.chunkSize) ?? Data()
                    if data.isEmpty { break }
                    let offset = sent
                    sent += UInt64(data.count)
                    let count = data.count
                    window.append((count, Task {
                        var chunk = Header()
                        chunk.op = Op.writeChunk
                        chunk.uploadId = uploadId
                        chunk.offset = offset
                        _ = try await self.roundTrip(chunk, body: data, timeout: .seconds(30))
                    }))
                }
                if window.isEmpty { break }
                let head = window.removeFirst()
                try await head.task.value
                confirmed += UInt64(head.count)
                progress(confirmed, size)
            }
            var commit = Header()
            commit.op = Op.writeCommit
            commit.uploadId = uploadId
            _ = try await roundTrip(commit, timeout: .seconds(30))
        } catch {
            var abort = Header()
            abort.op = Op.writeAbort
            abort.uploadId = uploadId
            _ = try? await roundTrip(abort, timeout: .seconds(5))
            throw error
        }
    }

    public func systemProfile() async throws -> SystemProfile {
        var header = Header()
        header.op = Op.sysInfo
        let reply = try await roundTrip(header, timeout: .seconds(8))
        guard let profile = reply.header.systemProfile else { throw ProtocolFailure.malformed }
        return profile
    }

    public func systemStats() async throws -> SystemStats {
        var header = Header()
        header.op = Op.sysStats
        let reply = try await roundTrip(header, timeout: .seconds(8))
        guard let stats = reply.header.systemStats else { throw ProtocolFailure.malformed }
        return stats
    }

    public func exec(cwd: String, line: String) async throws -> TerminalResult {
        var header = Header()
        header.op = Op.termExec
        header.cwd = cwd
        header.line = line
        let reply = try await roundTrip(header, timeout: .seconds(20))
        return TerminalResult(
            stdout: reply.header.stdout ?? "",
            stderr: reply.header.stderr ?? "",
            cwd: reply.header.cwd ?? cwd,
            exit: reply.header.exit ?? 0,
            action: reply.header.action
        )
    }

    public func close() async {
        await shutdown(notify: false)
    }

    private func handshake(deviceId: String, deviceName: String, mode: HandshakeMode) async throws {
        let nonceC = SymmetricKey.random().raw
        var hello = Header()
        hello.op = Op.clientHello
        hello.v = TetherCoreInfo.protocolVersion
        hello.deviceId = deviceId
        hello.deviceName = deviceName
        hello.nonceC = nonceC
        hello.mode = mode.wire
        hello.material = mode.material
        try await send(WireMessage(kind: .request, header: hello))

        let reply = try await nextMessage()
        if reply.header.ok == false {
            throw reply.header.error ?? ProtocolFailure(code: .unauthorized, message: "The Mac declined the connection.")
        }
        guard reply.header.op == Op.hostHello,
              reply.header.v == TetherCoreInfo.protocolVersion,
              let nonceH = reply.header.nonceH
        else {
            throw ProtocolFailure.malformed
        }
        // The pairing secret authenticates the Mac. The id in the code is only used to
        // pick a Bonjour result, so a missing TXT record must not abort a matching secret.
        hostId = reply.header.hostId ?? mode.expectedHostId
        hostName = reply.header.hostName ?? "Mac"
        if reply.header.hostId != mode.expectedHostId, !mode.expectedHostId.hasPrefix("name:") {
            TetherLog.pairing.debug("connected host id differs from the code; continuing because the pairing secret matches")
        }
        channel = SecureChannel(role: .client, secret: mode.secret, nonceC: nonceC, nonceH: nonceH)

        var auth = Header()
        auth.op = Op.auth
        auth.requestId = takeID()
        try await send(WireMessage(kind: .request, header: auth))
        let authReply = try await nextMessage()
        if authReply.header.ok == false {
            throw authReply.header.error ?? ProtocolFailure(code: .unauthorized, message: "Couldn't verify the connection.")
        }

        if case .pair = mode {
            var request = Header()
            request.op = Op.pairRequest
            request.requestId = takeID()
            request.deviceId = deviceId
            request.deviceName = deviceName
            try await send(WireMessage(kind: .request, header: request))
            let complete = try await nextMessage()
            if complete.header.ok == false {
                throw complete.header.error ?? ProtocolFailure.denied
            }
            guard let key = complete.header.deviceKey, key.count == 32 else {
                throw ProtocolFailure.malformed
            }
            receivedDeviceKey = key
            if let name = complete.header.hostName { hostName = name }
            if let id = complete.header.hostId { hostId = id }
        }
        lastReceived = Date()
    }

    private func startBackground() {
        loop = Task { await self.readLoop() }
        heartbeat = Task { await self.beat() }
    }

    private func readLoop() async {
        do {
            while !closed {
                let message = try await nextMessage()
                lastReceived = Date()
                deliver(message)
            }
        } catch {
            failAll(error)
            await shutdown(notify: true)
        }
    }

    private func beat() async {
        while !closed {
            try? await Task.sleep(for: .seconds(10))
            if closed { return }
            if Date().timeIntervalSince(lastReceived) > 45 {
                await shutdown(notify: true)
                return
            }
            var header = Header()
            header.op = Op.ping
            _ = try? await roundTrip(header, timeout: .seconds(20))
        }
    }

    private func roundTrip(_ header: Header, body: Data = Data(), timeout: Duration) async throws -> WireMessage {
        var header = header
        if header.requestId == nil { header.requestId = takeID() }
        let id = header.requestId ?? 0
        let box = WaitBox()
        waiters[id] = box
        do {
            try await send(WireMessage(kind: .request, header: header, body: body))
        } catch {
            waiters[id] = nil
            throw error
        }
        do {
            let reply = try await withThrowingTaskGroup(of: WireMessage.self) { group in
                group.addTask { try await box.value() }
                group.addTask {
                    try await Task.sleep(for: timeout)
                    throw ProtocolFailure.timeout
                }
                guard let value = try await group.next() else { throw ProtocolFailure.timeout }
                group.cancelAll()
                return value
            }
            waiters[id] = nil
            return reply
        } catch {
            box.finish(.failure(error))
            waiters[id] = nil
            throw error
        }
    }

    private func deliver(_ message: WireMessage) {
        guard let id = message.header.requestId, let box = waiters.removeValue(forKey: id) else { return }
        if message.header.ok == false {
            box.finish(.failure(message.header.error ?? ProtocolFailure.malformed))
        } else {
            box.finish(.success(message))
        }
    }

    private func failAll(_ error: Error) {
        let pending = waiters
        waiters.removeAll()
        for box in pending.values {
            box.finish(.failure(error))
        }
    }

    private func shutdown(notify: Bool) async {
        guard !closed else { return }
        closed = true
        loop?.cancel()
        heartbeat?.cancel()
        failAll(StreamError.closed)
        await stream.close()
        if notify { disconnectHandler?() }
    }

    private func send(_ message: WireMessage) async throws {
        var payload = try message.encode()
        if var crypto = channel {
            payload = try crypto.seal(payload)
            channel = crypto
        }
        try await stream.send(try FrameCodec.encode(payload: payload))
    }

    private func nextMessage() async throws -> WireMessage {
        while !closed {
            if let payload = try decoder.pop() {
                if var crypto = channel {
                    let plain = try crypto.open(payload)
                    channel = crypto
                    return try WireMessage.decode(plain)
                }
                return try WireMessage.decode(payload)
            }
            let chunk = try await stream.receive(maximumLength: 64 * 1024)
            if chunk.isEmpty {
                await Task.yield()
                continue
            }
            decoder.append(chunk)
        }
        throw StreamError.closed
    }

    private func takeID() -> UInt64 {
        let id = nextID
        nextID += 1
        return id
    }
}

final class WaitBox: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<WireMessage, Error>?
    private var result: Result<WireMessage, Error>?

    func value() async throws -> WireMessage {
        try await withCheckedThrowingContinuation { continuation in
            if let existing = claim(continuation) {
                continuation.resume(with: existing)
            }
        }
    }

    private func claim(_ continuation: CheckedContinuation<WireMessage, Error>) -> Result<WireMessage, Error>? {
        lock.lock()
        defer { lock.unlock() }
        if let result { return result }
        self.continuation = continuation
        return nil
    }

    func finish(_ result: Result<WireMessage, Error>) {
        lock.lock()
        if self.result != nil {
            lock.unlock()
            return
        }
        self.result = result
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}
