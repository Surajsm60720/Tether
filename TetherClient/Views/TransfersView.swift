import SwiftUI

struct TransfersView: View {
    @Bindable var store: ClientStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var selection = Set<UUID>()

    var body: some View {
        NavigationStack {
            List(selection: $selection) {
                if scenePhase != .active && !store.activeTransfers.isEmpty {
                    Text(L10n.keepOpen)
                        .font(.footnote)
                        .foregroundStyle(Color.tether.warning)
                }
                if !store.activeTransfers.isEmpty {
                    Section("Active") {
                        ForEach(store.activeTransfers) { item in
                            TransferRow(item: item, onCancel: { store.cancel(item) }, onOpen: nil)
                        }
                    }
                }
                if !store.finishedTransfers.isEmpty {
                    Section("Completed") {
                        ForEach(store.finishedTransfers) { item in
                            TransferRow(item: item, onCancel: nil, onOpen: { store.showPreview(item) })
                                .tag(item.id)
                                .swipeActions {
                                    Button("Remove", role: .destructive) { store.removeTransfer(item) }
                                    if item.state == .failed {
                                        Button("Retry") { Task { await store.retry(item) } }
                                    }
                                }
                        }
                    }
                }
                if store.transfers.isEmpty {
                    ContentUnavailableView("No transfers", systemImage: "arrow.up.arrow.down")
                }
            }
            .navigationTitle(L10n.transfers)
            .toolbar {
                EditButton()
                if selection.isEmpty {
                    Button("Clear all") { store.clearCompleted() }
                        .disabled(store.finishedTransfers.isEmpty)
                } else {
                    Button("Clear selected") {
                        store.removeTransfers(selection)
                        selection.removeAll()
                    }
                }
            }
        }
    }
}

struct TransferRow: View {
    var item: TransferItem
    var onCancel: (() -> Void)?
    var onOpen: (() -> Void)?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: item.direction == .down ? "arrow.down.circle" : "arrow.up.circle")
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(item.state == .failed ? Color.tether.danger : Color.tether.accentText)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.name)
                    .font(.body)
                    .lineLimit(1)
                    .truncationMode(.middle)
                ProgressView(value: item.fraction)
                    .tint(item.state == .failed ? Color.tether.danger : Color.tether.accent)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(item.state == .failed ? Color.tether.danger : .secondary)
                    .monospacedDigit()
            }
            if item.state == .active, let onCancel {
                Button("Cancel", role: .destructive, action: onCancel)
                    .buttonStyle(.bordered)
            }
        }
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        .onTapGesture {
            if item.state == .completed { onOpen?() }
        }
        .accessibilityElement(children: .combine)
    }

    private var detail: String {
        if item.state == .failed { return item.message ?? "Failed · Retry" }
        if item.state == .completed { return "Done" }
        let rate = Format.speed(bytes: item.sent, since: item.started)
        let eta = Format.eta(sent: item.sent, total: item.total, since: item.started)
        return eta.isEmpty ? rate : "\(rate) · \(eta)"
    }
}
