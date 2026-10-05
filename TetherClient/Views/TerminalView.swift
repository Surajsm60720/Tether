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

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(store.terminalLines) { line in
                            Text(line.text.isEmpty ? " " : line.text)
                                .font(font)
                                .foregroundStyle(color(for: line.kind))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                                .id(line.id)
                        }
                    }
                    .padding(12)
                }
                .scrollDismissesKeyboard(.never)
                .onChange(of: store.terminalLines.count) { _, _ in
                    if let last = store.terminalLines.last?.id {
                        proxy.scrollTo(last, anchor: .bottom)
                    }
                }
            }
            promptRow
            AccessoryKeyRow { token in
                apply(token)
            }
        }
        .background(TerminalTheme.standard.bg)
        .onAppear { focused = true }
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

    private var header: some View {
        HStack {
            Circle()
                .fill(store.offline ? Color.tether.warning : Color.tether.success)
                .frame(width: 8, height: 8)
            Text(store.hostName)
                .font(.caption)
                .foregroundStyle(TerminalTheme.standard.fg)
            Text(store.terminalCWD)
                .font(.caption)
                .foregroundStyle(TerminalTheme.standard.dir)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Button {
                store.sessionTab = 0
            } label: {
                Image(systemName: "xmark")
                    .foregroundStyle(TerminalTheme.standard.dim)
            }
            .accessibilityLabel("Back to files")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(TerminalTheme.standard.bg)
    }

    private var promptRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(store.prompt)
                .font(font)
                .foregroundStyle(TerminalTheme.standard.prompt)
                .lineLimit(1)
                .truncationMode(.middle)
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
            TerminalCursor(height: store.fontSize, animate: !reduceMotion)
                .allowsHitTesting(false)
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
        Task { await store.runTerminal(line) }
    }

    private func apply(_ token: String) {
        switch token {
        case "Tab":
            draft += suggested
        case "Esc":
            draft = ""
        case "Ctrl":
            break
        case "↑":
            guard !store.history.isEmpty else { return }
            store.historyIndex = max(0, store.historyIndex - 1)
            draft = store.history[store.historyIndex]
        case "↓":
            guard !store.history.isEmpty else { return }
            store.historyIndex = min(store.history.count, store.historyIndex + 1)
            draft = store.historyIndex == store.history.count ? "" : store.history[store.historyIndex]
        default:
            draft.append(token)
        }
        focused = true
        DispatchQueue.main.async { focused = true }
    }

    private var suggested: String {
        let partial = draft.split(separator: " ").last.map(String.init) ?? ""
        let commands = TerminalEngine.commandNames
        if draft.contains(" ") {
            return store.entries.first { $0.name.hasPrefix(partial) }?.name.dropFirst(partial.count).description ?? ""
        }
        return commands.first { $0.hasPrefix(partial) }?.dropFirst(partial.count).description ?? ""
    }
}

struct AccessoryKeyRow: View {
    var onKey: (String) -> Void
    private let keys = ["Tab", "Esc", "Ctrl", "↑", "↓", "/", "~", "-", "|"]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(keys, id: \.self) { key in
                    Button(key) { onKey(key) }
                        .buttonStyle(.plain)
                        .font(.system(.body, design: .monospaced))
                        .frame(minWidth: 44, minHeight: 44)
                        .overlay {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(TerminalTheme.standard.dim, lineWidth: 1)
                        }
                        .foregroundStyle(TerminalTheme.standard.fg)
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
