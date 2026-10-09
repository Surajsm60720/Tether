import SwiftUI

/// Menu bar glyph is the infinity mark (same as the Dock icon), not the full square artwork.
struct MenuBarIconLabel: View {
    let accessibilityLabel: String

    var body: some View {
        Image(systemName: "infinity")
            .symbolRenderingMode(.hierarchical)
            .accessibilityLabel(accessibilityLabel)
    }
}
