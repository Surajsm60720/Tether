import CryptoKit
import Foundation
import Network
import Testing
@testable import TetherCore

/// End-to-end coverage of every shipping 1.0 product claim that can run without a physical
/// iPhone/Mac UI. Device-only UI steps live in the v1 device E2E canvas checklist.
@Test func v1E2E_pairBrowseTransferTerminalSystemReconnectAndRevoke() async throws {
    let files = MemoryFileProvider()
    files.addShare(name: "Docs", writable: true)
    files.addShare(name: "Photos", writable: false)
    try files.writeFile(path: "/Docs/hello.txt", data: Data("hello tether\n".utf8))
    try files.writeFile(path: "/Docs/report.pdf", data: Data("%PDF-1.4 demo".utf8))
    try files.writeFile(path: "/Photos/shot.jpg", data: Data([0xFF, 0xD8, 0xFF, 0xD9]))

    let offer = PairingOffer(hostId: "host0001", hostName: "Studio Mac")
    let server = E2EHost(offer: offer, files: files)
    let pipe = MemoryPipe()
    let hostTask = Task {
        await HostConnection.serve(stream: pipe.host, remote: "e2e", server: server)
    }
    defer {
        hostTask.cancel()
    }

    // 1.0 — Pair by QR (full secret)
    let qrPayload = try PairingPayload.parseQR(offer.qr)
    #expect(qrPayload.material == .full)
    let client = try await ClientConnection.establish(
        stream: pipe.client,
        deviceId: "phone-e2e",
        deviceName: "Suraj's iPhone",
        mode: .pair(qrPayload)
    )
    #expect(await client.hostName == "Studio Mac")
    #expect(await client.hostId == "host0001")
    let pairedKeyData = try #require(await client.receivedDeviceKey)
    #expect(pairedKeyData.count == 32)
    let deviceKey = SymmetricKey(data: pairedKeyData)

    // 1.0 — Browse shares and folders
    let shares = try await client.shares()
    #expect(Set(shares.map(\.name)) == ["Docs", "Photos"])
    #expect(shares.first { $0.name == "Docs" }?.writable == true)
    #expect(shares.first { $0.name == "Photos" }?.writable == false)

    let root = try await client.list(path: "/")
    #expect(Set(root.map(\.name)) == ["Docs", "Photos"])

    let docs = try await client.list(path: "/Docs")
    #expect(docs.map(\.name).sorted() == ["hello.txt", "report.pdf"])

    let helloStat = try await client.stat(path: "/Docs/hello.txt")
    #expect(helloStat.kind == .file)
    #expect(helloStat.size == UInt64(Data("hello tether\n".utf8).count))

    // 1.0 — Read / download with progress
    let chunk = try await client.read(path: "/Docs/hello.txt", offset: 0, length: 100)
    #expect(String(data: chunk.data, encoding: .utf8) == "hello tether\n")

    let downloadURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("tether-e2e-dl-\(UUID().uuidString).txt")
    defer { try? FileManager.default.removeItem(at: downloadURL) }
    let downloadProgress = ProgressProbe()
    try await client.download(path: "/Docs/hello.txt", to: downloadURL) { done, total in
        downloadProgress.set(done, total)
    }
    #expect(downloadProgress.done == downloadProgress.total)
    #expect(String(data: try Data(contentsOf: downloadURL), encoding: .utf8) == "hello tether\n")

    // 1.0 — Upload into writable share; reject write into read-only share via terminal
    let uploadSrc = FileManager.default.temporaryDirectory
        .appendingPathComponent("tether-e2e-up-\(UUID().uuidString).txt")
    defer { try? FileManager.default.removeItem(at: uploadSrc) }
    try Data("from phone".utf8).write(to: uploadSrc)
    let uploadProgress = ProgressProbe()
    try await client.upload(file: uploadSrc, toDirectory: "/Docs", fileName: "from-phone.txt", progress: { done, total in
        uploadProgress.set(done, total)
    })
    #expect(uploadProgress.done == uploadProgress.total)
    let uploaded = try await client.read(path: "/Docs/from-phone.txt", offset: 0, length: 50)
    #expect(String(data: uploaded.data, encoding: .utf8) == "from phone")

    // 1.0 — Terminal everyday commands inside shares
    let ls = try await client.exec(cwd: "/Docs", line: "ls")
    #expect(ls.exit == 0)
    #expect(ls.stdout.contains("from-phone.txt"))

    let pwd = try await client.exec(cwd: "/Docs", line: "pwd")
    #expect(pwd.stdout.contains("/Docs"))

    let cat = try await client.exec(cwd: "/Docs", line: "cat hello.txt")
    #expect(cat.stdout.contains("hello tether"))

    let touch = try await client.exec(cwd: "/Docs", line: "touch note.txt")
    #expect(touch.exit == 0)
    let afterTouch = try await client.list(path: "/Docs")
    #expect(afterTouch.contains(where: { $0.name == "note.txt" }))

    let mkdir = try await client.exec(cwd: "/Docs", line: "mkdir sub")
    #expect(mkdir.exit == 0)

    let readOnlyWrite = try await client.exec(cwd: "/Photos", line: "touch nope.txt")
    #expect(readOnlyWrite.exit != 0)

    // 1.0 — whoami / fetch / htop (monitor action)
    let who = try await client.exec(cwd: "/", line: "whoami")
    #expect(who.exit == 0)
    #expect(who.stdout.contains("Studio Mac") || who.stdout.contains("@"))

    let fetch = try await client.exec(cwd: "/", line: "fetch")
    #expect(fetch.exit == 0)
    #expect(!fetch.stdout.isEmpty)

    let htop = try await client.exec(cwd: "/", line: "htop")
    #expect(htop.action?.type == "monitor")
    let btop = try await client.exec(cwd: "/", line: "btop")
    #expect(btop.action?.type == "monitor")

    // 1.0 — Live system stats (monitor data plane)
    let profile = try await client.systemProfile()
    #expect(profile.host == "Studio Mac")
    #expect(profile.shares == 2)
    let stats = try await client.systemStats()
    #expect(!stats.cores.isEmpty)
    #expect(stats.memoryTotal > 0)

    // 1.1 — No Mac shell fall-through
    let shellRejected = try await client.exec(cwd: "/Docs", line: "ls | wc")
    #expect(shellRejected.exit == 126)
    #expect(shellRejected.stderr.contains("shell operators") || shellRejected.stderr.contains("not available"))

    let unknown = try await client.exec(cwd: "/Docs", line: "yes")
    #expect(unknown.exit == 127)

    // 1.0 — Ping / liveness
    try await client.ping()
    #expect(await client.checkAlive())

    await client.close()
    await pipe.close()

    // 1.0 — Reconnect without password (session mode)
    let reconnectPipe = MemoryPipe()
    let reconnectHost = E2EHost(offer: nil, files: files)
    reconnectHost.keys["phone-e2e"] = deviceKey
    let reconnectTask = Task {
        await HostConnection.serve(stream: reconnectPipe.host, remote: "e2e-re", server: reconnectHost)
    }
    let session = try await ClientConnection.establish(
        stream: reconnectPipe.client,
        deviceId: "phone-e2e",
        deviceName: "Suraj's iPhone",
        mode: .session(hostId: "host0001", key: deviceKey)
    )
    let again = try await session.list(path: "/Docs")
    #expect(again.contains(where: { $0.name == "from-phone.txt" }))
    await session.close()
    reconnectTask.cancel()
    await reconnectPipe.close()

    // 1.0 — Revoke blocks new sessions
    let revokedPipe = MemoryPipe()
    let revokedHost = E2EHost(offer: nil, files: files)
    // No key stored → revoked / unknown device
    let revokedTask = Task {
        await HostConnection.serve(stream: revokedPipe.host, remote: "e2e-rev", server: revokedHost)
    }
    await #expect(throws: ProtocolFailure.self) {
        _ = try await ClientConnection.establish(
            stream: revokedPipe.client,
            deviceId: "phone-e2e",
            deviceName: "Suraj's iPhone",
            mode: .session(hostId: "host0001", key: deviceKey)
        )
    }
    revokedTask.cancel()
    await revokedPipe.close()
}

