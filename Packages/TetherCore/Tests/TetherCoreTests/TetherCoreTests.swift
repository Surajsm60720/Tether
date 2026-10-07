import CryptoKit
import Foundation
import Network
import Testing
@testable import TetherCore

@Test func bonjourNameMatchesSavedHost() {
    #expect(BonjourHostID.resolve(serviceName: "Tether-abcd1234", txtId: nil) == "abcd1234")
    #expect(BonjourHostID.resolve(serviceName: "Tether-abcd1234", txtId: "abcd1234") == "abcd1234")
    #expect(BonjourHostID.matches(discoveredId: "name:Tether-abcd1234", serviceName: "Tether-abcd1234", savedId: "abcd1234"))
    #expect(!BonjourHostID.matches(discoveredId: "other", serviceName: "Tether-other", savedId: "abcd1234"))
}

@Test func bonjourInstanceNameCarriesDisplayName() {
    let name = BonjourHostID.instanceName(displayName: "Cedar Studio", id: "abcd1234", fallbackPrefix: "Tether")
    #expect(name.contains("Cedar Studio"))
    #expect(BonjourHostID.resolve(serviceName: name, txtId: nil) == "abcd1234")
    #expect(BonjourHostID.displayName(serviceName: name, txtName: nil) == "Cedar Studio")
    #expect(BonjourHostID.displayName(serviceName: name, txtName: "Harbor Loft") == "Harbor Loft")
    #expect(BonjourHostID.matches(discoveredId: "abcd1234", serviceName: name, savedId: "abcd1234"))
    let fitted = BonjourHostID.instanceName(displayName: String(repeating: "A", count: 80), id: "abcd1234", fallbackPrefix: "Tether")
    #expect(fitted.utf8.count <= 63)
    #expect(BonjourHostID.resolve(serviceName: fitted, txtId: nil) == "abcd1234")
    #expect(!BonjourHostID.displayName(serviceName: "Tether-abcd1234", txtName: nil).isEmpty)
}

@Test func directorySizeIncludesNestedFiles() async throws {
    let files = MemoryFileProvider()
    files.addShare(name: "Docs", writable: true)
    try files.writeFile(path: "/Docs/hello.txt", data: Data("hello".utf8))
    try files.writeFile(path: "/Docs/sub/note.txt", data: Data("abcd".utf8))
    let listed = try await files.list(path: .root, offset: 0, limit: 10, includeHidden: false)
    let docs = try #require(listed.first { $0.name == "Docs" })
    #expect(docs.size == 9)
    #expect(docs.childCount == 2)
    let inside = try await files.list(path: VirtualPath.parse("/Docs"), offset: 0, limit: 10, includeHidden: false)
    #expect(inside.first { $0.name == "sub" }?.size == 4)
    #expect(inside.first { $0.name == "hello.txt" }?.size == 5)
}

@Test func diskFolderAndFileSizes() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("tether-size-\(UUID().uuidString)", isDirectory: true)
    let share = root.appendingPathComponent("share", isDirectory: true)
    let folder = share.appendingPathComponent("Folder", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try Data("abcdef".utf8).write(to: folder.appendingPathComponent("a.txt"))
    try Data("xy".utf8).write(to: share.appendingPathComponent("b.bin"))
    let package = share.appendingPathComponent("Doc.pages", isDirectory: true)
    try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
    try Data("12345".utf8).write(to: package.appendingPathComponent("index"))
    defer { try? FileManager.default.removeItem(at: root) }

    let provider = DiskFileProvider(shares: [MountedShare(name: "share", root: share, writable: true)])
    let listed = try await provider.list(path: VirtualPath.parse("/share"), offset: 0, limit: 20, includeHidden: false)
    let folderEntry = try #require(listed.first { $0.name == "Folder" })
    #expect(folderEntry.kind == .dir)
    #expect(folderEntry.childCount == 1)
    #expect(folderEntry.size == 6)
    let file = try #require(listed.first { $0.name == "b.bin" })
    #expect(file.size == 2)
    let pages = try #require(listed.first { $0.name == "Doc.pages" })
    #expect(pages.size == 5)
    let info = try await provider.stat(path: VirtualPath.parse("/share/Folder"))
    #expect(info.size == 6)
    #expect(info.childCount == 1)
    #expect(info.created != nil)
}

