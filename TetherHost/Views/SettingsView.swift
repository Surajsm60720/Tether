import SwiftData
import SwiftUI

struct SettingsView: View {
    @Bindable var store: HostStore
    @State private var filter = ""
    @State private var pendingRevoke: DeviceItem?
    @State private var nameDraft = ""

    var body: some View {
        TabView {
            general
                .tabItem { Label(L10n.general, systemImage: "gear") }
            folders
                .tabItem { Label(L10n.folders, systemImage: "folder") }
            devices
                .tabItem { Label(L10n.devices, systemImage: "iphone") }
            activity
                .tabItem { Label(L10n.activity, systemImage: "list.bullet") }
        }
        .frame(width: 560, height: 380)
        .padding(16)
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
        }
    }

    private var general: some View {
        Form {
            TextField(L10n.macName, text: $nameDraft)
                .onSubmit { store.setName(nameDraft) }
            HStack {
                Button("Save name") { store.setName(nameDraft) }
                Button("Random name") {
                    let generated = FriendlyName.make()
                    nameDraft = generated
                    store.setName(generated)
                }
            }
            Toggle(L10n.launchAtLogin, isOn: Binding(
                get: { store.launchAtLogin },
                set: { store.setLaunchAtLogin($0) }
            ))
            Toggle(L10n.requireApproval, isOn: Binding(
                get: { store.requireApproval },
                set: { store.setRequireApproval($0) }
            ))
            Toggle("Sharing", isOn: Binding(
                get: { store.sharingEnabled },
                set: { store.setSharing($0) }
            ))
            Picker("Icon", selection: Binding(
                get: { AppIconChoice.current },
                set: { $0.save() }
            )) {
                ForEach(AppIconChoice.allCases) { choice in
                    Text(choice.title).tag(choice)
                }
            }
            Text("Light and Dark follow the Mac’s appearance while Tether is open.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .onAppear { nameDraft = store.macName }
        .onChange(of: store.macName) { _, name in nameDraft = name }
    }

    private var folders: some View {
        VStack(alignment: .leading, spacing: 8) {
            Table(store.shares) {
                TableColumn("Name") { share in
                    TextField("Name", text: Binding(
                        get: { share.name },
                        set: { store.rename(share, to: $0) }
                    ))
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
            }
            Text("Allow uploads lets the iPhone add files. Leave it off to only allow browsing and downloads. Add folders from the main Tether window.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var devices: some View {
        List {
            if store.devices.isEmpty {
                Text("No iPhones paired yet.")
                    .foregroundStyle(.secondary)
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
                    Button(L10n.revoke, role: .destructive) { pendingRevoke = device }
                }
            }
        }
    }

    private var activity: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("Filter", text: $filter)
                Button(L10n.clear) { store.clearActivity() }
            }
            List(filtered) { event in
                HStack(alignment: .firstTextBaseline) {
                    Text(event.date.formatted(date: .omitted, time: .standard))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Text(event.text)
                        .font(.system(.caption, design: .monospaced))
                }
            }
        }
    }

    private var filtered: [ActivityEvent] {
        guard !filter.isEmpty else { return store.activity }
        return store.activity.filter { $0.text.localizedCaseInsensitiveContains(filter) }
    }
}

enum PreviewStore {
    @MainActor static let context: ModelContext = {
        let schema = Schema([ShareRecord.self, DeviceRecord.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try! ModelContainer(for: schema, configurations: configuration)
        return container.mainContext
    }()
}
