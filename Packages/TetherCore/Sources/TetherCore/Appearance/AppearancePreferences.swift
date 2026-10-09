import Foundation
import Observation

/// Persisted appearance choices shared by Mac Host and iOS Client (local UserDefaults only).
@Observable
@MainActor
public final class AppearancePreferences {
    public static let shared = AppearancePreferences()

    public static let presetIDKey = "appearance.presetID"
    public static let guiFontSizeKey = "appearance.guiFontSize"
    public static let guiFontWeightKey = "appearance.guiFontWeight"

    public static let minGUIFontSize: Double = 13
    public static let maxGUIFontSize: Double = 20
    public static let defaultGUIFontSize: Double = 15

    public private(set) var presetID: String
    public private(set) var guiFontSize: Double
    public private(set) var guiFontWeight: GuiFontWeight

    private let defaults: UserDefaults

    public var preset: AppearancePreset {
        AppearancePresets.resolve(presetID)
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let storedID = defaults.string(forKey: Self.presetIDKey) ?? AppearancePresets.defaultID
        self.presetID = AppearancePresets.resolve(storedID).id
        let size = defaults.object(forKey: Self.guiFontSizeKey) as? Double ?? Self.defaultGUIFontSize
        self.guiFontSize = Self.clampedFontSize(size)
        if let raw = defaults.string(forKey: Self.guiFontWeightKey),
           let weight = GuiFontWeight(rawValue: raw) {
            self.guiFontWeight = weight
        } else {
            self.guiFontWeight = .regular
        }
    }

    public func setPresetID(_ id: String) {
        let resolved = AppearancePresets.resolve(id).id
        guard resolved != presetID else { return }
        presetID = resolved
        defaults.set(resolved, forKey: Self.presetIDKey)
    }

    public func setGUIFontSize(_ size: Double) {
        let clamped = Self.clampedFontSize(size)
        guard clamped != guiFontSize else { return }
        guiFontSize = clamped
        defaults.set(clamped, forKey: Self.guiFontSizeKey)
    }

    public func setGUIFontWeight(_ weight: GuiFontWeight) {
        guard weight != guiFontWeight else { return }
        guiFontWeight = weight
        defaults.set(weight.rawValue, forKey: Self.guiFontWeightKey)
    }

    public static func clampedFontSize(_ size: Double) -> Double {
        min(max(size.rounded(), minGUIFontSize), maxGUIFontSize)
    }
}
