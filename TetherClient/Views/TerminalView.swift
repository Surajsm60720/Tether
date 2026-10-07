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

    var body: some View {
        VStack(spacing: 0) {
            header
            if store.agentProgram != nil {
                AgentTerminalView(store: store)
            } else {
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
        .background(TerminalTheme.standard.bg)
        // Live agent: hide the tab bar so the PTY and key row use the full bottom edge.
        .toolbar(store.agentProgram != nil && !store.agentExited ? .hidden : .automatic, for: .tabBar)
        .onAppear {
            if store.sessionTab == 1 { focused = store.agentProgram == nil }
        }
        .onChange(of: store.agentProgram) { _, program in
            if program == nil, store.sessionTab == 1 { focused = true }
        }
        .onChange(of: store.sessionTab) { _, tab in
            // Leaving Terminal must drop the keyboard so Files and Transfers get the full screen.
            // The agent session itself stays alive in ClientStore until X ends it.
            if tab != 1 {
                focused = false
            } else if store.agentProgram == nil {
                focused = true
            }
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
        .fullScreenCover(isPresented: $store.showMonitor) {
            MonitorScreen(store: store)
        }
        .onChange(of: store.requestUpload) { _, requested in
            if requested {
                importing = true
                store.requestUpload = false
            }
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
                Text(store.agentProgram.map { AgentPrograms.displayName($0) } ?? store.terminalCWD)
                    .font(.caption)
                    .foregroundStyle(TerminalTheme.standard.dir)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if store.agentProgram != nil {
                Button {
                    // Leave Terminal without ending the live session (tab bar returns).
                    store.sessionTab = 0
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
                if store.agentProgram != nil {
                    Task { await store.finishAgent() }
                } else {
                    store.sessionTab = 0
                }
            } label: {
                Image(systemName: "xmark")
                    .foregroundStyle(TerminalTheme.standard.dim)
            }
            .frame(minWidth: 44, minHeight: 44)
            .accessibilityLabel(store.agentProgram == nil ? "Back to files" : "Close session")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(TerminalTheme.standard.bg)
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
                        if next != hintedDraft { completionHint = "" }
                        return
                    }
                    control = false
                    draft = previous
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
            draft = ""
            completionHint = ""
        case "Ctrl":
            control.toggle()
        case "C-c":
            control = false
            store.interruptTerminal()
        case "C-l":
            control = false
            store.clearTerminal()
            completionHint = ""
        case "↑":
            control = false
            guard !store.history.isEmpty else { return }
            store.historyIndex = max(0, store.historyIndex - 1)
            draft = store.history[store.historyIndex]
        case "↓":
            control = false
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
        Task {
            let result = await store.completeTerminalLine(current)
            guard token == completionToken, draft == current else { return }
            hintedDraft = result.line
            draft = result.line
            completionHint = result.hint
            focused = true
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
