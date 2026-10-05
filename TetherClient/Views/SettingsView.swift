import SwiftData
import SwiftUI

struct SettingsView: View {
    @Bindable var store: ClientStore
    @State private var confirmForget = false

    var body: some View {
        Form {
            Section {
                TextField("Device name", text: Binding(
                    get: { store.deviceName },
                    set: { store.setDeviceName($0) }
                ))
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
