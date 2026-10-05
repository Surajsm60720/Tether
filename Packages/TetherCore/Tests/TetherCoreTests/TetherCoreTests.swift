import CryptoKit
import Foundation
import Testing
@testable import TetherCore

@Test func bonjourNameMatchesSavedHost() {
    #expect(BonjourHostID.resolve(serviceName: "Tether-abcd1234", txtId: nil) == "abcd1234")
    #expect(BonjourHostID.resolve(serviceName: "Tether-abcd1234", txtId: "abcd1234") == "abcd1234")
    #expect(BonjourHostID.matches(discoveredId: "name:Tether-abcd1234", serviceName: "Tether-abcd1234", savedId: "abcd1234"))
    #expect(!BonjourHostID.matches(discoveredId: "other", serviceName: "Tether-other", savedId: "abcd1234"))
}

@Test func phoneServiceNameResolvesDeviceId() {
    let id = "11111111-2222-3333-4444-555555555555"
    #expect(BonjourHostID.resolve(serviceName: "Phone-\(id)", txtId: nil) == id)
    #expect(BonjourHostID.matches(discoveredId: id, serviceName: "Phone-\(id)", savedId: id))
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

private final class TestHost: HostServing, @unchecked Sendable {
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
    func disconnected(deviceId: String) {}
    func files() -> any FileProvider { filesProvider }
    func thumbnail(virtualPath: String, maxPixel: Int) async -> Data? { nil }
    func watchConnection(for deviceId: String, close: @escaping @Sendable () -> Void) {}
    func ignoreConnection(for deviceId: String) {}
    func runShell(line: String, cwd: String) async -> TerminalResult? { nil }
}
