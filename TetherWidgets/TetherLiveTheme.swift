import SwiftUI

/// Live Activity palette mirrored from the app Theme (gold accent on charcoal).
/// Explicit colors — Dynamic Island ignores asset AccentColor for many system tints.
enum TetherLiveTheme {
    /// Dark-mode accent gold (`#E8B04A`).
    static let accent = Color(red: 0.910, green: 0.690, blue: 0.290)
    /// Deeper gold for fills (`#C98A1B`).
    static let accentDeep = Color(red: 0.788, green: 0.541, blue: 0.106)
    static let success = Color(red: 0.298, green: 0.765, blue: 0.541)
    static let warning = Color(red: 0.941, green: 0.659, blue: 0.290)
    static let danger = Color(red: 1.0, green: 0.420, blue: 0.420)

    static let label = Color.white
    static let secondary = Color.white.opacity(0.72)
    static let tertiary = Color.white.opacity(0.55)
    static let track = Color.white.opacity(0.14)
    static let badgeFill = Color.white.opacity(0.10)

    /// Claude Code terracotta spinner (`#D4783C` approx).
    static let claudeTerracotta = Color(red: 0.831, green: 0.471, blue: 0.235)
    /// Gemini Braille accent (brand blue-leaning).
    static let geminiBlue = Color(red: 0.482, green: 0.667, blue: 0.969)

    /// Island-friendly filename: keep a short head + rich tail (resolution/ext).
    static func shortFileName(_ name: String, limit: Int = 28) -> String {
        guard name.count > limit else { return name }
        let ns = name as NSString
        let ext = ns.pathExtension
        let stem = ext.isEmpty ? name : ns.deletingPathExtension
        if stem.count <= 6 {
            return String(name.prefix(limit - 1)) + "…"
        }
        let ellipsisAndExt = ext.isEmpty ? 1 : ext.count + 2
        let budget = max(8, limit - ellipsisAndExt)
        let head = max(5, budget / 3)
        let tail = max(8, budget - head)
        let start = stem.prefix(head)
        let end = stem.suffix(tail)
        if ext.isEmpty { return "\(start)…\(end)" }
        return "\(start)…\(end).\(ext)"
    }
}
