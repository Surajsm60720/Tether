import AppKit
import SwiftUI
import TetherCore

struct InboxView: View {
    @Bindable var store: HostStore
    @State private var confirmClear = false

    var body: some View {
        Group {
            if store.inboxItems.isEmpty {
                ContentUnavailableView {
                    Label("No files yet", systemImage: "tray")
                } description: {
                    Text("Files you send from your iPhone show up here. They are saved to \(store.inboxPathDisplay).")
                }
            } else {
                List {
                    ForEach(store.inboxItems) { item in
                        InboxRow(item: item)
                            .padding(.vertical, 6)
                            .contextMenu {
                                Button("Open") { store.openInboxItem(item) }
                                Button("Show in Finder") { store.revealInboxItem(item) }
                                Button("Move…") { store.moveInboxItem(item) }
                                Divider()
                                Button("Remove", role: .destructive) { store.deleteInboxItem(item) }
                            }
                            .onDrag {
                                NSItemProvider(contentsOf: item.url) ?? NSItemProvider()
                            }
                    }
                }
                .listStyle(.inset)
            }
        }
        .onAppear {
            store.refreshInbox()
            store.markInboxSeen()
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Clear") { confirmClear = true }
                    .disabled(store.inboxItems.isEmpty)
            }
        }
        .safeAreaInset(edge: .bottom) {
            Text("Saving to \(store.inboxPathDisplay)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.bar)
                .help("Change the Inbox folder in Settings → General.")
        }
        .confirmationDialog("Clear Inbox list?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Clear list", role: .destructive) { store.clearInbox() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Clears this list in Tether only. Files stay in the destination folder.")
        }
    }
}

private struct InboxRow: View {
    let item: InboxItem

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: item.url.path))
                .resizable()
                .frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.name)
                    .font(.body)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(item.destination)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help(item.destination)
                HStack(spacing: 8) {
                    Text(item.modified.formatted(date: .abbreviated, time: .shortened))
                    Text(ByteCountFormatter.string(fromByteCount: Int64(item.size), countStyle: .file))
                    if let sender = item.sender {
                        Text(sender)
                    }
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }
        }
        .frame(minHeight: 64, alignment: .topLeading)
        .padding(.vertical, 2)
    }
}
