import Foundation
import Testing
@testable import TetherCore

@Test func shareInboxQueueManifestRoundTrip() throws {
    // Unit-level encode/decode only — App Group container is unavailable in swift test.
    let manifest = ShareInboxQueue.Manifest(files: ["a.txt", "b.jpg"], createdAt: 1_700_000_000)
    let data = try JSONEncoder().encode(manifest)
    let decoded = try JSONDecoder().decode(ShareInboxQueue.Manifest.self, from: data)
    #expect(decoded.files == ["a.txt", "b.jpg"])
    #expect(decoded.createdAt == 1_700_000_000)
    #expect(ShareInboxQueue.appGroupID == "group.app.tether.client")
    #expect(ShareInboxQueue.pendingFolderName == "PendingSend")
}
