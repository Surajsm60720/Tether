import Foundation

/// Kind of surface a Terminal tab slot can hold (v2.4).
public enum TerminalSlotKind: String, Sendable, Codable, CaseIterable, Equatable {
    case virtual
    case agent
    case monitor
    case fetch
}

/// Lightweight slot identity/order used by the phone and unit tests.
public struct TerminalSlotMeta: Equatable, Sendable, Identifiable, Codable {
    public var id: String
    public var kind: TerminalSlotKind
    public var title: String
    public var agentSessionID: String?
    public var agentProgram: String?
    public var agentLine: String?
    public var agentHostID: String?
    public var cwd: String?
    public var agentNeedsYou: Bool

    public init(
        id: String = UUID().uuidString,
        kind: TerminalSlotKind,
        title: String,
        agentSessionID: String? = nil,
        agentProgram: String? = nil,
        agentLine: String? = nil,
        agentHostID: String? = nil,
        cwd: String? = nil,
        agentNeedsYou: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.agentSessionID = agentSessionID
        self.agentProgram = agentProgram
        self.agentLine = agentLine
        self.agentHostID = agentHostID
        self.cwd = cwd
        self.agentNeedsYou = agentNeedsYou
    }
}

/// Pure rules for creating, focusing, reordering, and capping Terminal slots.
public enum TerminalSlotBook {
    public static let maxSlots = 3
    public static let maxAgents = 3

    public static func welcomeVirtual(title: String = "~") -> TerminalSlotMeta {
        TerminalSlotMeta(kind: .virtual, title: title, cwd: "/")
    }

    public static func canAdd(count: Int) -> Bool {
        count < maxSlots
    }

    public static func shortTitle(kind: TerminalSlotKind, cwd: String?, program: String?) -> String {
        switch kind {
        case .virtual:
            guard let cwd, !cwd.isEmpty else { return "~" }
            if cwd == "/" { return "~" }
            return (try? VirtualPath.parse(cwd))?.components.last ?? cwd
        case .agent:
            guard let program else { return "agent" }
            return AgentPrograms.displayName(program)
        case .monitor:
            return "Monitor"
        case .fetch:
            return "fetch"
        }
    }

    /// Insert a new virtual shell at the end and focus it. Returns nil when at capacity.
    public static func addVirtual(
        slots: [TerminalSlotMeta],
        focused: String?
    ) -> (slots: [TerminalSlotMeta], focused: String)? {
        guard canAdd(count: slots.count) else { return nil }
        let next = welcomeVirtual()
        var copy = slots
        copy.append(next)
        return (copy, next.id)
    }

    public static func focus(slots: [TerminalSlotMeta], id: String) -> String? {
        slots.contains(where: { $0.id == id }) ? id : slots.first?.id
    }

    public static func reorder(slots: [TerminalSlotMeta], from: Int, to: Int) -> [TerminalSlotMeta] {
        guard from != to, slots.indices.contains(from), slots.indices.contains(to) else { return slots }
        var copy = slots
        let item = copy.remove(at: from)
        copy.insert(item, at: to)
        return copy
    }

    /// Move the slot with `id` so it sits at `toIndex` in the visible order.
    public static func move(slots: [TerminalSlotMeta], id: String, toIndex: Int) -> [TerminalSlotMeta] {
        guard let from = slots.firstIndex(where: { $0.id == id }) else { return slots }
        let to = min(max(0, toIndex), slots.count - 1)
        return reorder(slots: slots, from: from, to: to)
    }

    /// Close a non-agent slot (or an ended agent). Never removes the last slot — replaces with a virtual shell.
    public static func close(
        slots: [TerminalSlotMeta],
        focused: String?,
        id: String
    ) -> (slots: [TerminalSlotMeta], focused: String)? {
        guard let index = slots.firstIndex(where: { $0.id == id }) else { return nil }
        let target = slots[index]
        if target.kind == .agent { return nil }
        var copy = slots
        copy.remove(at: index)
        if copy.isEmpty {
            let fresh = welcomeVirtual()
            return ([fresh], fresh.id)
        }
        let nextFocus: String
        if focused == id {
            nextFocus = copy[min(index, copy.count - 1)].id
        } else if let focused, copy.contains(where: { $0.id == focused }) {
            nextFocus = focused
        } else {
            nextFocus = copy[0].id
        }
        return (copy, nextFocus)
    }

    /// Remove an agent slot after the process ends (or user closes with X).
    public static func removeAgent(
        slots: [TerminalSlotMeta],
        focused: String?,
        id: String
    ) -> (slots: [TerminalSlotMeta], focused: String) {
        guard let index = slots.firstIndex(where: { $0.id == id }) else {
            let fallback = focused ?? slots.first?.id ?? welcomeVirtual().id
            return (slots.isEmpty ? [welcomeVirtual()] : slots, fallback)
        }
        var copy = slots
        copy.remove(at: index)
        if copy.isEmpty {
            let fresh = welcomeVirtual()
            return ([fresh], fresh.id)
        }
        let nextFocus: String
        if focused == id {
            nextFocus = copy[min(index, copy.count - 1)].id
        } else if let focused, copy.contains(where: { $0.id == focused }) {
            nextFocus = focused
        } else {
            nextFocus = copy[0].id
        }
        return (copy, nextFocus)
    }

    public static func first(of kind: TerminalSlotKind, in slots: [TerminalSlotMeta]) -> TerminalSlotMeta? {
        slots.first { $0.kind == kind }
    }

    public static func liveAgents(in slots: [TerminalSlotMeta]) -> [TerminalSlotMeta] {
        slots.filter { $0.kind == .agent && $0.agentProgram != nil }
    }

    /// Island / deep-link target: focused live agent, else Needs-you, else first live agent.
    public static func islandAgent(
        slots: [TerminalSlotMeta],
        focused: String?,
        needsYouIDs: Set<String> = []
    ) -> TerminalSlotMeta? {
        let live = liveAgents(in: slots)
        guard !live.isEmpty else { return nil }
        if let focused, let match = live.first(where: { $0.id == focused }) {
            return match
        }
        if let urgent = live.first(where: { needsYouIDs.contains($0.id) || $0.agentNeedsYou }) {
            return urgent
        }
        return live.first
    }

    public static func agentCount(in slots: [TerminalSlotMeta]) -> Int {
        liveAgents(in: slots).count
    }

    public static func canOpenAgent(slots: [TerminalSlotMeta], convertingSlotID: String?) -> Bool {
        if let convertingSlotID,
           let slot = slots.first(where: { $0.id == convertingSlotID }),
           slot.kind == .virtual {
            return agentCount(in: slots) < maxAgents
        }
        if canAdd(count: slots.count), agentCount(in: slots) < maxAgents {
            return true
        }
        return false
    }

    /// Open or refresh a monitor/fetch slot. Prefers an existing slot of that kind.
    public static func openOrFocus(
        slots: [TerminalSlotMeta],
        focused: String?,
        kind: TerminalSlotKind,
        title: String
    ) -> (slots: [TerminalSlotMeta], focused: String)? {
        precondition(kind == .monitor || kind == .fetch)
        if let existing = first(of: kind, in: slots) {
            var copy = slots
            if let index = copy.firstIndex(where: { $0.id == existing.id }) {
                copy[index].title = title
            }
            return (copy, existing.id)
        }
        guard canAdd(count: slots.count) else { return nil }
        let next = TerminalSlotMeta(kind: kind, title: title)
        var copy = slots
        copy.append(next)
        return (copy, next.id)
    }
}
