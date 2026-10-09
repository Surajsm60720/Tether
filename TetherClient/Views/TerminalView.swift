import SwiftUI
import TetherCore
import UIKit
import UniformTypeIdentifiers

struct TerminalScreen: View {
    @Bindable var store: ClientStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focused: Bool
    @State private var draft = ""
    @State private var importing = false
    @State private var control = false
    @State private var keyboardVisible = false
    @State private var completionHint = ""
    @State private var hintedDraft = ""
    @State private var accessoryDraft = ""
    @State private var completionToken = 0
    @State private var suggestions: [CompletionSuggestion] = []
    @State private var suggestToken = 0
    /// Tall enough for ~8–10 rows; the menu itself scrolls for the rest.
    private let menuMaxHeight: CGFloat = 260

    var body: some View {
        VStack(spacing: 0) {
            header
            slotStrip
            Group {
                switch store.focusedSlot?.kind {
                case .agent:
                    AgentTerminalView(store: store)
                case .monitor:
                    MonitorScreen(store: store, embedded: true)
                case .fetch:
                    fetchSurface
                default:
                    virtualSurface
                }
            }
            .id("\(store.focusedSlotID)-\(store.slotEpoch)")
        }
        .background(TerminalTheme.standard.bg)
        // Live agent: hide the tab bar so the PTY and key row use the full bottom edge.
        .toolbar(store.focusedIsLiveAgent ? .hidden : .automatic, for: .tabBar)
        .onAppear {
            if store.sessionTab == SessionTabIndex.terminal { focused = store.focusedSlot?.kind == .virtual }
            store.syncMonitorPolling()
        }
        .onChange(of: store.focusedSlotID) { _, _ in
            if store.sessionTab == SessionTabIndex.terminal { focused = store.focusedSlot?.kind == .virtual }
            store.syncMonitorPolling()
        }
        .onChange(of: store.agentProgram) { _, program in
            if program == nil, store.sessionTab == SessionTabIndex.terminal { focused = store.focusedSlot?.kind == .virtual }
        }
        .onChange(of: store.sessionTab) { _, tab in
            // Leaving Terminal must drop the keyboard so Files and Transfers get the full screen.
            // Slot sessions stay alive in ClientStore until closed.
            if tab != SessionTabIndex.terminal {
                focused = false
            } else if store.focusedSlot?.kind == .virtual {
                focused = true
            }
            store.syncMonitorPolling()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidShowNotification)) { _ in
            keyboardVisible = true
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidHideNotification)) { _ in
            keyboardVisible = false
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item]) { result in
            if case let .success(url) = result {
                let accessing = url.startAccessingSecurityScopedResource()
                Task {
                    await store.upload(url: url)
                    if accessing { url.stopAccessingSecurityScopedResource() }
                }
            }
        }
        .onChange(of: store.requestUpload) { _, requested in
            if requested {
                importing = true
                store.requestUpload = false
            }
        }
    }

    private var slotStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Array(store.terminalSlots.enumerated()), id: \.element.id) { index, slot in
                    slotChip(slot, index: index)
                }
                Button {
                    store.addTerminalSlot()
                } label: {
                    Image(systemName: "plus")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(
                            TerminalSlotBook.canAdd(count: store.terminalSlots.count)
                                ? TerminalTheme.standard.prompt
                                : TerminalTheme.standard.dim.opacity(0.45)
                        )
                        .frame(minWidth: 36, minHeight: 32)
                }
                .disabled(!TerminalSlotBook.canAdd(count: store.terminalSlots.count))
                .accessibilityLabel("New terminal")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        .background(TerminalTheme.standard.bg)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(TerminalTheme.standard.dim.opacity(0.25))
                .frame(height: 1)
        }
    }

    private func slotChip(_ slot: TerminalSlotState, index: Int) -> some View {
        let selected = slot.id == store.focusedSlotID
        return Button {
            store.focusSlot(id: slot.id)
        } label: {
            HStack(spacing: 4) {
                if slot.isLiveAgent {
                    Circle()
                        .fill(slot.agentNeedsYou ? Color.tether.warning : Color.tether.success)
                        .frame(width: 6, height: 6)
                }
                Text(slot.title)
                    .font(.caption.weight(selected ? .semibold : .regular))
                    .foregroundStyle(selected ? TerminalTheme.standard.fg : TerminalTheme.standard.dim)
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(selected ? TerminalTheme.standard.dim.opacity(0.22) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(TerminalTheme.standard.dim.opacity(selected ? 0.55 : 0.25), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Terminal \(slot.title)")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .onDrag {
            NSItemProvider(object: slot.id as NSString)
        }
        .onDrop(of: [.text], isTargeted: nil) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: NSString.self) { item, _ in
                guard let dragged = item as? String else { return }
                Task { @MainActor in
                    guard let from = store.terminalSlots.firstIndex(where: { $0.id == dragged }) else { return }
                    store.reorderTerminalSlots(from: from, to: index)
                }
            }
            return true
        }
    }

    private var virtualSurface: some View {
        VStack(spacing: 0) {
            GeometryReader { geo in
                let inner = max(120, geo.size.width - 24)
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(store.terminalLines) { line in
                                VStack(alignment: .leading, spacing: 2) {
                                    ForEach(Array(MonoLayout.wrap(line.text, maxWidth: inner, size: store.fontSize).enumerated()), id: \.offset) { _, piece in
                                        Text(piece)
                                            .font(font)
                                            .foregroundStyle(color(for: line.kind))
                                            .frame(width: inner, alignment: .leading)
                                            .textSelection(.enabled)
                                    }
                                }
                                .id(line.id)
                            }
                        }
                        .padding(12)
                        .frame(width: geo.size.width, alignment: .leading)
                    }
                    .scrollDismissesKeyboard(.never)
                    .onChange(of: store.terminalLines.count) { _, _ in
                        if let last = store.terminalLines.last?.id {
                            proxy.scrollTo(last, anchor: .bottom)
                        }
                    }
                }
            }
            .layoutPriority(0)
            if store.showCommandHelp {
                commandHelpMenu
                    .layoutPriority(1)
            } else if !suggestions.isEmpty {
                suggestionMenu
                    .layoutPriority(1)
            }
            promptRow
            if control {
                Text("Control on. C stops the command. L clears the screen.")
                    .font(.caption2)
                    .foregroundStyle(TerminalTheme.standard.dim)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.top, 4)
            }
            AccessoryKeyRow(control: control, keyboardVisible: keyboardVisible) { token in
                apply(token)
            } onKeyboard: {
                toggleKeyboard()
            }
        }
    }

    private var fetchSurface: some View {
        ScrollView {
            Text(store.fetchText ?? "")
                .font(font)
                .foregroundStyle(TerminalTheme.standard.fg)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                .padding(12)
        }
        .background(TerminalTheme.standard.bg)
    }

    private var headerSubtitle: String {
        switch store.focusedSlot?.kind {
        case .agent:
            return store.agentProgram.map { AgentPrograms.displayName($0) } ?? "agent"
        case .monitor:
            return "Monitor"
        case .fetch:
            return "fetch"
        default:
            return store.terminalCWD
        }
    }

    private var closeAccessibilityLabel: String {
        switch store.focusedSlot?.kind {
        case .agent:
            return "Close session"
        case .monitor, .fetch:
            return "Close tab"
        default:
            return store.terminalSlots.count > 1 ? "Close tab" : "Back to files"
        }
    }

    private var header: some View {
        HStack {
            Circle()
                .fill(store.offline ? Color.tether.warning : Color.tether.success)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(store.hostName)
                    .font(.caption)
                    .foregroundStyle(TerminalTheme.standard.fg)
                    .fixedSize(horizontal: false, vertical: true)
                Text(headerSubtitle)
                    .font(.caption)
                    .foregroundStyle(TerminalTheme.standard.dir)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if store.focusedSlot?.kind == .agent {
                Button {
                    // Leave Terminal without ending the live session (tab bar returns).
                    store.sessionTab = SessionTabIndex.files
                } label: {
                    Image(systemName: "folder")
                        .foregroundStyle(TerminalTheme.standard.dim)
                }
                .frame(minWidth: 44, minHeight: 44)
                .accessibilityLabel("Back to files")
                Button {
                    UIPasteboard.general.string = store.agentSurface?.screen.plainText()
                } label: {
                    Image(systemName: "doc.on.doc")
                        .foregroundStyle(TerminalTheme.standard.dim)
                }
                .frame(minWidth: 44, minHeight: 44)
                .accessibilityLabel("Copy screen")
            }
            Button {
                store.closeFocusedSlot()
            } label: {
                Image(systemName: "xmark")
                    .foregroundStyle(TerminalTheme.standard.dim)
            }
            .frame(minWidth: 44, minHeight: 44)
            .accessibilityLabel(closeAccessibilityLabel)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(TerminalTheme.standard.bg)
    }

    private var suggestionMenu: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(suggestionMenuTitle)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(TerminalTheme.standard.dim)
                Spacer()
                if suggestions.count > 8 {
                    Text("Scroll")
                        .font(.caption2)
                        .foregroundStyle(TerminalTheme.standard.prompt)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(suggestions) { item in
                        suggestionRow(item)
                    }
                }
            }
            .scrollIndicators(.visible)
            .frame(maxHeight: menuMaxHeight)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(TerminalTheme.standard.bg.opacity(0.96))
        .overlay(alignment: .top) {
            Rectangle()
                .fill(TerminalTheme.standard.dim.opacity(0.35))
                .frame(height: 1)
        }
        .accessibilityHint(suggestions.count > 8 ? "Scroll to see every match" : "")
    }

    private var suggestionMenuTitle: String {
        let files = suggestions.filter { $0.kind != .command }.count
        let commands = suggestions.count - files
        if files > 0, commands == 0 {
            return "\(files) \(files == 1 ? "match" : "matches")"
        }
        if commands > 0, files == 0 {
            return "\(commands) \(commands == 1 ? "command" : "commands")"
        }
        return "\(suggestions.count) matches"
    }

    private var commandHelpMenu: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Commands · scroll for syntax")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(TerminalTheme.standard.dim)
                Spacer()
                Button("Close") {
                    store.dismissCommandHelp()
                    focused = true
                }
                .font(.caption)
                .foregroundStyle(TerminalTheme.standard.prompt)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(CommandCatalog.all) { entry in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.syntax)
                                .font(.system(size: max(12, store.fontSize - 1), design: .monospaced))
                                .foregroundStyle(TerminalTheme.standard.fg)
                                .lineLimit(2)
                            Text(entry.usage)
                                .font(.caption2)
                                .foregroundStyle(TerminalTheme.standard.dim)
                                .lineLimit(2)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                        .onTapGesture { pickHelp(entry) }
                        .accessibilityAddTraits(.isButton)
                        .accessibilityLabel("\(entry.syntax), \(entry.usage)")
                    }
                }
            }
            .scrollIndicators(.visible)
            .frame(maxHeight: menuMaxHeight)
        }
        .background(TerminalTheme.standard.bg.opacity(0.96))
        .overlay(alignment: .top) {
            Rectangle()
                .fill(TerminalTheme.standard.dim.opacity(0.35))
                .frame(height: 1)
        }
    }

    @ViewBuilder
    private func suggestionRow(_ item: CompletionSuggestion) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol(for: item.kind))
                .font(.caption)
                .foregroundStyle(item.kind == .folder ? TerminalTheme.standard.dir : TerminalTheme.standard.dim)
                .frame(width: 16)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(suggestionTitle(item))
                    .font(.system(size: max(12, store.fontSize - 1), design: .monospaced))
                    .foregroundStyle(TerminalTheme.standard.fg)
                    .lineLimit(1)
                if let detail = suggestionDetail(item) {
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(TerminalTheme.standard.dim)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture { pickSuggestion(item) }
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(suggestionAccessibility(item))
    }

    private func suggestionTitle(_ item: CompletionSuggestion) -> String {
        guard item.kind == .command, let help = CommandCatalog.entry(named: item.display) else {
            return item.display
        }
        return help.syntax
    }

    private func suggestionDetail(_ item: CompletionSuggestion) -> String? {
        guard item.kind == .command, let help = CommandCatalog.entry(named: item.display) else {
            return nil
        }
        return help.usage
    }

    private func suggestionAccessibility(_ item: CompletionSuggestion) -> String {
        if let detail = suggestionDetail(item) {
            return "\(suggestionTitle(item)), \(detail)"
        }
        return item.display
    }

    private var promptRow: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(store.prompt)
                .font(font)
                .foregroundStyle(TerminalTheme.standard.prompt)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(alignment: .firstTextBaseline, spacing: 0) {
            TextField("", text: $draft, axis: .horizontal)
                .font(font)
                .foregroundStyle(TerminalTheme.standard.fg)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($focused)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .onSubmit {
                    submit()
                    focused = true
                }
                .onChange(of: draft) { previous, next in
                    guard next != accessoryDraft, control, next.count == previous.count + 1, previous == String(next.dropLast()), let character = next.last else {
                        if next != hintedDraft {
                            completionHint = ""
                            if store.showCommandHelp, !next.isEmpty {
                                store.dismissCommandHelp()
                            }
                            scheduleSuggestions(for: next)
                        }
                        return
                    }
                    control = false
                    draft = previous
                    clearSuggestions()
                    switch character.lowercased() {
                    case "c": store.interruptTerminal()
                    case "l":
                        store.clearTerminal()
                        completionHint = ""
                    default:
                        completionHint = "Control \(character.uppercased()) has no action in this shell."
                        hintedDraft = previous
                    }
                }
            TerminalCursor(height: store.fontSize, animate: !reduceMotion)
                .allowsHitTesting(false)
            }
            if !completionHint.isEmpty {
                Text(completionHint)
                    .font(.system(size: max(11, store.fontSize - 2), design: .monospaced))
                    .foregroundStyle(TerminalTheme.standard.dim)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 12)
        .contentShape(Rectangle())
        .onTapGesture { focused = true }
        .background(TerminalTheme.standard.bg)
    }

    private var font: Font {
        .system(size: store.fontSize, design: .monospaced)
    }

    private func color(for kind: TermLine.Kind) -> Color {
        switch kind {
        case .input: TerminalTheme.standard.fg
        case .output: TerminalTheme.standard.file
        case .error: TerminalTheme.standard.error
        case .dim: TerminalTheme.standard.dim
        case .directory: TerminalTheme.standard.dir
        }
    }

    private func submit() {
        let line = draft
        draft = ""
        completionHint = ""
        clearSuggestions()
        control = false
        Task { await store.runTerminal(line) }
    }

    private func toggleKeyboard() {
        if keyboardVisible {
            focused = false
            return
        }
        if focused {
            focused = false
            DispatchQueue.main.async { focused = true }
        } else {
            focused = true
        }
    }

    private func apply(_ token: String) {
        switch token {
        case "Tab":
            completeDraft()
        case "Esc":
            control = false
            if store.showCommandHelp {
                store.dismissCommandHelp()
            } else if !suggestions.isEmpty {
                clearSuggestions()
            } else {
                draft = ""
            }
            completionHint = ""
        case "Ctrl":
            control.toggle()
        case "C-c":
            control = false
            store.interruptTerminal()
            clearSuggestions()
        case "C-l":
            control = false
            store.clearTerminal()
            completionHint = ""
            clearSuggestions()
        case "↑":
            control = false
            clearSuggestions()
            guard !store.history.isEmpty else { return }
            store.historyIndex = max(0, store.historyIndex - 1)
            draft = store.history[store.historyIndex]
        case "↓":
            control = false
            clearSuggestions()
            guard !store.history.isEmpty else { return }
            store.historyIndex = min(store.history.count, store.historyIndex + 1)
            draft = store.historyIndex == store.history.count ? "" : store.history[store.historyIndex]
        default:
            control = false
            accessoryDraft = draft + token
            draft.append(token)
        }
        focused = true
        DispatchQueue.main.async { focused = true }
    }

    private func completeDraft() {
        completionToken += 1
        let token = completionToken
        let current = draft
        control = false
        store.dismissCommandHelp()
        Task {
            let result = await store.completeTerminalLine(current)
            guard token == completionToken, draft == current else { return }
            hintedDraft = result.line
            draft = result.line
            completionHint = result.hint
            suggestions = result.suggestions
            if result.suggestions.isEmpty, result.line != current {
                scheduleSuggestions(for: result.line)
            }
            focused = true
        }
    }

    private func scheduleSuggestions(for line: String) {
        suggestToken += 1
        let token = suggestToken
        guard !control, store.agentProgram == nil else {
            suggestions = []
            return
        }
        Task {
            try? await Task.sleep(for: .milliseconds(180))
            guard token == suggestToken, draft == line else { return }
            let listed = await store.terminalSuggestions(for: line)
            guard token == suggestToken, draft == line else { return }
            suggestions = listed
        }
    }

    private func pickSuggestion(_ item: CompletionSuggestion) {
        let next = store.applyTerminalSuggestion(item, to: draft)
        hintedDraft = next
        draft = next
        completionHint = ""
        if item.kind == .command, item.display == "help" {
            clearSuggestions()
            draft = ""
            Task { await store.runTerminal("help") }
            focused = true
            return
        }
        if item.isDirectory || item.kind == .command {
            scheduleSuggestions(for: next)
        } else {
            clearSuggestions()
        }
        focused = true
    }

    private func pickHelp(_ entry: CommandHelp) {
        if entry.name == "help" {
            focused = true
            return
        }
        let next = store.applyCommandHelp(entry)
        hintedDraft = next
        draft = next
        clearSuggestions()
        scheduleSuggestions(for: next)
        focused = true
    }

    private func clearSuggestions() {
        suggestToken += 1
        suggestions = []
    }

    private func symbol(for kind: CompletionKind) -> String {
        switch kind {
        case .command: "terminal"
        case .folder: "folder"
        case .file: "doc"
        }
    }
}

