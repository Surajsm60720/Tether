import SwiftUI
import TetherCore

/// Observes appearance prefs so accent / type tokens refresh across the iOS client.
struct AppearanceChrome<Content: View>: View {
    @Bindable private var appearance = AppearancePreferences.shared
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .environment(appearance)
            .tint(Color(appearance.preset.accent))
            .id(appearanceIdentity)
    }

    private var appearanceIdentity: String {
        "\(appearance.presetID)-\(Int(appearance.guiFontSize))-\(appearance.guiFontWeight.rawValue)"
    }
}