@Test func phoneServiceNameResolvesDeviceId() {
    let id = "11111111-2222-3333-4444-555555555555"
    #expect(BonjourHostID.resolve(serviceName: "Phone-\(id)", txtId: nil) == id)
    #expect(BonjourHostID.matches(discoveredId: id, serviceName: "Phone-\(id)", savedId: id))
    #expect(BonjourHostID.displayName(serviceName: "Phone-\(id)", txtName: "Suraj iPhone") == "Suraj iPhone")
    #expect(BonjourHostID.displayName(serviceName: "Phone-\(id)", txtName: nil) == "iPhone")
    let phone = DiscoveredHost(
        name: "iPhone",
        hostId: id,
        endpoint: .hostPort(host: .ipv4(.loopback), port: 9),
        serviceName: "Phone-\(id)",
        role: "phone"
    )
    #expect(phone.isPhone)
    let mac = DiscoveredHost(
        name: "Cedar Studio",
        hostId: "abcd1234",
        endpoint: .hostPort(host: .ipv4(.loopback), port: 9),
        serviceName: "Cedar Studio #abcd1234",
        role: "mac"
    )
    #expect(!mac.isPhone)
}

@Test func dialFrameRoundTrip() throws {
    let frame = try SessionDial.encode(hostId: "abcd1234", hostName: "Cedar Studio")
    var decoder = FrameDecoder()
    decoder.append(frame)
    let payload = try #require(try decoder.pop())
    let dial = try SessionDial.decode(payload)
    #expect(dial.hostId == "abcd1234")
    #expect(dial.hostName == "Cedar Studio")
}

@Test func protocolVersionIsOne() {
    #expect(TetherCoreInfo.protocolVersion == 1)
    #expect(TetherCoreInfo.serviceType == "_tether._tcp")
    #expect(TetherCoreInfo.phoneServiceType == "_tether-phone._tcp")
}

@Test func virtualPathRejectsEscapes() throws {
    #expect(try VirtualPath.parse("/").isRoot)
    #expect(try VirtualPath.parse("/Docs/notes.txt").string == "/Docs/notes.txt")
    #expect(try VirtualPath.parse("/Docs/./notes.txt").string == "/Docs/notes.txt")
    #expect(try VirtualPath.parse("/Docs/sub/").string == "/Docs/sub")
    #expect(throws: PathError.self) { try VirtualPath.parse("/Docs/../Secret") }
    #expect(throws: PathError.self) { try VirtualPath.parse("/../etc/passwd") }
    #expect(throws: PathError.self) { try VirtualPath.parse("Docs/notes.txt") }
    #expect(throws: PathError.self) { try VirtualPath.parse("/Docs//notes.txt") }
    #expect(throws: PathError.self) { try VirtualPath.parse("/Docs/%2e%2e/Secret") }
    #expect(throws: PathError.self) { try VirtualPath.parse("/Docs/%252e%252e/Secret") }
    #expect(throws: PathError.self) { try VirtualPath.parse("/Docs/a\0b") }
    let composed = try VirtualPath.parse("/Do\u{0063}s/a")
    let decomposed = try VirtualPath.parse("/Do\u{0063}s/a".decomposedStringWithCanonicalMapping)
    #expect(composed == decomposed)
}

@Test func terminalResolveCollapsesDotDot() throws {
    let cwd = try VirtualPath.parse("/Docs/sub")
    #expect(try VirtualPath.resolve("..", from: cwd).string == "/Docs")
    #expect(try VirtualPath.resolve("../..", from: cwd).string == "/")
    #expect(try VirtualPath.resolve("~", from: cwd).string == "/")
    #expect(try VirtualPath.resolve("file.txt", from: cwd).string == "/Docs/sub/file.txt")
}

@Test func crockfordRoundTripAndForgiveness() throws {
    let bytes = Data([0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0x99])
    let code = CrockfordBase32.grouped(bytes)
    #expect(code.split(separator: "-").count == 4)
    #expect(try CrockfordBase32.decode(code) == bytes)
    let fuzzy = code.replacingOccurrences(of: "0", with: "O").replacingOccurrences(of: "1", with: "L")
    #expect(try CrockfordBase32.decode(fuzzy) == bytes)
}

