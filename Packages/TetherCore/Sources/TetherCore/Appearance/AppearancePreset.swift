import Foundation

/// Linear sRGB components in 0…1. UI layers convert to `Color` / `UIColor`.
public struct ThemeRGBA: Sendable, Equatable, Hashable, Codable {
    public var r: Double
    public var g: Double
    public var b: Double
    public var a: Double

    public init(r: Double, g: Double, b: Double, a: Double = 1) {
        self.r = r
        self.g = g
        self.b = b
        self.a = a
    }

    /// Parse `#RRGGBB` or `#RRGGBBAA`.
    public init?(hex: String) {
        var raw = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.hasPrefix("#") { raw.removeFirst() }
        guard raw.count == 6 || raw.count == 8, let value = UInt64(raw, radix: 16) else { return nil }
        if raw.count == 6 {
            r = Double((value >> 16) & 0xFF) / 255
            g = Double((value >> 8) & 0xFF) / 255
            b = Double(value & 0xFF) / 255
            a = 1
        } else {
            r = Double((value >> 24) & 0xFF) / 255
            g = Double((value >> 16) & 0xFF) / 255
            b = Double((value >> 8) & 0xFF) / 255
            a = Double(value & 0xFF) / 255
        }
    }
}

/// Optional terminal chrome tint for a preset (GUI themes can leave this nil).
public struct TerminalPaletteTokens: Sendable, Equatable, Hashable, Codable {
    public var bg: ThemeRGBA
    public var fg: ThemeRGBA
    public var dim: ThemeRGBA
    public var prompt: ThemeRGBA
    public var dir: ThemeRGBA
    public var file: ThemeRGBA
    public var exec: ThemeRGBA
    public var error: ThemeRGBA

    public init(
        bg: ThemeRGBA,
        fg: ThemeRGBA,
        dim: ThemeRGBA,
        prompt: ThemeRGBA,
        dir: ThemeRGBA,
        file: ThemeRGBA,
        exec: ThemeRGBA,
        error: ThemeRGBA
    ) {
        self.bg = bg
        self.fg = fg
        self.dim = dim
        self.prompt = prompt
        self.dir = dir
        self.file = file
        self.exec = exec
        self.error = error
    }
}

public struct AppearancePreset: Sendable, Equatable, Identifiable, Hashable {
    public var id: String
    public var name: String
    public var accent: ThemeRGBA
    public var accentText: ThemeRGBA
    public var success: ThemeRGBA
    public var warning: ThemeRGBA
    public var danger: ThemeRGBA
    public var terminal: TerminalPaletteTokens?

    public init(
        id: String,
        name: String,
        accent: ThemeRGBA,
        accentText: ThemeRGBA,
        success: ThemeRGBA,
        warning: ThemeRGBA,
        danger: ThemeRGBA,
        terminal: TerminalPaletteTokens? = nil
    ) {
        self.id = id
        self.name = name
        self.accent = accent
        self.accentText = accentText
        self.success = success
        self.warning = warning
        self.danger = danger
        self.terminal = terminal
    }
}

public enum AppearancePresets: Sendable {
    public static let defaultID = "gold"

    public static let all: [AppearancePreset] = [gold, blue, green, neutral, midnight]

    public static func resolve(_ id: String) -> AppearancePreset {
        all.first(where: { $0.id == id }) ?? gold
    }

    public static let gold = AppearancePreset(
        id: "gold",
        name: "Gold",
        accent: ThemeRGBA(hex: "#E8B04A")!,
        accentText: ThemeRGBA(hex: "#C98A1B")!,
        success: ThemeRGBA(hex: "#4CC38A")!,
        warning: ThemeRGBA(hex: "#F0A84A")!,
        danger: ThemeRGBA(hex: "#FF6B6B")!,
        terminal: Self.defaultTerminal(prompt: ThemeRGBA(hex: "#E8B04A")!)
    )

    public static let blue = AppearancePreset(
        id: "blue",
        name: "Blue",
        accent: ThemeRGBA(hex: "#5B9DFF")!,
        accentText: ThemeRGBA(hex: "#2F6FED")!,
        success: ThemeRGBA(hex: "#4CC38A")!,
        warning: ThemeRGBA(hex: "#F0A84A")!,
        danger: ThemeRGBA(hex: "#FF6B6B")!,
        terminal: Self.defaultTerminal(prompt: ThemeRGBA(hex: "#6CB6FF")!)
    )

