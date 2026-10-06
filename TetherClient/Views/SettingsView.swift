import SwiftData
import SwiftUI
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
                Toggle(L10n.demo, isOn: Binding(
                    get: { store.demoMode },
                    set: { store.setDemo($0) }
                ))
            } footer: {
                Text("Demo mode shows sample files without a Mac, so you can look around when Wi-Fi blocks device-to-device traffic.")
            }
            Section {
                Button("Forget all Macs", role: .destructive) { confirmForget = true }
            }
            Section("About") {
                LabeledContent("Version", value: "0.1")
                Text("Tether stays on your Wi-Fi. Files are not uploaded to the internet.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle(L10n.settings)
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

enum PreviewClient {
    @MainActor static let store: ClientStore = {
        let schema = Schema([PairedHostRecord.self, RecentRecord.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try! ModelContainer(for: schema, configurations: configuration)
        return ClientStore(context: container.mainContext, preview: true)
    }()
}
