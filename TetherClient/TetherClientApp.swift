import SwiftData
import SwiftUI

@main
struct TetherClientApp: App {
    private let container: ModelContainer
    @State private var store: ClientStore

    init() {
        let schema = Schema([PairedHostRecord.self, RecentRecord.self])
        let stored = ModelConfiguration(schema: schema)
        let container = (try? ModelContainer(for: schema, configurations: stored)) ?? {
            let memory = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
            return try! ModelContainer(for: schema, configurations: memory)
        }()
        self.container = container
        _store = State(initialValue: ClientStore(context: container.mainContext))
    }

    var body: some Scene {
        WindowGroup {
            AppearanceChrome {
                RootView(store: store)
                    .onOpenURL { store.openDeepLink($0) }
                    .task {
                        await store.processPendingShareInbox()
                    }
                    .onChange(of: store.connected) { _, connected in
                        if connected {
                            Task { await store.processPendingShareInbox() }
                        }
                    }
            }
        }
    }
}
