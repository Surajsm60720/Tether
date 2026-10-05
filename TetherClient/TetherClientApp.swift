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
            RootView(store: store)
                .tint(Color.tether.accent)
        }
    }
}
