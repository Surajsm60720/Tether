import SwiftUI
import TetherCore

/// Observes appearance prefs so accent / type tokens refresh without remounting windows awkwardly.
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
            // Fonts and Color.tether are read outside Observation tracking in helpers;
            // bump identity when prefs change so the tree picks up new tokens.
            .id(appearanceIdentity)
    }

    private var appearanceIdentity: String {
        "\(appearance.presetID)-\(Int(appearance.guiFontSize))-\(appearance.guiFontWeight.rawValue)"
    }
}
