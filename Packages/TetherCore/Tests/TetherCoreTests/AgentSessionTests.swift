import Foundation
import Testing
@testable import TetherCore

@Test func agentProgramNamesStayOnTheLivePath() {
    #expect(AgentPrograms.programName(in: "claude") == "claude")
    #expect(AgentPrograms.programName(in: "  Claude --resume  ") == "claude")
    #expect(AgentPrograms.programName(in: "/Users/me/.local/bin/codex") == "codex")
    #expect(AgentPrograms.programName(in: "cursor agent") == "cursor")
    #expect(AgentPrograms.programName(in: "sudo agent") == "agent")
    #expect(AgentPrograms.programName(in: "echo claude") == nil)
    #expect(AgentPrograms.programName(in: "claude | tee log") == nil)
    #expect(AgentPrograms.programName(in: "claude; rm -rf /") == nil)
    #expect(AgentPrograms.programName(in: "claude\nrm") == nil)
    #expect(AgentPrograms.programName(in: "ls") == nil)
    #expect(AgentPrograms.shellScript(line: "claude", directory: "/Users/o'brien/code") == "cd '/Users/o'\\''brien/code' && exec claude")
    #expect(AgentPrograms.displayName("claude") == "Claude Code")
    #expect(AgentPrograms.displayName("agent") == "Cursor")
}

@Test func virtualScreenDrawsTextColorAndReportsTheCursor() {
    var screen = VTScreen(columns: 8, rows: 3)
    let replies = screen.ingest(Data("Hi\u{1b}[31m!\u{1b}[H\u{1b}[6n".utf8))
    #expect(screen.glyph(row: 0, column: 0) == "H")
    #expect(screen.glyph(row: 0, column: 1) == "i")
    #expect(screen.glyph(row: 0, column: 2) == "!")
    #expect(screen.cell(row: 0, column: 2).foreground == .indexed(1))
    #expect(String(data: replies, encoding: .utf8) == "\u{1b}[1;1R")

    var wrapped = VTScreen(columns: 4, rows: 3)
    wrapped.ingest(Data("abcdef".utf8))
    #expect(wrapped.glyph(row: 0, column: 0) == "a")
    #expect(wrapped.glyph(row: 0, column: 3) == "d")
    #expect(wrapped.glyph(row: 1, column: 0) == "e")
    #expect(wrapped.glyph(row: 1, column: 1) == "f")

    var cleared = VTScreen(columns: 4, rows: 2)
    cleared.ingest(Data("abcd\u{1b}[2J".utf8))
    #expect(cleared.plainText().isEmpty)

    var alt = VTScreen(columns: 6, rows: 2)
    alt.ingest(Data("keep\u{1b}[?1049h\u{1b}[Hlive\u{1b}[?1049l".utf8))
    #expect(alt.glyph(row: 0, column: 0) == "k")
    #expect(alt.plainText().hasPrefix("keep"))

    var partial = VTScreen(columns: 5, rows: 2)
    partial.ingest(Data("Z\u{1b}[2".utf8))
    #expect(partial.glyph(row: 0, column: 0) == "Z")
    partial.ingest(Data("J".utf8))
    #expect(partial.plainText().isEmpty)

    var titled = VTScreen(columns: 5, rows: 2)
    titled.ingest(Data("\u{1b}]0;Claude\u{7}".utf8))
    #expect(titled.title == "Claude")
    #expect(titled.ingest(Data("\u{1b}[?25l\u{1b}[?2004h\u{1b}[?1h".utf8)).isEmpty)
    #expect(!titled.cursorVisible)
    #expect(titled.bracketedPaste)
    #expect(titled.applicationCursorKeys)

    let arrows = VTKeys.encode(.up, applicationCursor: false, bracketedPaste: false)
    #expect(String(data: arrows, encoding: .utf8) == "\u{1b}[A")
    let app = VTKeys.encode(.up, applicationCursor: true, bracketedPaste: false)
    #expect(String(data: app, encoding: .utf8) == "\u{1b}OA")
    let control = VTKeys.encode(.control("c"), applicationCursor: false, bracketedPaste: false)
    #expect(control == Data([0x03]))
    let suspend = VTKeys.encode(.control("Z"), applicationCursor: false, bracketedPaste: false)
    #expect(suspend == Data([0x1a]))
    let tab = VTKeys.encode(.tab, applicationCursor: false, bracketedPaste: true)
    #expect(tab == Data([0x09]))
    let backtab = VTKeys.encode(.backtab, applicationCursor: false, bracketedPaste: false)
    #expect(String(data: backtab, encoding: .utf8) == "\u{1b}[Z")
    let paste = VTKeys.encode(.text("hi"), applicationCursor: false, bracketedPaste: true)
    #expect(String(data: paste, encoding: .utf8) == "\u{1b}[200~hi\u{1b}[201~")

    var color = VTScreen(columns: 4, rows: 1)
    color.ingest(Data("\u{1b}[38;2;1;2;3mX".utf8))
    #expect(color.cell(row: 0, column: 0).foreground == .rgb(1, 2, 3))

    var sized = VTScreen(columns: 6, rows: 2)
    sized.ingest(Data("hello".utf8))
    sized.resize(columns: 3, rows: 2)
    #expect(sized.glyph(row: 0, column: 0) == "h")
    #expect(sized.glyph(row: 0, column: 2) == "l")
    #expect(sized.columns == 3)

    var history = VTScreen(columns: 4, rows: 2)
    history.ingest(Data("aaaa\r\nbbbb\r\ncccc".utf8))
    #expect(history.scrollback.count == 1)
    #expect(history.scrollback[0][0].grapheme == "a")
    #expect(history.glyph(row: 0, column: 0) == "b")
    #expect(history.glyph(row: 1, column: 0) == "c")
    #expect(history.plainText().contains("aaaa"))
    history.ingest(Data("\u{1b}[3J".utf8))
    #expect(history.scrollback.isEmpty)
}