struct AccessoryKeyRow: View {
    var control: Bool
    var keyboardVisible: Bool
    var onKey: (String) -> Void
    var onKeyboard: () -> Void
    private var keys: [String] {
        control ? ["C-c", "C-l", "Esc", "Tab", "Ctrl", "↑", "↓"] : ["Tab", "Esc", "Ctrl", "↑", "↓", "/", "~", "-", "|"]
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Button(action: onKeyboard) {
                    Image(systemName: keyboardVisible ? "keyboard.chevron.compact.down" : "keyboard")
                        .font(.body)
                        .frame(minWidth: 44, minHeight: 44)
                        .foregroundStyle(TerminalTheme.standard.fg)
                        .overlay {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(TerminalTheme.standard.dim, lineWidth: 1)
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(keyboardVisible ? "Hide keyboard" : "Show keyboard")
                ForEach(keys, id: \.self) { key in
                    Button(key) { onKey(key) }
                        .buttonStyle(.plain)
                        .font(.system(.body, design: .monospaced))
                        .frame(minWidth: 44, minHeight: 44)
                        .foregroundStyle(TerminalTheme.standard.fg)
                        .background(
                            key == "Ctrl" && control ? TerminalTheme.standard.prompt.opacity(0.28) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(TerminalTheme.standard.dim, lineWidth: 1)
                        }
                        .accessibilityLabel(key == "Ctrl" ? (control ? "Control, on" : "Control") : key)
                        .accessibilityHint(key == "Ctrl" ? "Turns Control on. The next letter is a shortcut. C stops a command. L clears the screen." : "")
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
        }
        .background(TerminalTheme.standard.bg)
    }
}

private struct TerminalCursor: View {
    var height: Double
    var animate: Bool
    @State private var shown = true

    var body: some View {
        Rectangle()
            .fill(TerminalTheme.standard.prompt)
            .frame(width: 8, height: height)
            .opacity(shown ? 1 : 0)
            .task {
                guard animate else { return }
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(530))
                    shown.toggle()
                }
            }
    }
}