@Test func pairingQRCarriesFullSecret() throws {
    let offer = PairingOffer(hostId: "abcd1234", hostName: "Studio Mac", now: Date(timeIntervalSince1970: 0), lifetime: 120)
    let payload = try PairingPayload.parseQR(offer.qr)
    #expect(payload.hostId == "abcd1234")
    #expect(payload.hostName == "Studio Mac")
    #expect(payload.material == .full)
    #expect(payload.secret.raw == offer.fullSecret.raw)
    let manual = try PairingPayload.parseManual(code: offer.manualCode, hostId: "abcd1234", hostName: "Studio Mac")
    #expect(manual.material == .short)
    #expect(manual.secret.raw == offer.shortSecret.raw)
    #expect(manual.secret.raw.count == 10)
}

@Test func framesRejectMalformedAndOversize() throws {
    var hello = Header()
    hello.op = Op.ping
    hello.requestId = 7
    let message = WireMessage(kind: .request, header: hello)
    let payload = try message.encode()
    let frame = try FrameCodec.encode(payload: payload)
    var decoder = FrameDecoder()
    decoder.append(frame.prefix(3))
    #expect(try decoder.pop() == nil)
    decoder.append(frame.dropFirst(3))
    guard let popped = try decoder.pop() else {
        Issue.record("Expected a complete frame")
        return
    }
    let decoded = try WireMessage.decode(popped)
    #expect(decoded.header.op == Op.ping)
    #expect(decoded.header.requestId == 7)

    #expect(throws: ProtocolFailure.self) { try WireMessage.decode(Data([0x01, 0x00, 0x00, 0x00, 0x02, 0x7b])) }
    var oversize = FrameDecoder()
    var huge = Data()
    huge.appendUInt32(UInt32(TetherCoreInfo.maxFrameBytes + 1))
    oversize.append(huge)
    #expect(throws: ProtocolFailure.self) { try oversize.pop() }
    #expect(throws: ProtocolFailure.self) { _ = try FrameCodec.encode(payload: Data(repeating: 1, count: TetherCoreInfo.maxFrameBytes + 1)) }
}

@Test func secureChannelRejectsReplayWrongKeyAndReorder() throws {
    let secret = SymmetricKey(data: Data(repeating: 0x11, count: 32))
    let nonceC = Data(repeating: 0x22, count: 32)
    let nonceH = Data(repeating: 0x33, count: 32)
    let keys = ChannelKeys.derive(secret: secret, nonceC: nonceC, nonceH: nonceH)
    #expect(keys.clientToHost.raw != keys.hostToClient.raw)
    let again = ChannelKeys.derive(secret: secret, nonceC: nonceC, nonceH: nonceH)
    #expect(keys.clientToHost.raw == again.clientToHost.raw)

    var client = SecureChannel(role: .client, secret: secret, nonceC: nonceC, nonceH: nonceH)
    var host = SecureChannel(role: .host, secret: secret, nonceC: nonceC, nonceH: nonceH)
    let first = try client.seal(Data("auth".utf8))
    let second = try client.seal(Data("next".utf8))
    #expect(throws: ProtocolFailure.self) { try host.open(second) }
    #expect(try host.open(first) == Data("auth".utf8))
    #expect(throws: ProtocolFailure.self) { try host.open(first) }
    #expect(try host.open(second) == Data("next".utf8))

    var outsider = SecureChannel(role: .host, secret: SymmetricKey(data: Data(repeating: 0x44, count: 32)), nonceC: nonceC, nonceH: nonceH)
    #expect(throws: ProtocolFailure.self) { try outsider.open(try client.seal(Data("nope".utf8))) }
}

@Test func abuseGuardLocksAfterRepeatedFailures() {
    let guardRail = AbuseGuard()
    let now = Date()
    for _ in 0..<5 {
        #expect(guardRail.recordPairingFailure(now: now) == false)
    }
    #expect(guardRail.recordPairingFailure(now: now) == true)
    #expect(guardRail.isPairingLocked(now: now.addingTimeInterval(10)))
    #expect(!guardRail.isPairingLocked(now: now.addingTimeInterval(6 * 60)))

    let handshakes = AbuseGuard()
    for _ in 0..<10 {
        #expect(handshakes.recordHandshakeFailure(now: now) == false)
    }
    #expect(handshakes.recordHandshakeFailure(now: now) == true)
    #expect(handshakes.isHandshakeLocked(now: now.addingTimeInterval(10)))
    #expect(!handshakes.isHandshakeLocked(now: now.addingTimeInterval(3 * 60)))
}