@Test func v1E2E_manualPairingCodeAndRemoteSetup() throws {
    let offer = PairingOffer(hostId: "host0001", hostName: "Studio Mac")
    let manual = try PairingPayload.parseManual(
        code: offer.manualCode,
        hostId: offer.hostId,
        hostName: offer.hostName
    )
    #expect(manual.material == .short)
    #expect(manual.hostId == "host0001")

    let token = SymmetricKey.random().raw
    let setup = RemoteSetup(
        hostId: "host0001",
        direct: RemoteAddress(host: "203.0.113.10", port: TetherPorts.direct),
        relay: RemoteAddress(host: "relay.example.com", port: TetherPorts.relay),
        token: token
    )
    let encoded = setup.encoded()
    let decoded = try #require(RemoteSetup.decode(encoded))
    #expect(decoded.hostId == "host0001")
    #expect(decoded.token == token)
    #expect(decoded.direct?.host == "203.0.113.10")
    #expect(decoded.relay?.host == "relay.example.com")
}

@Test func v1E2E_pathEscapeAndReadOnlyUploadDenied() async throws {
    let files = MemoryFileProvider()
    files.addShare(name: "Docs", writable: false)
    try files.writeFile(path: "/Docs/a.txt", data: Data("a".utf8))
    let offer = PairingOffer(hostId: "host0001", hostName: "Studio Mac")
    let server = E2EHost(offer: offer, files: files)
    let pipe = MemoryPipe()
    let hostTask = Task { await HostConnection.serve(stream: pipe.host, remote: "e2e", server: server) }
    defer { hostTask.cancel() }

    let client = try await ClientConnection.establish(
        stream: pipe.client,
        deviceId: "phone-ro",
        deviceName: "Phone",
        mode: .pair(try PairingPayload.parseQR(offer.qr))
    )

    await #expect(throws: (any Error).self) {
        _ = try await client.read(path: "/Docs/../../etc/passwd", offset: 0, length: 10)
    }

    let src = FileManager.default.temporaryDirectory.appendingPathComponent("ro-\(UUID().uuidString).bin")
    defer { try? FileManager.default.removeItem(at: src) }
    try Data("x".utf8).write(to: src)
    await #expect(throws: ProtocolFailure.self) {
        try await client.upload(file: src, toDirectory: "/Docs", fileName: "x.bin", progress: { _, _ in })
    }

    await client.close()
    await pipe.close()
}

