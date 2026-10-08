import Foundation

/// Aggregate view of active transfers for a Live Activity (≤4 KB payload friendly).
public struct TransferLiveSnapshot: Equatable, Sendable {
    public var fileName: String
    public var isUpload: Bool
    public var fraction: Double
    public var bytesSent: UInt64
    public var bytesTotal: UInt64
    public var speedLabel: String
    public var etaLabel: String
    public var phase: TransferLivePhase
    /// How many files in the batch have finished successfully.
    public var batchCompleted: Int
    /// Active + completed files in the current batch.
    public var batchTotal: Int

    public init(
        fileName: String,
        isUpload: Bool,
        fraction: Double,
        bytesSent: UInt64,
        bytesTotal: UInt64,
        speedLabel: String,
        etaLabel: String,
        phase: TransferLivePhase,
        batchCompleted: Int,
        batchTotal: Int
    ) {
        self.fileName = fileName
        self.isUpload = isUpload
        self.fraction = fraction
        self.bytesSent = bytesSent
        self.bytesTotal = bytesTotal
        self.speedLabel = speedLabel
        self.etaLabel = etaLabel
        self.phase = phase
        self.batchCompleted = batchCompleted
        self.batchTotal = max(batchTotal, 1)
    }

    public var percentLabel: String {
        "\(Int((fraction * 100).rounded()))%"
    }

    /// Small Island copy: `2 of 5`. Empty when the batch is a single file.
    public var batchLabel: String {
        guard batchTotal > 1 else { return "" }
        return "\(batchCompleted) of \(batchTotal)"
    }

    public var trailingCompact: String {
        if batchTotal > 1 {
            return "\(percentLabel) · \(batchCompleted)/\(batchTotal)"
        }
        return percentLabel
    }
}

public enum TransferLivePhase: String, Codable, Sendable, CaseIterable {
    case active
    case paused
    case completed
    case failed
}

public enum TransferLiveSnapshotBuilder {
    public struct Input: Equatable, Sendable {
        public var name: String
        public var isUpload: Bool
        public var sent: UInt64
        public var total: UInt64
        public var started: Date
        public var state: TransferLivePhase

        public init(
            name: String,
            isUpload: Bool,
            sent: UInt64,
            total: UInt64,
            started: Date,
            state: TransferLivePhase
        ) {
            self.name = name
            self.isUpload = isUpload
            self.sent = sent
            self.total = total
            self.started = started
            self.state = state
        }

        public var fraction: Double {
            guard total > 0 else { return 0 }
            return min(1, Double(sent) / Double(total))
        }
    }

    /// Prefer the largest remaining active transfer; fall back to most recent terminal state.
    public static func build(
        active: [Input],
        completedCount: Int,
        finishedPrimary: Input?,
        now: Date = Date()
    ) -> TransferLiveSnapshot? {
        let batchCompleted = max(0, completedCount)
        let batchTotal = max(1, active.count + batchCompleted)

        if let primary = active.max(by: { left, right in
            let leftLeft = left.total > left.sent ? left.total - left.sent : 0
            let rightLeft = right.total > right.sent ? right.total - right.sent : 0
            if leftLeft != rightLeft { return leftLeft < rightLeft }
            return left.total < right.total
        }) {
            return snapshot(
                from: primary,
                batchCompleted: batchCompleted,
                batchTotal: batchTotal,
                now: now
            )
        }
        guard let finishedPrimary else { return nil }
        return snapshot(
            from: finishedPrimary,
            batchCompleted: max(batchCompleted, 1),
            batchTotal: max(batchTotal, batchCompleted),
            now: now
        )
    }

    public static func speedLabel(bytes: UInt64, since: Date, now: Date) -> String {
        let seconds = max(now.timeIntervalSince(since), 0.1)
        let perSecond = Double(bytes) / seconds
        return byteRate(UInt64(perSecond)) + "/s"
    }

    public static func etaLabel(sent: UInt64, total: UInt64, since: Date, now: Date) -> String {
        let elapsed = max(now.timeIntervalSince(since), 0.1)
        let rate = Double(sent) / elapsed
        guard rate > 1, total > sent else { return "" }
        let left = Int((Double(total - sent) / rate).rounded())
        if left < 60 { return "\(left)s left" }
        return "\(left / 60)m \(left % 60)s left"
    }

    private static func snapshot(
        from input: Input,
        batchCompleted: Int,
        batchTotal: Int,
        now: Date
    ) -> TransferLiveSnapshot {
        TransferLiveSnapshot(
            fileName: input.name,
            isUpload: input.isUpload,
            fraction: input.fraction,
            bytesSent: input.sent,
            bytesTotal: input.total,
            speedLabel: input.state == .active ? speedLabel(bytes: input.sent, since: input.started, now: now) : "",
            etaLabel: input.state == .active ? etaLabel(sent: input.sent, total: input.total, since: input.started, now: now) : "",
            phase: input.state,
            batchCompleted: batchCompleted,
            batchTotal: batchTotal
        )
    }

    private static func byteRate(_ value: UInt64) -> String {
        let units = ["B", "KB", "MB", "GB"]
        var size = Double(value)
        var index = 0
        while size >= 1024, index < units.count - 1 {
            size /= 1024
            index += 1
        }
        if index == 0 { return "\(Int(size)) \(units[index])" }
        return String(format: "%.1f \(units[index])", size)
    }
}

public enum TetherDeepLink {
    public static let scheme = "tether"
    public static let transfers = URL(string: "tether://transfers")!
    public static let terminal = URL(string: "tether://terminal")!
}