@Test func connectionAdmissionCapsPendingSockets() {
    let gate = ConnectionAdmission(limit: 2)
    #expect(gate.tryAdmit())
    #expect(gate.tryAdmit())
    #expect(!gate.tryAdmit())
    gate.release()
    #expect(gate.tryAdmit())
}

@Test func waitBoxFinishesWhenWaitingTaskIsCancelled() async {
    let box = WaitBox()
    let task = Task {
        try await box.value()
    }
    try? await Task.sleep(for: .milliseconds(20))
    task.cancel()
    do {
        _ = try await task.value
        Issue.record("Expected cancellation")
    } catch is CancellationError {
        // Expected.
    } catch {
        Issue.record("Unexpected error \(error)")
    }
}

@Test func memoryFilesystemAndTerminal() async throws {
    let files = MemoryFileProvider()
    files.addShare(name: "Docs", writable: true)
    files.addShare(name: "Photos", writable: false)
    try files.writeFile(path: "/Docs/hello.txt", data: Data("hello tether\n".utf8))
    try files.writeFile(path: "/Docs/.hidden", data: Data("secret".utf8))
    let listed = try await files.list(path: VirtualPath.parse("/Docs"), offset: 0, limit: 100, includeHidden: false)
    #expect(listed.map(\.name) == ["hello.txt"])
    let all = try await files.list(path: VirtualPath.parse("/Docs"), offset: 0, limit: 100, includeHidden: true)
    #expect(all.map(\.name).sorted() == [".hidden", "hello.txt"])

    let engine = TerminalEngine()
    let ls = await engine.execute(line: "ls /Docs", cwd: "/", files: files)
    #expect(ls.stdout.contains("hello.txt"))
    #expect(!ls.stdout.contains(".hidden"))
    let long = await engine.execute(line: "ls -la /Docs", cwd: "/", files: files)
    #expect(long.stdout.contains(".hidden"))
    let cat = await engine.execute(line: "cat \"/Docs/hello.txt\"", cwd: "/", files: files)
    #expect(cat.stdout.contains("hello tether"))
    let missing = await engine.execute(line: "nope", cwd: "/", files: files)
    #expect(missing.stdout.contains("command not found"))
    let moved = await engine.execute(line: "cd /Docs", cwd: "/", files: files)
    #expect(moved.cwd == "/Docs")
    let made = await engine.execute(line: "mkdir notes", cwd: "/Docs", files: files)
    #expect(made.exit == 0)
    let echoed = await engine.execute(line: "echo hello", cwd: "/Docs", files: files)
    #expect(echoed.stdout.contains("hello"))
    #expect(TerminalSyntax.requiresShell("ls | grep notes"))
    #expect(!TerminalSyntax.requiresShell("ls -la"))
    let quoted = Tokenizer.tokens("cat \"my file.txt\"")
    #expect(quoted == ["cat", "my file.txt"])
    await #expect(throws: ProtocolFailure.self) {
        _ = try await files.beginUpload(path: try VirtualPath.parse("/Photos/a.txt"), size: 1, overwrite: false)
    }
}

@Test func diskProviderRejectsSymlinkEscape() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("tether-test-\(UUID().uuidString)", isDirectory: true)
    let share = root.appendingPathComponent("share", isDirectory: true)
    let outside = root.appendingPathComponent("secret.txt")
    try FileManager.default.createDirectory(at: share, withIntermediateDirectories: true)
    try Data("inside".utf8).write(to: share.appendingPathComponent("ok.txt"))
    try Data("hidden".utf8).write(to: outside)
    try FileManager.default.createSymbolicLink(at: share.appendingPathComponent("escape"), withDestinationURL: outside)
    defer { try? FileManager.default.removeItem(at: root) }

    let provider = DiskFileProvider(shares: [MountedShare(name: "share", root: share, writable: true)])
    let ok = try await provider.read(path: VirtualPath.parse("/share/ok.txt"), offset: 0, length: 100)
    #expect(String(data: ok.data, encoding: .utf8) == "inside")
    await #expect(throws: ProtocolFailure.self) {
        _ = try await provider.read(path: try VirtualPath.parse("/share/escape"), offset: 0, length: 100)
    }
    await #expect(throws: PathError.self) {
        _ = try await provider.read(path: try VirtualPath.parse("/share/../../secret.txt"), offset: 0, length: 10)
    }
    await #expect(throws: ProtocolFailure.self) {
        try await provider.writeWholeFile(
            path: try VirtualPath.parse("/share/escape"),
            data: Data("pwned".utf8),
            append: true
        )
    }
    #expect(String(data: try Data(contentsOf: outside), encoding: .utf8) == "hidden")
}