@Test func v1E2E_cancelDownloadReleasesWaiters() async throws {
    let files = MemoryFileProvider()
    files.addShare(name: "Docs", writable: true)
    // Large enough to need multiple chunks so cancel can race mid-transfer.
    let payload = Data(repeating: 0xAB, count: TetherCoreInfo.chunkSize * 3 + 100)
    try files.writeFile(path: "/Docs/big.bin", data: payload)

    let offer = PairingOffer(hostId: "host0001", hostName: "Studio Mac")
    let server = E2EHost(offer: offer, files: files)
    let pipe = MemoryPipe()
    let hostTask = Task { await HostConnection.serve(stream: pipe.host, remote: "e2e", server: server) }
    defer { hostTask.cancel() }

    let client = try await ClientConnection.establish(
        stream: pipe.client,
        deviceId: "phone-cancel",
        deviceName: "Phone",
        mode: .pair(try PairingPayload.parseQR(offer.qr))
    )

    let dest = FileManager.default.temporaryDirectory.appendingPathComponent("cancel-\(UUID().uuidString).bin")
    defer { try? FileManager.default.removeItem(at: dest) }

    let download = Task {
        try await client.download(path: "/Docs/big.bin", to: dest) { _, _ in }
    }
    try await Task.sleep(for: .milliseconds(5))
    download.cancel()
    do {
        try await download.value
        // May finish before cancel on a fast machine — still OK if file is complete.
        if FileManager.default.fileExists(atPath: dest.path) {
            #expect((try? Data(contentsOf: dest).count) == payload.count)
        }
    } catch is CancellationError {
        // Expected path when cancel wins.
    } catch {
        // Timeout/closed after cancel is also acceptable.
    }

    // Connection remains usable after a cancelled transfer.
    try await client.ping()
    await client.close()
    await pipe.close()
}

