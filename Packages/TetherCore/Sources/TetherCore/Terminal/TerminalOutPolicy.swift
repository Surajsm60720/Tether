import Foundation

/// Wire-side batching for live PTY `term.data` events.
///
/// Concatenates consecutive chunks into fewer encrypted frames so Wi-Fi sees
/// larger packets instead of a flood of tiny ones. Bytes are never dropped —
/// VT state on the phone stays correct.
public enum TerminalOutPolicy: Sendable {
    /// Brief pause so a keystroke echo can merge with an immediate follow-up.
    public static let interactiveHoldMs = 8
    /// Longer gather window while an agent is redrawing heavily.
    public static let streamingHoldMs = 56
    /// Recent flush within this window means we are in streaming mode.
    public static let streamingThresholdMs = 70
    /// Skip the hold once a soft amount of bytes is already waiting.
    public static let softCapBytes = 24 * 1024
    /// Largest single `term.data` body taken from the mailbox.
    public static let hardCapBytes = 48 * 1024

    /// How long to wait before sending, given pending size and recency of the last flush.
    public static func holdMilliseconds(pendingBytes: Int, msSinceLastFlush: Int?) -> Int {
        guard pendingBytes > 0 else { return 0 }
        if pendingBytes >= softCapBytes { return 0 }
        if let ago = msSinceLastFlush, ago < streamingThresholdMs {
            return streamingHoldMs
        }
        return interactiveHoldMs
    }

    /// Bytes to take for one wire frame from a pending buffer.
    public static func takeCount(pendingBytes: Int) -> Int {
        min(max(0, pendingBytes), hardCapBytes)
    }
}