@Test func diskUploadRejectsOutOfRangeChunkAndAbortAll() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("tether-upload-\(UUID().uuidString)", isDirectory: true)
    let share = root.appendingPathComponent("share", isDirectory: true)
    try FileManager.default.createDirectory(at: share, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let provider = DiskFileProvider(shares: [MountedShare(name: "share", root: share, writable: true)])
    let id = try await provider.beginUpload(path: try VirtualPath.parse("/share/file.bin"), size: 8, overwrite: true)
    await #expect(throws: ProtocolFailure.self) {
        _ = try await provider.uploadChunk(id: id, offset: 4, data: Data(repeating: 1, count: 8))
    }
    _ = try await provider.uploadChunk(id: id, offset: 0, data: Data(repeating: 2, count: 4))
    await provider.abortAllUploads()
    let leftovers = try FileManager.default.contentsOfDirectory(atPath: share.path)
    #expect(!leftovers.contains(where: { $0.hasPrefix(".tether-upload-") }))
}

@Test func pairListReadWriteOverThePipe() async throws {
    let files = MemoryFileProvider()
    files.addShare(name: "Docs", writable: true)
    try files.writeFile(path: "/Docs/hello.txt", data: Data("hello tether".utf8))
    let offer = PairingOffer(hostId: "host0001", hostName: "Studio Mac")
    let server = TestHost(offer: offer, files: files)
    let pipe = MemoryPipe()
    let hostTask = Task {
        await HostConnection.serve(stream: pipe.host, remote: "test", server: server)
    }
    let payload = try PairingPayload.parseQR(offer.qr)
    let client = try await ClientConnection.establish(
        stream: pipe.client,
        deviceId: "phone-1",
        deviceName: "Suraj's iPhone",
        mode: .pair(payload)
    )
    #expect(await client.hostName == "Studio Mac")
    let pairedKey = await client.receivedDeviceKey
    #expect(pairedKey?.count == 32)
    let entries = try await client.list(path: "/Docs")
    #expect(entries.map(\.name) == ["hello.txt"])
    let chunk = try await client.read(path: "/Docs/hello.txt", offset: 0, length: 100)
    #expect(String(data: chunk.data, encoding: .utf8) == "hello tether")

    let temp = FileManager.default.temporaryDirectory.appendingPathComponent("tether-upload-\(UUID().uuidString).txt")
    try Data("uploaded".utf8).write(to: temp)
    try await client.upload(file: temp, toDirectory: "/Docs", fileName: "new.txt", progress: { _, _ in })
    let saved = try await client.read(path: "/Docs/new.txt", offset: 0, length: 100)
    #expect(String(data: saved.data, encoding: .utf8) == "uploaded")
    let exec = try await client.exec(cwd: "/Docs", line: "ls")
    #expect(exec.stdout.contains("new.txt"))

    guard let pairedKey else {
        Issue.record("Missing device key")
        return
    }
    let key = SymmetricKey(data: pairedKey)
    await client.close()
    hostTask.cancel()
    await pipe.close()

    let second = MemoryPipe()
    let revoked = TestHost(offer: nil, files: files)
    revoked.keys["phone-1"] = key
    let secondHost = Task {
        await HostConnection.serve(stream: second.host, remote: "test", server: revoked)
    }
    revoked.keys["phone-1"] = nil
    await #expect(throws: ProtocolFailure.self) {
        _ = try await ClientConnection.establish(
            stream: second.client,
            deviceId: "phone-1",
            deviceName: "Suraj's iPhone",
            mode: .session(hostId: "host0001", key: key)
        )
    }
    secondHost.cancel()
    await second.close()
}

