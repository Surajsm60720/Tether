import SwiftUI
import TetherCore

extension Color {
    init(_ rgba: ThemeRGBA) {
        self.init(.sRGB, red: rgba.r, green: rgba.g, blue: rgba.b, opacity: rgba.a)
    }

    /// Live palette from `AppearancePreferences`. Asset-catalog colors remain the Gold fallback.
    @MainActor
    static var tether: TetherColors { TetherColors() }
}

@MainActor
struct TetherColors {
    private var preset: AppearancePreset { AppearancePreferences.shared.preset }

    var accent: Color { Color(preset.accent) }
    var accentText: Color { Color(preset.accentText) }
    var success: Color { Color(preset.success) }
    var warning: Color { Color(preset.warning) }
    var danger: Color { Color(preset.danger) }
}

@MainActor
struct TerminalTheme {
    private var tokens: TerminalPaletteTokens {
        AppearancePreferences.shared.preset.terminal
            ?? AppearancePresets.gold.terminal!
    }

    var bg: Color { Color(tokens.bg) }
    var fg: Color { Color(tokens.fg) }
    var dim: Color { Color(tokens.dim) }
    var prompt: Color { Color(tokens.prompt) }
    var dir: Color { Color(tokens.dir) }
    var file: Color { Color(tokens.file) }
    var exec: Color { Color(tokens.exec) }
    var error: Color { Color(tokens.error) }

    static var standard: TerminalTheme { TerminalTheme() }
}

/// GUI text styles follow AppearancePreferences size/weight. Terminal keeps its own size slider.
@MainActor
enum TetherType {
    private static var size: CGFloat { CGFloat(AppearancePreferences.shared.guiFontSize) }
    private static var weight: Font.Weight {
        switch AppearancePreferences.shared.guiFontWeight {
        case .regular: .regular
        case .medium: .medium
        case .semibold: .semibold
        }
    }

    static var hero: Font { .system(size: size + 10, weight: weight) }
    static var title: Font { .system(size: size + 4, weight: weight) }
    static var section: Font { .system(size: size, weight: weight == .regular ? .semibold : weight) }
    static var body: Font { .system(size: size, weight: weight) }
    static var secondary: Font { .system(size: size - 1, weight: weight) }
    static var meta: Font { .system(size: size - 3, weight: weight) }
    static var footnote: Font { .system(size: size - 4, weight: weight) }
    static var code: Font { .system(size: size + 2, weight: weight, design: .monospaced) }
}

enum TetherMotion {
    /// Short spring for a state change. Reduced motion becomes a short fade.
    static func spring(_ reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeOut(duration: 0.2) : .spring(duration: 0.35, bounce: 0.15)
    }

    static func fade(_ reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeOut(duration: 0.12) : .spring(duration: 0.28, bounce: 0)
    }
}
