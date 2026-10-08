import SwiftUI

/// Expanded Dynamic Island side columns don’t share the center stack’s vertical metrics.
/// Prefer a single full-width row in `.center` so leading mark + text (+ trailing) stay level.
enum IslandExpandedRow {
    static let spacing: CGFloat = 12
    static let markSize: CGFloat = 34
}