final class TestHost: HostServing, @unchecked Sendable {
    let hostId = "host0001"
    var offer: PairingOffer?
    let filesProvider: MemoryFileProvider
    let abuse = AbuseGuard()
    var keys: [String: SymmetricKey] = [:]
    var connectedNames: [String] = []
    let lock = NSLock()

    init(offer: PairingOffer?, files: MemoryFileProvider) {
        self.offer = offer
        self.filesProvider = files
    }

    func hostName() -> String { "Studio Mac" }
    func currentOffer() -> PairingOffer? { offer }
    func takeOffer() -> PairingOffer? {
        let value = offer
        offer = nil
        return value
    }
    func consumeOffer() { offer = nil }
    func deviceKey(for deviceId: String) -> SymmetricKey? { keys[deviceId] }
    func rememberDevice(id: String, name: String, key: SymmetricKey) { keys[id] = key }
    func sessionApprovalRequired() -> Bool { false }
    func decide(_ request: ApprovalRequest) async -> Bool { true }
    func note(_ event: String) {}
    func connected(deviceId: String, name: String) {
        lock.lock()
        connectedNames.append(name)
        lock.unlock()
    }
    func files() -> any FileProvider { filesProvider }
    func thumbnail(virtualPath: String, maxPixel: Int) async -> Data? { nil }
    func watchConnection(for deviceId: String, close: @escaping @Sendable () -> Void) -> UInt64 { 1 }
    func ignoreConnection(for deviceId: String, generation: UInt64) {}
    func disconnected(deviceId: String, generation: UInt64) -> Bool { true }
    func runShell(line: String, cwd: String) async -> TerminalResult? { nil }
    var terminalWrites: [Data] = []
    var preventSleep = true
    func openTerminal(
        id: String,
        line: String,
        cwd: String,
        columns: Int,
        rows: Int,
        onData: @escaping @Sendable (Data) -> Void,
        onExit: @escaping @Sendable (Int32) -> Void
    ) async throws -> UInt64 {
        onData(Data("ready\r\n".utf8))
        onExit(0)
        return 1
    }
    func writeTerminal(id: String, data: Data) async {
        recordWrite(data)
    }

    private func recordWrite(_ data: Data) {
        lock.lock()
        terminalWrites.append(data)
        lock.unlock()
    }
    func resizeTerminal(id: String, columns: Int, rows: Int) async {}
    func closeTerminal(id: String) async {}
    func suspendTerminal(id: String, generation: UInt64) async {}
    func resumeTerminal(id: String, onData: @escaping @Sendable (Data) -> Void, onExit: @escaping @Sendable (Int32) -> Void) async -> UInt64? {
        nil
    }
    func preventSleepWhileActive() -> Bool { preventSleep }
    func setPreventSleepWhileActive(_ value: Bool) { preventSleep = value }
}

@Test func remoteAddressAndSetupRoundTrip() throws {
    #expect(RemoteAddress.parse("10.0.0.8:52173") == RemoteAddress(host: "10.0.0.8", port: 52173))
    #expect(RemoteAddress.parse("10.0.0.8:52173")?.reach == .localNetwork)
    #expect(RemoteAddress.parse("100.64.0.2:52173")?.reach == .tunnel)
    #expect(RemoteAddress.parse("home.example.com:443")?.reach == .publicInternet)
    #expect(RemoteAddress.parse("203.0.113.10", defaultPort: 52174)?.port == 52174)
    #expect(RemoteAddress.parse("[::1]:52173")?.host == "::1")
    #expect(RemoteAddress.parse("no-port") == nil)
    #expect(RemoteAddress.parse("host:0") == nil)

    let interfaces = [
        MachineAddress(interfaceName: "en0", address: "192.168.1.20", kind: .local),
        MachineAddress(interfaceName: "utun3", address: "100.64.0.2", kind: .tailscale),
    ]
    #expect(RemoteAddress.preferred(override: "", port: 52173, interfaces: interfaces)?.host == "100.64.0.2")
    #expect(RemoteAddress.preferred(override: "home.example.com", port: 52173, interfaces: interfaces)?.description == "home.example.com:52173")

    let token = Data(repeating: 0xAB, count: 32)
    let setup = RemoteSetup(
        hostId: "abcd1234",
        direct: RemoteAddress(host: "100.64.0.2", port: 52173),
        relay: RemoteAddress(host: "relay.example.com", port: 52174),
        token: token
    )
    let decoded = RemoteSetup.decode(setup.encoded())
    #expect(decoded == setup)
    #expect(RemoteSetup.decode("not a code") == nil)
    #expect(MachineAddresses.list().allSatisfy { $0.address != "127.0.0.1" })
}

