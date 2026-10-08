import SwiftUI
import WidgetKit

@main
struct TetherWidgetsBundle: WidgetBundle {
    var body: some Widget {
        TransferLiveActivityWidget()
        AgentLiveActivityWidget()
    }
}
