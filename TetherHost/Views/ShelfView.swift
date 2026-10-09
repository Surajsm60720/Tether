import AppKit
import SwiftUI
import TetherCore

struct ShelfView: View {
    @Bindable var store: HostStore
    @State private var selected: Set<UUID> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Shelf", systemImage: "shippingbox")
                    .font(TetherType.section)
                    .foregroundStyle(Color.tether.accentText)
                Spacer()
                if !store.shelfItems.isEmpty {
                    Text(selectionLabel)
                        .font(TetherType.meta)
                        .foregroundStyle(.secondary)
                }
            }

            if store.shelfItems.isEmpty {
                Text("Only the latest batch from your iPhone appears here. Drag files into any app.")
                    .font(TetherType.secondary)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(store.shelfItems) { item in
                            ShelfDraggableTile(
                                item: item,
                                selected: selected.contains(item.id),
                                urlsForDrag: { dragURLs(startingWith: item) },
                                onToggle: { toggle(item.id) }
                            )
                            .frame(width: 104, height: 100)
                            .contextMenu {
                                Button(selected.contains(item.id) ? "Deselect" : "Select") {
                                    toggle(item.id)
                                }
                                Button("Select all") {
                                    selected = Set(store.shelfItems.map(\.id))
                                }
                                .disabled(store.shelfItems.count < 2)
                                Divider()
                                Button("Open") { store.openInboxItem(item) }
                                Button("Show in Finder") { store.revealInboxItem(item) }
                                Button("Remove", role: .destructive) {
                                    selected.remove(item.id)
                                    store.deleteInboxItem(item)
                                }
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }

                HStack {
                    Button(selected.isEmpty ? "Select all" : "Clear selection") {
                        if selected.isEmpty {
                            selected = Set(store.shelfItems.map(\.id))
                        } else {
                            selected = []
                        }
                    }
                    .buttonStyle(.borderless)
                    .font(TetherType.meta)
                    Spacer()
                    Text(selected.count > 1 ? "Drag any selected file to move all \(selected.count)" : "Click to select · drag to drop")
                        .font(TetherType.meta)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(16)
        .frame(minWidth: 420, idealWidth: 560, minHeight: 140, idealHeight: 168)
        .background(ShelfWindowChrome())
        .onAppear {
            store.refreshInbox()
            store.markInboxSeen()
            selected = selected.intersection(Set(store.shelfItems.map(\.id)))
        }
        .onChange(of: store.shelfItems) { _, items in
            selected = selected.intersection(Set(items.map(\.id)))
        }
    }

    private var selectionLabel: String {
        if selected.isEmpty {
            return "\(store.shelfItems.count) new"
        }
        return "\(selected.count) selected"
    }

    private func toggle(_ id: UUID) {
        if selected.contains(id) {
            selected.remove(id)
        } else {
            selected.insert(id)
        }
    }

    private func dragURLs(startingWith item: InboxItem) -> [URL] {
        if selected.contains(item.id), selected.count > 1 {
            return store.shelfItems.filter { selected.contains($0.id) }.map(\.url)
        }
        return [item.url]
    }
}

/// AppKit drag source so multiple file URLs land on the pasteboard together.
private struct ShelfDraggableTile: NSViewRepresentable {
    let item: InboxItem
    let selected: Bool
    let urlsForDrag: () -> [URL]
    let onToggle: () -> Void

    func makeNSView(context: Context) -> ShelfTileNSView {
        let view = ShelfTileNSView()
        view.onToggle = onToggle
        view.urlsForDrag = urlsForDrag
        context.coordinator.hosting = NSHostingView(
            rootView: ShelfTileChrome(item: item, selected: selected)
        )
        if let hosting = context.coordinator.hosting {
            hosting.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(hosting)
            NSLayoutConstraint.activate([
                hosting.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                hosting.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                hosting.topAnchor.constraint(equalTo: view.topAnchor),
                hosting.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            ])
        }
        return view
    }

    func updateNSView(_ nsView: ShelfTileNSView, context: Context) {
        nsView.onToggle = onToggle
        nsView.urlsForDrag = urlsForDrag
        context.coordinator.hosting?.rootView = ShelfTileChrome(item: item, selected: selected)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var hosting: NSHostingView<ShelfTileChrome>?
    }
}

private struct ShelfTileChrome: View {
    let item: InboxItem
    let selected: Bool

    var body: some View {
        VStack(spacing: 6) {
            ZStack(alignment: .topTrailing) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: item.url.path))
                    .resizable()
                    .frame(width: 48, height: 48)
                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, Color.tether.accent)
                        .font(.system(size: 14))
                        .offset(x: 4, y: -4)
                }
            }
            Text(item.name)
                .font(TetherType.meta)
                .lineLimit(2)
                .truncationMode(.middle)
                .frame(width: 88)
                .multilineTextAlignment(.center)
        }
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(selected ? Color.tether.accent : Color.clear, lineWidth: 2)
        )
        .allowsHitTesting(false)
    }
}

private final class ShelfTileNSView: NSView, NSDraggingSource {
    var onToggle: (() -> Void)?
    var urlsForDrag: (() -> [URL])?
    private var mouseDownEvent: NSEvent?
    private var didDrag = false

    override var isFlipped: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        mouseDownEvent = event
        didDrag = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard !didDrag, let start = mouseDownEvent else { return }
        let delta = hypot(event.locationInWindow.x - start.locationInWindow.x, event.locationInWindow.y - start.locationInWindow.y)
        guard delta >= 4 else { return }
        let urls = urlsForDrag?() ?? []
        guard !urls.isEmpty else { return }
        didDrag = true
        let items = urls.map { url -> NSDraggingItem in
            let item = NSDraggingItem(pasteboardWriter: url as NSURL)
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            item.setDraggingFrame(bounds, contents: icon)
            return item
        }
        beginDraggingSession(with: items, event: start, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        if !didDrag {
            onToggle?()
        }
        mouseDownEvent = nil
        didDrag = false
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }
}

private struct ShelfWindowChrome: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.level = .floating
            window.collectionBehavior.insert([.canJoinAllSpaces, .fullScreenAuxiliary])
            window.isMovableByWindowBackground = true
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            nsView.window?.level = .floating
        }
    }
}