@Test func relayRejectsAMalformedPrelude() async throws {
    let server = try await RelayServer.start()
    defer { server.stop() }
    let address = RemoteAddress(host: "127.0.0.1", port: server.port)
    let stream = NWByteStream(connection: NWConnection(to: address.endpoint, using: TetherLink.parameters(allowsCellular: true)))
    try await stream.start()
    try await stream.send(Data("OPEN nope\n".utf8))
    let reply = try await stream.receive(maximumLength: 16)
    #expect(String(decoding: reply, as: UTF8.self) == "NO\n")
    await stream.close()
}

@Test func sessionWorksThroughTheRelay() async throws {
    let server = try await RelayServer.start()
    defer { server.stop() }
    let token = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
    let address = RemoteAddress(host: "127.0.0.1", port: server.port)
    let files = MemoryFileProvider()
    files.addShare(name: "Docs", writable: false)
    try files.writeFile(path: "/Docs/hello.txt", data: Data("remote".utf8))
    let key = SymmetricKey(size: .bits256)
    let host = TestHost(offer: nil, files: files)
    host.keys["phone-1"] = key

    let hostTask = Task {
        do {
            let stream = try await RelayClient.open(role: .host, address: address, token: token)
            await HostConnection.serve(stream: stream, remote: "relay", server: host)
        } catch {
            Issue.record("Host failed to join the relay")
        }
    }
    let stream = try await RelayClient.open(role: .client, address: address, token: token)
    let client = try await ClientConnection.establish(
        stream: stream,
        deviceId: "phone-1",
        deviceName: "Phone",
        mode: .session(hostId: "host0001", key: key)
    )
    let entries = try await client.list(path: "/Docs")
    #expect(entries.map(\.name) == ["hello.txt"])
    let chunk = try await client.read(path: "/Docs/hello.txt", offset: 0, length: 100)
    #expect(String(data: chunk.data, encoding: .utf8) == "remote")
    await client.close()
    hostTask.cancel()
    await hostTask.value
}

@Test func sessionReachesADirectPort() async throws {
    let files = MemoryFileProvider()
    files.addShare(name: "Docs", writable: false)
    try files.writeFile(path: "/Docs/hello.txt", data: Data("direct".utf8))
    let key = SymmetricKey(size: .bits256)
    let host = TestHost(offer: nil, files: files)
    host.keys["phone-1"] = key
    let listener = TetherListener()
    let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
        let gate = OnceResume<UInt16>()
        listener.onReady = { ready in
            gate.resume(continuation, returning: ready)
        }
        listener.onState = { state in
            if state.hasPrefix("failed") {
                gate.fail(continuation, StreamError.failed(state))
            }
        }
        do {
            try listener.start(name: "Studio", hostId: "host0001", peerToPeer: false, advertise: false)
        } catch {
            gate.fail(continuation, error)
        }
    }
    defer { listener.stop() }
    listener.onConnection = { connection in
        let stream = NWByteStream(connection: connection)
        Task {
            do {
                try await stream.start()
                await HostConnection.serve(stream: stream, remote: "direct", server: host)
            } catch {
                await stream.close()
            }
        }
    }
    guard let bound = NWEndpoint.Port(rawValue: port) else {
        Issue.record("Missing port")
        return
    }
    let stream = try await TetherLink.connect(
        to: .hostPort(host: .ipv4(.loopback), port: bound),
        allowsCellular: true,
        timeout: .seconds(5)
    )
    let client = try await ClientConnection.establish(
        stream: stream,
        deviceId: "phone-1",
        deviceName: "Phone",
        mode: .session(hostId: "host0001", key: key)
    )
    let entries = try await client.list(path: "/Docs")
    #expect(entries.map(\.name) == ["hello.txt"])
    await client.close()
}

