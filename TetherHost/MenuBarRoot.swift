import AppKit
import SwiftUI

struct MenuBarRoot: View {
    @Bindable var store: HostStore
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.appName)
                .font(.headline)
            Text(store.statusText)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text(store.networkLine)
                .font(.caption)
                .foregroundStyle(.secondary)
            Divider()
            Button("Open Tether") { showMainWindow() }
                .keyboardShortcut("o")
            Button(L10n.pair) {
                store.beginPairing()
                openWindow(id: "pair")
            }
            Button(L10n.quit) { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }
        .padding(16)
        .frame(width: 280, alignment: .leading)
    }

    private func showMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { $0.identifier?.rawValue != "pair" && $0.canBecomeMain && !$0.title.isEmpty }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            openWindow(id: "main")
        }
    }
}

#Preview("Menu") {
    MenuBarRoot(store: HostStore(context: PreviewStore.context))
}