@Test func v1E2E_changelogListsEveryShippedVersion() throws {
    #expect(AppChangelog.current == "2.5")
    let versions = Set(AppChangelog.releases.map(\.version))
    #expect(versions.contains("1.0"))
    #expect(versions.contains("1.1"))
    #expect(versions.contains("1.2"))
    #expect(versions.contains("2.0"))
    #expect(versions.contains("2.1"))
    #expect(versions.contains("2.2"))
    #expect(versions.contains("2.3"))
    #expect(versions.contains("2.4"))
    #expect(versions.contains("2.5"))
    let v1 = try #require(AppChangelog.releases.first { $0.version == "1.0" })
    #expect(v1.items.count >= 8)
    let v2 = try #require(AppChangelog.releases.first { $0.version == "2.0" })
    #expect(v2.items.contains(where: { $0.localizedCaseInsensitiveContains("agent") }))
    let v21 = try #require(AppChangelog.releases.first { $0.version == "2.1" })
    #expect(v21.items.contains(where: { $0.localizedCaseInsensitiveContains("keyboard") }))
    let v22 = try #require(AppChangelog.releases.first { $0.version == "2.2" })
    #expect(v22.items.contains(where: { $0.localizedCaseInsensitiveContains("sleep") }))
    #expect(v22.items.contains(where: { $0.localizedCaseInsensitiveContains("suggest") }))
    #expect(v22.items.contains(where: { $0.localizedCaseInsensitiveContains("Files search") || $0.localizedCaseInsensitiveContains("across every shared") }))
    let v24 = try #require(AppChangelog.releases.first { $0.version == "2.4" })
    #expect(v24.items.contains(where: { $0.localizedCaseInsensitiveContains("slot") }))
    let v25 = try #require(AppChangelog.releases.first { $0.version == "2.5" })
    #expect(v25.items.contains(where: { $0.localizedCaseInsensitiveContains("allowlist") || $0.localizedCaseInsensitiveContains("symlink") }))
}

@Test func v1E2E_terminalCommandSurfaceMatchesHelp() async {
    let files = MemoryFileProvider()
    files.addShare(name: "Docs", writable: true)
    let engine = TerminalEngine()
    let help = await engine.execute(line: "help", cwd: "/", files: files)
    for name in ["ls", "cd", "cat", "whoami", "fetch", "htop", "btop", "pwd", "mkdir", "rm"] {
        #expect(help.stdout.contains(name), "help should mention \(name)")
        #expect(TerminalEngine.commandNames.contains(name))
    }
}

// MARK: - Helpers

private final class ProgressProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var _done: UInt64 = 0
    private var _total: UInt64 = 0

    func set(_ done: UInt64, _ total: UInt64) {
        lock.lock()
        _done = done
        _total = total
        lock.unlock()
    }

    var done: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return _done
    }

    var total: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return _total
    }
}

private final class E2EHost: HostServing, @unchecked Sendable {
    let hostId = "host0001"
    var offer: PairingOffer?
    let filesProvider: MemoryFileProvider
    let abuse = AbuseGuard()
    var keys: [String: SymmetricKey] = [:]
    private let lock = NSLock()

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
    func connected(deviceId: String, name: String) {}
    func files() -> any FileProvider { filesProvider }
    func thumbnail(virtualPath: String, maxPixel: Int) async -> Data? { nil }
    func watchConnection(for deviceId: String, close: @escaping @Sendable () -> Void) -> UInt64 { 1 }
    func ignoreConnection(for deviceId: String, generation: UInt64) {}
    func disconnected(deviceId: String, generation: UInt64) -> Bool { true }
    func runShell(line: String, cwd: String) async -> TerminalResult? { nil }

    func openTerminal(
        id: String,
        deviceId: String,
        line: String,
        cwd: String,
        columns: Int,
        rows: Int,
        onData: @escaping @Sendable (Data) -> Void,
        onExit: @escaping @Sendable (Int32) -> Void
    ) async throws -> UInt64 {
        _ = deviceId
        onData(Data("ready\r\n".utf8))
        onExit(0)
        return 1
    }
    func writeTerminal(id: String, deviceId: String, data: Data) async throws {
        _ = deviceId
    }
    func resizeTerminal(id: String, deviceId: String, columns: Int, rows: Int) async throws {
        _ = deviceId
    }
    func closeTerminal(id: String, deviceId: String) async throws {
        _ = deviceId
    }
    func suspendTerminal(id: String, generation: UInt64) async {}
    func resumeTerminal(
        id: String,
        deviceId: String,
        onData: @escaping @Sendable (Data) -> Void,
        onExit: @escaping @Sendable (Int32) -> Void
    ) async throws -> UInt64? {
        _ = deviceId
        return nil
    }
    func preventSleepWhileActive() -> Bool { true }
    func setPreventSleepWhileActive(_ value: Bool) {}
}
