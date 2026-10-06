import SwiftData
import SwiftUI
import TetherCore
import UIKit

enum AppIconChoice: String, CaseIterable, Identifiable {
    case gold, blue, green, neutral

    nonisolated var id: String { rawValue }
    var title: String {
        switch self {
        case .gold: "Gold"
        case .blue: "Blue"
        case .green: "Green"
        case .neutral: "Neutral"
        }
    }

    /// `nil` is the primary gold icon. The other names match `CFBundleAlternateIcons`.
    var alternateName: String? {
        switch self {
        case .gold: nil
        case .blue: "Blue"
        case .green: "Green"
        case .neutral: "Neutral"
        }
    }

    @MainActor
    static var current: AppIconChoice {
        switch UIApplication.shared.alternateIconName {
        case "Blue": .blue
        case "Green": .green
        case "Neutral": .neutral
        default: .gold
        }
    }

    @MainActor
    func apply() async -> String? {
        guard UIApplication.shared.alternateIconName != alternateName else { return nil }
        do {
            try await UIApplication.shared.setAlternateIconName(alternateName)
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}

struct SettingsView: View {
    @Bindable var store: ClientStore
    @State private var confirmForget = false
    @State private var iconChoice = AppIconChoice.current
    @State private var iconError: String?
    @State private var remoteCode = ""
    @State private var remoteMessage: String?

    var body: some View {
        Form {
            Section {
                TextField("Device name", text: Binding(
                    get: { store.deviceName },
                    set: { store.setDeviceName($0) }
                ))
            }
            Section {
                Picker("Icon", selection: $iconChoice) {
                    ForEach(AppIconChoice.allCases) { choice in
                        Text(choice.title).tag(choice)
                    }
                }
            } footer: {
                Text("Light, Dark, and Tinted follow the Home Screen. Turn Tinted off in Settings, then Home Screen & App Library, if the icon should change between light and dark.")
            }
            Section("Cache") {
                LabeledContent("Size", value: Format.bytes(UInt64(max(store.cacheBytes, 0))))
                Button("Clear") { store.clearCache() }
            }
            Section("Terminal") {
                VStack(alignment: .leading) {
                    Text("Font size")
                    Slider(value: Binding(
                        get: { store.fontSize },
                        set: { store.setFontSize($0) }
                    ), in: 11...20, step: 1)
                }
            }
            Section {
                Button("Forget all Macs", role: .destructive) { confirmForget = true }
            }
            Section {
                if store.paired.isEmpty {
                    Text("Pair on Wi-Fi first. Then paste the code from the Mac.")
                        .foregroundStyle(.secondary)
                } else {
                    TextField("Setup code", text: $remoteCode, axis: .vertical)
                        .lineLimit(3...6)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("Save") {
                        remoteMessage = store.saveRemote(code: remoteCode)
                        if remoteMessage == nil { remoteCode = "" }
                    }
                    .disabled(remoteCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    ForEach(store.paired) { host in
                        if let summary = store.remoteSummary(for: host.id) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(host.name)
                                Text(summary)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Button("Remove", role: .destructive) { store.clearRemote(host.id) }
                            }
                        }
                    }
                    if let remoteMessage {
                        Text(remoteMessage)
                            .font(.footnote)
                            .foregroundStyle(Color.tether.danger)
                    }
                }
            } header: {
                Text("Other networks")
            } footer: {
                Text("Paste the code from the Mac’s Settings to open it when you are not on the same Wi-Fi. On the same Wi-Fi, Tether still connects directly.")
            }
            Section("About") {
                LabeledContent("Version", value: AppVersion.marketing)
                NavigationLink("What's new") {
                    ChangelogList()
                }
                Text("On the same Wi-Fi, files stay on your network. From another network, Tether uses the address or relay you paste here. A relay only carries encrypted traffic.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle(L10n.settings)
        .onAppear {
            if store.demoMode { store.setDemo(false) }
        }
        .onChange(of: iconChoice) { _, choice in
            Task { iconError = await choice.apply() }
        }
        .alert("Couldn't change the icon", isPresented: Binding(
            get: { iconError != nil },
            set: { if !$0 { iconError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(iconError ?? "")
        }
        .confirmationDialog("Forget all Macs?", isPresented: $confirmForget, titleVisibility: .visible) {
            Button("Forget all Macs", role: .destructive) { store.forgetAll() }
            Button("Cancel", role: .cancel) {}
        }
    }
}

struct ChangelogList: View {
    var body: some View {
        List {
            ForEach(AppChangelog.releases) { release in
                Section(release.version) {
                    ForEach(release.items, id: \.self) { item in
                        Text(item)
                    }
                }
            }
        }
        .navigationTitle("What's new")
        .navigationBarTitleDisplayMode(.inline)
    }
}

enum AppVersion {
    static var marketing: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? AppChangelog.current
    }
}

enum PreviewClient {
    @MainActor static let store: ClientStore = {
        let schema = Schema([PairedHostRecord.self, RecentRecord.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try! ModelContainer(for: schema, configurations: configuration)
        return ClientStore(context: container.mainContext, preview: true)
    }()
}