@Test func systemCommandsFormatWhoamiFetchAndMonitor() async {
    let profile = SystemProfile(
        user: "suraj",
        host: "Studio Mac",
        model: "Mac16,1",
        os: "macOS 26.0.0",
        cpu: "Apple M4",
        cores: 10,
        memory: 24 * 1024 * 1024 * 1024,
        uptime: 3 * 3600 + 12 * 60,
        diskUsed: 180 * 1024 * 1024 * 1024,
        diskTotal: 500 * 1024 * 1024 * 1024,
        shares: 2
    )
    let context = TerminalContext(user: "suraj", host: "Studio Mac", device: "Suraj's iPhone", profile: profile)
    #expect(SystemText.whoami(user: "suraj", host: "Studio Mac", device: "Suraj's iPhone") == "suraj@Studio Mac (via Suraj's iPhone)\n")
    let portrait = SystemText.fetch(profile)
    #expect(portrait.contains("suraj@Studio Mac"))
    #expect(portrait.contains("Shares  2"))
    #expect(portrait.contains("Load"))
    #expect(SystemText.uptime(3 * 3600 + 12 * 60) == "3h 12m")
    let previous = CPUSample(cores: [CPUSample.Core(user: 10, system: 5, idle: 85, nice: 0)])
    let current = CPUSample(cores: [CPUSample.Core(user: 20, system: 15, idle: 165, nice: 0)])
    #expect(CPUDelta.percents(previous: previous, current: current) == [20])
    let parts = CPUDelta.parts(previous: previous, current: current)
    #expect(abs(parts.user - 10) < 0.01)
    #expect(abs(parts.idle - 80) < 0.01)
    #expect(BatteryMath.chargePercent(current: 100, max: 100) == 100)
    #expect(BatteryMath.maximumCapacity(nominal: 4462, design: 4563) == 97)
    #expect(BatteryMath.condition(health: 92) == "Good")
    let sensors = TemperatureFilter.choose([
        ("PMU tdie1", 60),
        ("PMU tdie2", 59),
        ("PMU tdie3", 58),
        ("PMU tdie4", 57),
        ("PMU tdie5", 56),
        ("PMU tdie6", 55),
        ("PMU tdie6", 51),
        ("gas gauge battery", 33),
        ("PMU ibuck4", 4),
    ])
    #expect(sensors.count == 6)
    #expect(sensors.first?.name == "PMU tdie1")
    #expect(sensors.contains { $0.name == "gas gauge battery" })
    #expect(!sensors.contains { $0.name == "PMU tdie6" })

    let files = MemoryFileProvider()
    let engine = TerminalEngine()
    let who = await engine.execute(line: "whoami", cwd: "/", files: files, context: context)
    #expect(who.stdout.contains("suraj@Studio Mac"))
    #expect(who.exit == 0)
    let monitor = await engine.execute(line: "htop", cwd: "/", files: files, context: context)
    #expect(monitor.action?.type == "monitor")
    let alias = await engine.execute(line: "btop", cwd: "/", files: files)
    #expect(alias.action?.type == "monitor")
    let offline = await engine.execute(line: "fetch", cwd: "/", files: files)
    #expect(offline.exit == 1)
}

@Test func systemProbeReadsThisMac() async {
    let profile = SystemProbe.profile(hostName: "Studio Mac", shareCount: 1)
    #expect(profile.host == "Studio Mac")
    #expect(profile.memory > 0)
    #expect(profile.cores >= 1)
    #expect(profile.os.hasPrefix("macOS"))
    let stats = await SystemSampler().stats()
    #expect(!stats.cores.isEmpty)
    #expect(stats.memoryTotal > 0)
    #expect(!stats.processes.isEmpty)
    #expect(stats.processes.allSatisfy { !$0.name.contains("/") })
    if !stats.temperatures.isEmpty {
        #expect(stats.temperatures.allSatisfy { $0.celsius > 1 && $0.celsius < 125 })
    }
    if let health = stats.batteryHealth {
        #expect((1...100).contains(health))
    }
}

private final class OnceResume<T: Sendable>: @unchecked Sendable {
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
