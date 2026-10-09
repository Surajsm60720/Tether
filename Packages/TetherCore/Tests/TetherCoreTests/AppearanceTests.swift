import Foundation
import Testing
@testable import TetherCore

@Test func appearancePresetsIncludeGoldDefault() {
    #expect(AppearancePresets.defaultID == "gold")
    #expect(AppearancePresets.all.count == 5)
    #expect(AppearancePresets.all.map(\.id) == ["gold", "blue", "green", "neutral", "midnight"])
    #expect(AppearancePresets.resolve("gold").name == "Gold")
}

@Test func appearanceNeutralAccentIsNotNearWhite() {
    let accent = AppearancePresets.neutral.accent
    let luminance = 0.2126 * accent.r + 0.7152 * accent.g + 0.0722 * accent.b
    #expect(luminance < 0.75)
}

@Test func appearanceResolveUnknownFallsBackToGold() {
    let preset = AppearancePresets.resolve("not-a-real-theme")
    #expect(preset.id == "gold")
    #expect(preset.name == "Gold")
}

@Test func themeRGBAHexRoundTripBasics() {
    let gold = ThemeRGBA(hex: "#E8B04A")
    #expect(gold != nil)
    #expect(abs((gold?.r ?? 0) - 232.0 / 255.0) < 0.001)
    #expect(ThemeRGBA(hex: "nope") == nil)
    #expect(ThemeRGBA(hex: "#11223344")?.a ?? 0 > 0.2)
}

@Test @MainActor
func appearancePreferencesPersistAndClamp() {
    let suiteName = "test.tether.appearance.\(UUID().uuidString)"
    let suite = UserDefaults(suiteName: suiteName)!
    defer { suite.removePersistentDomain(forName: suiteName) }

    let prefs = AppearancePreferences(defaults: suite)
    #expect(prefs.presetID == "gold")
    #expect(prefs.guiFontSize == AppearancePreferences.defaultGUIFontSize)
    #expect(prefs.guiFontWeight == .regular)

    prefs.setPresetID("midnight")
    prefs.setGUIFontSize(99)
    prefs.setGUIFontWeight(.semibold)
    #expect(prefs.presetID == "midnight")
    #expect(prefs.guiFontSize == AppearancePreferences.maxGUIFontSize)
    #expect(prefs.guiFontWeight == .semibold)

    prefs.setPresetID("garbage")
    #expect(prefs.presetID == "gold")

    let reloaded = AppearancePreferences(defaults: suite)
    #expect(reloaded.presetID == "gold")
    #expect(reloaded.guiFontSize == AppearancePreferences.maxGUIFontSize)
    #expect(reloaded.guiFontWeight == .semibold)
}
