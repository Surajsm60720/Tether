import SwiftData
import SwiftUI

@main
struct TetherHostApp: App {
    private let container: ModelContainer
    @State private var store: HostStore

    init() {
        let schema = Schema([ShareRecord.self, DeviceRecord.self])
        let container = (try? ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema)))
            ?? {
                let memory = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
                return try! ModelContainer(for: schema, configurations: memory)
            }()
        self.container = container
        _store = State(initialValue: HostStore(context: container.mainContext))
    }

    var body: some Scene {
        WindowGroup(id: "main") {
            HostWindow(store: store)
        }
        .defaultSize(width: 920, height: 600)

        MenuBarExtra {
            MenuBarRoot(store: store)
        } label: {
            Image(systemName: "macbook.and.iphone")
                .accessibilityLabel(store.statusLabel)
        }
        .menuBarExtraStyle(.window)

        Window("Pair new iPhone", id: "pair") {
            PairingWindow(store: store)
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 420, height: 520)

        Window("Welcome to Tether", id: "welcome") {
            WelcomeView(store: store)
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 420, height: 280)

        Settings {
            SettingsView(store: store)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button(L10n.pair) {
                    store.beginPairing()
                }
                .keyboardShortcut("n")
            }
        }
    }
}
