import Foundation

#if os(macOS)
import IOKit.ps

/// Whether this Mac is on wall power (AC / UPS) vs battery-only.
public enum MacPowerSource: Sendable {
    /// `true` when IOKit reports AC/UPS, or when power-source info is unavailable (desktop / unknown).
    public static func isExternallyPowered() -> Bool {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return true }
        if let type = IOPSGetProvidingPowerSourceType(snapshot)?.takeRetainedValue() as String? {
            return type != kIOPSBatteryPowerValue
        }
        return true
    }
}
#endif
