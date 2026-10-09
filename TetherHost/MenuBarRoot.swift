import AppKit
import SwiftUI

/// Classic menu-bar menu (not a custom window). Native rows, no pill buttons.
struct MenuBarRoot: View {
    @Bindable var store: HostStore
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Toggle("Sharing", isOn: Binding(
            get: { store.sharingEnabled },
            set: { store.setSharing($0) }
        ))

        if !store.connected.isEmpty {
            Divider()
            ForEach(store.connected.prefix(3)) { device in
                Button("Disconnect \(device.name)") {
                    store.disconnect(device)
                }
            }
        }

        Divider()

        if store.inboxUnseenCount > 0 {
            Text("\(store.inboxUnseenCount) new")
        }

        Button("Show Shelf") {
            store.presentShelf()
            openWindow(id: "shelf")
        }

        Button("Open Tether") {
            showMainWindow()
        }
        .keyboardShortcut("o")

        Button(L10n.pair) {
            store.beginPairing()
            openWindow(id: "pair")
        }

        SettingsLink {
            Text(L10n.settings)
        }

        Divider()

        Button(L10n.quit) {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
    }

    private func showMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: {
            $0.identifier?.rawValue != "pair"
                && $0.identifier?.rawValue != "shelf"
                && $0.canBecomeMain
                && !$0.title.isEmpty
        }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            openWindow(id: "main")
        }
    }
}