@Test func aKeystrokeOnlyInvalidatesTheRowItChanges() {
    var screen = VTScreen(columns: 6, rows: 4)
    let quiet = screen.stamp(forLine: 3)
    screen.ingest(Data("hi".utf8))
    let typed = screen.stamp(forLine: 0)
    #expect(typed != quiet)
    #expect(screen.stamp(forLine: 3) == quiet)
    screen.ingest(Data("!".utf8))
    let written = screen.stamp(forLine: 0)
    #expect(written != typed)
    #expect(screen.stamp(forLine: 1) == quiet)
    #expect(screen.lineCount == 4)
    screen.ingest(Data("\u{1b}[Hhi!".utf8))
    #expect(screen.stamp(forLine: 0) == written)
    #expect(screen.glyph(row: 0, column: 0) == "h")
    #expect(screen.glyph(row: 0, column: 2) == "!")
}

@Test func agentBytesTravelAsEvents() async throws {
    let files = MemoryFileProvider()
    files.addShare(name: "Docs", writable: true)
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
    let box = EventBox()
    await client.setEventHandler { message in box.add(message) }
    let id = try await client.openTerminal(line: "claude", cwd: "/Docs", columns: 40, rows: 12)
    let sawExit = await box.wait { events in
        events.contains { $0.header.op == Op.termExit && $0.header.session == id }
    }
    #expect(sawExit)
    let bytes = box.snapshot().filter { $0.header.op == Op.termData }.reduce(into: Data()) { $0.append($1.body) }
    #expect(String(data: bytes, encoding: .utf8) == "ready\r\n")
    let blocked = try await client.exec(cwd: "/Docs", line: "codex")
    #expect(blocked.exit == 1)
    #expect(blocked.stderr.contains("live screen"))
    try await client.writeTerminal(session: id, data: Data("x".utf8))
    #expect(server.terminalWrites == [Data("x".utf8)])
    await client.close()
    hostTask.cancel()
    await pipe.close()
}

@Test func terminalBridgeKeepsOutputWhileSuspended() async {
    let bridge = TerminalBridge()
    let box = OutputBox()
    bridge.push(Data("a".utf8))
    bridge.suspend()
    bridge.push(Data("b".utf8))
    bridge.resume(onData: { box.append($0) }, onExit: { box.finish($0) })
    bridge.push(Data("c".utf8))
    let saw = await box.waitUntil { data, _ in
        String(data: data, encoding: .utf8) == "abc"
    }
    #expect(saw)
    bridge.finish(0)
    let ended = await box.wait()
    #expect(ended)
    #expect(box.snapshot().1 == 0)
}

#if os(macOS)
@Test func ptyRunsAProgramAndReturnsItsOutput() async throws {
    let box = OutputBox()
    let directory = FileManager.default.temporaryDirectory.path
    let session = PTYSession.start(
        id: "echo-test",
        argv: ["/bin/echo", "hello-tether"],
        directory: directory,
        environment: ["PATH": "/bin:/usr/bin", "TERM": "xterm-256color", "HOME": directory],
        columns: 80,
        rows: 24,
        onData: { box.append($0) },
        onExit: { box.finish($0) }
    )
    #expect(session != nil)
    let finished = await box.wait()
    #expect(finished)
    let (data, code) = box.snapshot()
    #expect(String(data: data, encoding: .utf8)?.contains("hello-tether") == true)
    #expect(code == 0)
}

@Test func ptyPassesKeystrokesToTheProgram() async throws {
    let box = OutputBox()
    let directory = FileManager.default.temporaryDirectory.path
    guard let session = PTYSession.start(
        id: "cat-test",
        argv: ["/bin/cat"],
        directory: directory,
        environment: ["PATH": "/bin:/usr/bin", "TERM": "xterm-256color", "HOME": directory],
        columns: 80,
        rows: 24,
        onData: { box.append($0) },
        onExit: { box.finish($0) }
    ) else {
        Issue.record("Couldn't open a pty")
        return
    }
    try await Task.sleep(for: .milliseconds(50))
    session.write(Data("ping\n".utf8))
    let echoed = await box.waitUntil { data, _ in
        String(data: data, encoding: .utf8)?.contains("ping") == true
    }
    #expect(echoed)
    session.resize(columns: 100, rows: 30)
    session.terminate()
    let finished = await box.wait()
    #expect(finished)
    _ = session
}
#endif

private final class EventBox: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [WireMessage] = []

    func add(_ message: WireMessage) {
        lock.lock()
        events.append(message)
        lock.unlock()
    }

    func snapshot() -> [WireMessage] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }

    func wait(_ ready: @Sendable ([WireMessage]) -> Bool) async -> Bool {
        for _ in 0..<100 {
            if ready(snapshot()) { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return ready(snapshot())
    }
}

private final class OutputBox: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private var code: Int32?

    func append(_ chunk: Data) {
        lock.lock()
        data.append(chunk)
        lock.unlock()
    }

    func finish(_ code: Int32) {
        lock.lock()
        self.code = code
        lock.unlock()
    }

    func snapshot() -> (Data, Int32?) {
        lock.lock()
        defer { lock.unlock() }
        return (data, code)
    }

    func wait() async -> Bool {
        await waitUntil { _, code in code != nil }
    }

    func waitUntil(_ ready: @Sendable (Data, Int32?) -> Bool) async -> Bool {
        for _ in 0..<150 {
            let snap = snapshot()
            if ready(snap.0, snap.1) { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        let snap = snapshot()
        return ready(snap.0, snap.1)
    }
}