    public static let green = AppearancePreset(
        id: "green",
        name: "Green",
        accent: ThemeRGBA(hex: "#3DCF8E")!,
        accentText: ThemeRGBA(hex: "#1F8A4C")!,
        success: ThemeRGBA(hex: "#4CC38A")!,
        warning: ThemeRGBA(hex: "#F0A84A")!,
        danger: ThemeRGBA(hex: "#FF6B6B")!,
        terminal: Self.defaultTerminal(prompt: ThemeRGBA(hex: "#7EE787")!)
    )

    public static let neutral = AppearancePreset(
        id: "neutral",
        name: "Neutral",
        // Bright cool gray for list tints (host names, file rows, toolbar). System
        // `#8E8E93` reads as “disabled”; this stays clearly interactive on dark UI.
        // Prominent buttons use a separate darker fill (see client `SendAccent`).
        accent: ThemeRGBA(hex: "#E5E5EA")!,
        accentText: ThemeRGBA(hex: "#FFFFFF")!,
        success: ThemeRGBA(hex: "#4CC38A")!,
        warning: ThemeRGBA(hex: "#F0A84A")!,
        danger: ThemeRGBA(hex: "#FF6B6B")!,
        terminal: TerminalPaletteTokens(
            bg: ThemeRGBA(hex: "#121417")!,
            fg: ThemeRGBA(hex: "#F5F5F7")!,
            dim: ThemeRGBA(hex: "#8E8E93")!,
            prompt: ThemeRGBA(hex: "#E5E5EA")!,
            dir: ThemeRGBA(hex: "#F5F5F7")!,
            file: ThemeRGBA(hex: "#F5F5F7")!,
            exec: ThemeRGBA(hex: "#7EE787")!,
            error: ThemeRGBA(hex: "#FF7B72")!
        )
    )

    /// Dark enough for white labels on `.borderedProminent` when Neutral’s accent is light.
    public static let neutralProminentFill = ThemeRGBA(hex: "#636366")!

    public static let midnight = AppearancePreset(
        id: "midnight",
        name: "Midnight",
        accent: ThemeRGBA(hex: "#E8B04A")!,
        accentText: ThemeRGBA(hex: "#F2C970")!,
        success: ThemeRGBA(hex: "#4CC38A")!,
        warning: ThemeRGBA(hex: "#F0A84A")!,
        danger: ThemeRGBA(hex: "#FF6B6B")!,
        terminal: TerminalPaletteTokens(
            bg: ThemeRGBA(hex: "#0B0D10")!,
            fg: ThemeRGBA(hex: "#E6E1D6")!,
            dim: ThemeRGBA(hex: "#7D8590")!,
            prompt: ThemeRGBA(hex: "#E8B04A")!,
            dir: ThemeRGBA(hex: "#6CB6FF")!,
            file: ThemeRGBA(hex: "#E6E1D6")!,
            exec: ThemeRGBA(hex: "#7EE787")!,
            error: ThemeRGBA(hex: "#FF7B72")!
        )
    )

    private static func defaultTerminal(prompt: ThemeRGBA) -> TerminalPaletteTokens {
        TerminalPaletteTokens(
            bg: ThemeRGBA(hex: "#121417")!,
            fg: ThemeRGBA(hex: "#E6E1D6")!,
            dim: ThemeRGBA(hex: "#7D8590")!,
            prompt: prompt,
            dir: ThemeRGBA(hex: "#6CB6FF")!,
            file: ThemeRGBA(hex: "#E6E1D6")!,
            exec: ThemeRGBA(hex: "#7EE787")!,
            error: ThemeRGBA(hex: "#FF7B72")!
        )
    }
}

public enum GuiFontWeight: String, CaseIterable, Sendable, Codable, Identifiable {
    case regular
    case medium
    case semibold

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .regular: "Regular"
        case .medium: "Medium"
        case .semibold: "Semibold"
        }
    }
}
