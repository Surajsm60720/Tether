import SwiftUI

enum HostPage: String, CaseIterable, Identifiable {
    case overview
    case folders
    case phones
    case activity

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: "Status"
        case .folders: "Shared folders"
        case .phones: "iPhones"
        case .activity: "Activity"
        }
    }

    var symbol: String {
        switch self {
        case .overview: "link"
        case .folders: "folder"
        case .phones: "iphone"
        case .activity: "list.bullet"
        }
    }
}

struct HostWindow: View {
    @Bindable var store: HostStore
    @State private var page: HostPage? = .overview
    @State private var showPairing = false
    @State private var pendingRevoke: DeviceItem?
    @State private var filter = ""

    var body: some View {
        NavigationSplitView {
            List(HostPage.allCases, selection: $page) { item in
                Label(item.title, systemImage: item.symbol)
                    .tag(item)
            }
            .navigationSplitViewColumnWidth(min: 196, ideal: 220)
        } detail: {
            NavigationStack {
                detail
                    .navigationTitle(page?.title ?? "Tether")
                    .toolbar {
                        ToolbarItem(placement: .primaryAction) {
                            Button(L10n.pair) {
                                store.beginPairing()
                                showPairing = true
                            }
                        }
                        if page == .folders {
                            ToolbarItem(placement: .automatic) {
                                Button(L10n.addFolder) { store.addFolder() }
                            }
                        }
                    }
            }
        }
        .frame(minWidth: 860, minHeight: 540)
        .sheet(isPresented: $showPairing) {
            PairingWindow(store: store)
        }
        .confirmationDialog(
            "Revoke \(pendingRevoke?.name ?? "this iPhone")?",
            isPresented: Binding(
                get: { pendingRevoke != nil },
                set: { if !$0 { pendingRevoke = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Revoke", role: .destructive) {
                if let pendingRevoke { store.revoke(pendingRevoke) }
                pendingRevoke = nil
            }
            Button("Cancel", role: .cancel) { pendingRevoke = nil }
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch page ?? .overview {
        case .overview:
            overview
        case .folders:
            folders
        case .phones:
            phones
        case .activity:
            activity
        }
    }

    private var overview: some View {
        Form {
            Section {
                LabeledContent("Sharing") {
                    Text(store.statusText)
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Network") {
                    Text(store.networkLine)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                }
                Toggle("Sharing", isOn: Binding(
                    get: { store.sharingEnabled },
                    set: { store.setSharing($0) }
                ))
                if let stale = store.staleMessage {
                    Text(stale)
                        .foregroundStyle(Color.tether.warning)
                }
            }
            Section(L10n.connectedDevices) {
                if store.connected.isEmpty {
                    Text("No iPhone is connected.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(store.connected) { device in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(device.name)
                                Text(device.since, style: .relative)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                            Spacer()
                            Button(L10n.disconnect) { store.disconnect(device) }
                        }
                    }
                }
            }
            Section {
                if store.shares.isEmpty {
                    Text(L10n.welcomeBody)
                        .foregroundStyle(.secondary)
                    Button(L10n.addFolder) { store.addFolder() }
                } else {
                    ForEach(store.shares) { share in
                        LabeledContent(share.name, value: share.writable ? L10n.canUpload : L10n.readOnly)
                    }
                }
            } header: {
                Text(L10n.sharedFolders)
            }
        }
        .formStyle(.grouped)
    }

    private var folders: some View {
        VStack(alignment: .leading, spacing: 12) {
            if store.shares.isEmpty {
                ContentUnavailableView("No shared folders", systemImage: "folder", description: Text(L10n.welcomeBody))
            } else {
                Table(store.shares) {
                    TableColumn("Name") { share in
                        Text(share.name)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    TableColumn("Access") { share in
                        Toggle(share.writable ? L10n.canUpload : L10n.readOnly, isOn: Binding(
                            get: { share.writable },
                            set: { store.setWritable(share, $0) }
                        ))
                        .toggleStyle(.checkbox)
                    }
                    TableColumn("") { share in
                        Button("Remove", role: .destructive) { store.remove(share) }
                    }
                    .width(90)
                }
            }
            HStack {
                Button(L10n.addFolder) { store.addFolder() }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
        }
    }

    private var phones: some View {
        List {
            if store.devices.isEmpty {
                ContentUnavailableView("No iPhones paired yet", systemImage: "iphone", description: Text("Pair an iPhone to browse the folders you share."))
            }
            ForEach(store.devices) { device in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(device.name)
                        Text(device.lastSeenAt?.formatted(date: .abbreviated, time: .shortened) ?? "Not seen yet")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if store.connected.contains(where: { $0.id == device.id }) {
                        Text("Connected")
                            .font(.caption)
                            .foregroundStyle(Color.tether.success)
                    }
                    Button(L10n.revoke, role: .destructive) { pendingRevoke = device }
                }
                .frame(minHeight: 44)
            }
        }
    }

    private var activity: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("Filter", text: $filter)
                    .textFieldStyle(.roundedBorder)
                Button(L10n.clear) { store.clearActivity() }
            }
            .padding([.horizontal, .top], 16)
            List(filtered) { event in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(event.date.formatted(date: .omitted, time: .standard))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 88, alignment: .leading)
                    Text(event.text)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
        }
    }

    private var filtered: [ActivityEvent] {
        guard !filter.isEmpty else { return store.activity }
        return store.activity.filter { $0.text.localizedCaseInsensitiveContains(filter) }
    }
}

#Preview("Host window") {
    HostWindow(store: HostStore(context: PreviewStore.context))
        .frame(width: 900, height: 580)
}
