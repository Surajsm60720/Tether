import Foundation
import Testing
@testable import TetherCore

@Test func agentAttachPathLeavesSimplePathsBare() {
    #expect(AgentAttachPath.quoted("/Users/me/Inbox/shot.png") == "/Users/me/Inbox/shot.png")
}

@Test func agentAttachPathQuotesSpaces() {
    #expect(
        AgentAttachPath.quoted("/Users/me/Tether Received/my shot.png")
            == "'/Users/me/Tether Received/my shot.png'"
    )
}

@Test func agentAttachPathEscapesEmbeddedSingleQuotes() {
    #expect(
        AgentAttachPath.quoted("/tmp/it's.png")
            == "'/tmp/it'\\''s.png'"
    )
}

@Test func memoryUploadCommitSynthesizesHostPath() async throws {
    let files = MemoryFileProvider()
    files.addShare(name: InboxShare.name, writable: true)
    let payload = Data("attach-me".utf8)
    let id = try await files.beginUpload(
        path: try InboxShare.path(fileName: "clip.png"),
        size: UInt64(payload.count),
        overwrite: false
    )
    _ = try await files.uploadChunk(id: id, offset: 0, data: payload)
    let commit = try await files.commitUpload(id: id)
    #expect(commit.fileName == "clip.png")
    #expect(commit.path.string == "/Inbox/clip.png")
    #expect(commit.hostAbsolutePath == "/tmp/TetherDemo/Inbox/clip.png")
    #expect(AgentAttachPath.quoted(commit.hostAbsolutePath) == "/tmp/TetherDemo/Inbox/clip.png")
}

@Test func quietUploadSkipsReceiveAnnounce() async throws {
    let files = MemoryFileProvider()
    files.addShare(name: InboxShare.name, writable: true)
    let offer = PairingOffer(hostId: "host0001", hostName: "Studio Mac")
    let server = TestHost(offer: offer, files: files)
    let pipe = MemoryPipe()
    let hostTask = Task {
        await HostConnection.serve(stream: pipe.host, remote: "test", server: server)
    }
    defer {
        hostTask.cancel()
    }
    let payload = try PairingPayload.parseQR(offer.qr)
    let client = try await ClientConnection.establish(
        stream: pipe.client,
        deviceId: "phone-attach",
        deviceName: "Test Phone",
        mode: .pair(payload)
    )
    let quiet = FileManager.default.temporaryDirectory.appendingPathComponent("tether-quiet-\(UUID().uuidString).png")
    let loud = FileManager.default.temporaryDirectory.appendingPathComponent("tether-loud-\(UUID().uuidString).png")
    defer {
        try? FileManager.default.removeItem(at: quiet)
        try? FileManager.default.removeItem(at: loud)
    }
    try Data("quiet".utf8).write(to: quiet)
    try Data("loud".utf8).write(to: loud)

    _ = try await client.upload(
        file: quiet,
        toDirectory: "/\(InboxShare.name)",
        fileName: "quiet.png",
        notifyReceive: false,
        progress: { _, _ in }
    )
    #expect(server.receiveAnnounceCount == 0)

    _ = try await client.upload(
        file: loud,
        toDirectory: "/\(InboxShare.name)",
        fileName: "loud.png",
        notifyReceive: true,
        progress: { _, _ in }
    )
    #expect(server.receiveAnnounceCount == 1)

    await client.close()
    await pipe.close()
}
