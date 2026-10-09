import SwiftUI

enum HostPage: String, CaseIterable, Identifiable {
    case overview
    case folders
    case inbox
    case phones

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: "Status"
        case .folders: "Shared folders"
        case .inbox: "Inbox"
        case .phones: "iPhones"
        }
    }

    var symbol: String {
        switch self {
        case .overview: "link"
        case .folders: "folder"
        case .inbox: "tray.and.arrow.down"
        case .phones: "iphone"
        }
    }
}

struct HostWindow: View {
    @Bindable var store: HostStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openWindow) private var openWindow
    @State private var page: HostPage? = .overview
    @State private var showPairing = false

    var body: some View {
        NavigationSplitView {
            List(selection: $page) {
                Section {
                    ForEach(HostPage.allCases) { item in
                        Label {
                            HStack {
                                Text(item.title)
                                if item == .inbox, store.inboxUnseenCount > 0 {
                                    Text("\(store.inboxUnseenCount)")
                                        .font(.caption2.monospacedDigit())
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Capsule().fill(Color.tether.accent.opacity(0.25)))
                                }
                            }
                        } icon: {
                            Image(systemName: item.symbol)
                                .symbolRenderingMode(.hierarchical)
                        }
                        .tag(item)
                    }
                }
                Section {
                    SettingsLink {
                        Label("Settings", systemImage: "gearshape")
                            .symbolRenderingMode(.hierarchical)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 196, ideal: 220)
            .safeAreaInset(edge: .bottom) {
                sidebarStatus
            }
        } detail: {
            NavigationStack {
                detail
                    .animation(TetherMotion.fade(reduceMotion), value: page)
                    .navigationTitle(page?.title ?? "Tether")
                    .toolbar {
                        ToolbarItem(placement: .primaryAction) {
                            Button(L10n.pair) {
                                store.beginPairing()
                                showPairing = true
                            }
                        }
                    }
            }
        }
        .frame(minWidth: 860, minHeight: 540)
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { store.refreshPhones(announce: false) }
        }
        .onChange(of: store.shelfPresentationToken) { _, _ in
            openWindow(id: "shelf")
        }
        .sheet(isPresented: $showPairing) {
            PairingWindow(store: store)
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch page ?? .overview {
        case .overview:
            overview
        case .folders:
            folders
        case .inbox:
            InboxView(store: store)
        case .phones:
            phones
        }
    }

    private var sidebarStatus: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(store.sharingEnabled ? (store.connected.isEmpty ? Color.tether.warning : Color.tether.success) : Color.secondary)
                .frame(width: 8, height: 8)
            Text(store.sharingEnabled ? (store.connected.isEmpty ? "Waiting" : "Connected") : "Paused")
                .font(TetherType.meta)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
    }

    private var overview: some View {
        Form {
            Section {
                HStack(alignment: .center, spacing: 16) {
                    Image(systemName: store.sharingEnabled ? "laptopcomputer" : "pause.circle")
                        .font(TetherType.hero)
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(store.sharingEnabled ? Color.tether.accentText : Color.secondary)
                        .symbolEffect(.bounce, value: store.connected.count)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(store.macName)
                            .font(TetherType.title)
                        Label(store.statusText, systemImage: store.connected.isEmpty ? "circle" : "checkmark.circle.fill")
                            .font(TetherType.secondary)
                            .foregroundStyle(.secondary)
                            .symbolRenderingMode(.hierarchical)
                        Text(store.networkLine)
                            .font(TetherType.meta)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 4)
            }
            Section {
                Toggle("Sharing", isOn: Binding(
                    get: { store.sharingEnabled },
                    set: { store.setSharing($0) }
                ))
                if store.remoteEnabled {
                    LabeledContent("Other networks") {
                        Text(store.relayStatus.isEmpty ? "Listening" : store.relayStatus)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.trailing)
                    }
                }
                if let stale = store.staleMessage {
                    Text(stale)
                        .foregroundStyle(Color.tether.warning)
                }
            } footer: {
                Text("Pause sharing anytime. Rename this Mac and other preferences are in Settings.")
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
                    TableColumn("Allow uploads") { share in
                        Toggle("Allow uploads", isOn: Binding(
                            get: { share.writable },
                            set: { store.setWritable(share, $0) }
                        ))
                        .toggleStyle(.checkbox)
                        .labelsHidden()
                    }
                    TableColumn("") { share in
                        Button("Remove", role: .destructive) { store.remove(share) }
                    }
                    .width(90)
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                Button(L10n.addFolder) { store.addFolder() }
                Text("Turn on Allow uploads when the iPhone should add files. Leave it off and the iPhone can only look at and download files.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
        }
    }

    private var phones: some View {
        List {
            Section {
                if store.nearbyPhones.isEmpty {
                    Text("Open Tether on the iPhone. It will show up here, under the name set on the iPhone, while that app is open.")
                        .foregroundStyle(.secondary)
                }
                Button("Look again") { store.refreshPhones() }
                ForEach(store.nearbyPhones) { phone in
                    HStack(spacing: 12) {
                        Image(systemName: "iphone")
                            .font(TetherType.title)
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(Color.tether.accentText)
                            .frame(width: 36)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(phone.name)
                                .font(TetherType.body)
                            Text(store.devices.contains { phone.matches(savedHostId: $0.id) } ? "Paired" : "Not paired yet")
                                .font(TetherType.meta)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if store.devices.contains(where: { phone.matches(savedHostId: $0.id) }) {
                            Button("Connect") { store.connect(phone: phone) }
                        } else {
                            Button("Pair") {
                                store.beginPairing()
                                showPairing = true
                            }
                        }
                    }
                    .frame(minHeight: 44)
                }
                if let phoneStatus = store.phoneStatus {
                    Text(phoneStatus)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("On this network")
            } footer: {
                Text("Paired iPhones and Revoke are in Settings → Devices.")
            }
        }
    }
}

#Preview("Host window") {
    HostWindow(store: HostStore(context: PreviewStore.context))
        .frame(width: 900, height: 580)
}
