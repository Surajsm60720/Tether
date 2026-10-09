import AppKit
import SwiftUI

struct MenuBarRoot: View {
    @Bindable var store: HostStore
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: store.sharingEnabled ? "laptopcomputer" : "pause.circle")
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(store.sharingEnabled ? Color.tether.accentText : Color.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.appName)
                        .font(TetherType.section)
                    Text(store.statusText)
                        .font(TetherType.secondary)
                        .foregroundStyle(.secondary)
                    Text(store.networkLine)
                        .font(TetherType.meta)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            Toggle("Sharing", isOn: Binding(
                get: { store.sharingEnabled },
                set: { store.setSharing($0) }
            ))
            .toggleStyle(.switch)
            .font(TetherType.secondary)

            if !store.connected.isEmpty {
                Divider()
                Text(L10n.connectedDevices)
                    .font(TetherType.meta)
                    .foregroundStyle(.secondary)
                ForEach(store.connected.prefix(3)) { device in
                    HStack {
                        Circle().fill(Color.tether.success).frame(width: 8, height: 8)
                        Text(device.name)
                            .font(TetherType.body)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        Button(L10n.disconnect) { store.disconnect(device) }
                            .font(TetherType.meta)
                    }
                }
            }

            if !store.shares.isEmpty {
                Divider()
                Text(L10n.sharedFolders)
                    .font(TetherType.meta)
                    .foregroundStyle(.secondary)
                ForEach(store.shares.prefix(3)) { share in
                    HStack(spacing: 8) {
                        Image(systemName: "folder.fill")
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(Color.tether.accentText)
                        Text(share.name)
                            .font(TetherType.body)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 8)
                        Text(share.writable ? L10n.canUpload : L10n.readOnly)
                            .font(TetherType.meta)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Divider()
            if store.inboxUnseenCount > 0 {
                Text("\(store.inboxUnseenCount) new")
                    .font(TetherType.meta)
                    .foregroundStyle(Color.tether.accentText)
            }
            Button(store.inboxUnseenCount > 0 ? "Show received" : "Show Shelf") {
                store.presentShelf()
            }
            Button("Open Tether") { showMainWindow() }
                .keyboardShortcut("o")
            Button(L10n.pair) {
                store.beginPairing()
                openWindow(id: "pair")
            }
            SettingsLink {
                Text(L10n.settings)
            }
            Button(L10n.quit) { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }
        .padding(16)
        .frame(width: 320, alignment: .leading)
        .tint(Color.tether.accent)
        .onChange(of: store.shelfPresentationToken) { _, _ in
            openWindow(id: "shelf")
        }
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
