import Testing
@testable import TetherCore

@Test func terminalSlotBookCapsAtThree() {
    var slots = [TerminalSlotBook.welcomeVirtual()]
    var focused = slots[0].id
    for _ in 0..<2 {
        let result = TerminalSlotBook.addVirtual(slots: slots, focused: focused)
        #expect(result != nil)
        slots = result!.slots
        focused = result!.focused
    }
    #expect(slots.count == 3)
    #expect(TerminalSlotBook.addVirtual(slots: slots, focused: focused) == nil)
    #expect(!TerminalSlotBook.canAdd(count: 3))
}

@Test func terminalSlotBookReorderAndClose() {
    let a = TerminalSlotMeta(id: "a", kind: .virtual, title: "~")
    let b = TerminalSlotMeta(id: "b", kind: .monitor, title: "Monitor")
    let c = TerminalSlotMeta(id: "c", kind: .fetch, title: "fetch")
    let reordered = TerminalSlotBook.reorder(slots: [a, b, c], from: 0, to: 2)
    #expect(reordered.map(\.id) == ["b", "c", "a"])

    let closed = TerminalSlotBook.close(slots: reordered, focused: "a", id: "b")
    #expect(closed?.slots.map(\.id) == ["c", "a"])
    #expect(closed?.focused == "a")

    let last = TerminalSlotBook.close(slots: [a], focused: "a", id: "a")
    #expect(last?.slots.count == 1)
    #expect(last?.slots.first?.kind == .virtual)
    #expect(last?.slots.first?.id != "a")
}

@Test func terminalSlotBookRefusesClosingLiveAgent() {
    let agent = TerminalSlotMeta(id: "ag", kind: .agent, title: "Claude", agentProgram: "claude")
    let shell = TerminalSlotMeta(id: "sh", kind: .virtual, title: "~")
    #expect(TerminalSlotBook.close(slots: [agent, shell], focused: "ag", id: "ag") == nil)
    let removed = TerminalSlotBook.removeAgent(slots: [agent, shell], focused: "ag", id: "ag")
    #expect(removed.slots.map(\.id) == ["sh"])
    #expect(removed.focused == "sh")
}

@Test func terminalSlotBookOpenOrFocusMonitorAndFetch() {
    let shell = TerminalSlotBook.welcomeVirtual()
    let first = TerminalSlotBook.openOrFocus(slots: [shell], focused: shell.id, kind: .monitor, title: "Monitor")
    #expect(first?.slots.count == 2)
    #expect(first?.slots.last?.kind == .monitor)
    let again = TerminalSlotBook.openOrFocus(
        slots: first!.slots,
        focused: first!.focused,
        kind: .monitor,
        title: "Monitor"
    )
    #expect(again?.slots.count == 2)
    #expect(again?.focused == first?.focused)

    var full = first!.slots
    full.append(TerminalSlotMeta(kind: .fetch, title: "fetch"))
    #expect(full.count == 3)
    #expect(TerminalSlotBook.openOrFocus(slots: full, focused: full[0].id, kind: .fetch, title: "fetch") != nil)
    #expect(TerminalSlotBook.openOrFocus(slots: full, focused: full[0].id, kind: .monitor, title: "Monitor") != nil)
    let noRoom = TerminalSlotBook.openOrFocus(
        slots: [
            shell,
            TerminalSlotMeta(kind: .agent, title: "Claude", agentProgram: "claude"),
            TerminalSlotMeta(kind: .agent, title: "Codex", agentProgram: "codex"),
        ],
        focused: shell.id,
        kind: .monitor,
        title: "Monitor"
    )
    #expect(noRoom == nil)
}

@Test func terminalSlotBookIslandPicksFocusedThenNeedsYou() {
    let shell = TerminalSlotMeta(id: "sh", kind: .virtual, title: "~")
    let a = TerminalSlotMeta(id: "a", kind: .agent, title: "Claude", agentProgram: "claude")
    let b = TerminalSlotMeta(
        id: "b",
        kind: .agent,
        title: "Codex",
        agentProgram: "codex",
        agentNeedsYou: true
    )
    let slots = [shell, a, b]
    #expect(TerminalSlotBook.islandAgent(slots: slots, focused: "a")?.id == "a")
    #expect(TerminalSlotBook.islandAgent(slots: slots, focused: "sh")?.id == "b")
    #expect(TerminalSlotBook.islandAgent(slots: slots, focused: nil)?.id == "b")
}

@Test func terminalSlotBookShortTitles() {
    #expect(TerminalSlotBook.shortTitle(kind: .virtual, cwd: "/", program: nil) == "~")
    #expect(TerminalSlotBook.shortTitle(kind: .virtual, cwd: "/Documents/Work", program: nil) == "Work")
    #expect(TerminalSlotBook.shortTitle(kind: .monitor, cwd: nil, program: nil) == "Monitor")
    #expect(TerminalSlotBook.shortTitle(kind: .fetch, cwd: nil, program: nil) == "fetch")
}
