#if canImport(ActivityKit) && os(iOS)
import ActivityKit
import Foundation

public struct TetherTransferAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable, Sendable {
        public var fileName: String
        public var isUpload: Bool
        public var fraction: Double
        public var bytesSent: UInt64
        public var bytesTotal: UInt64
        public var speedLabel: String
        public var etaLabel: String
        public var phase: TransferLivePhase
        public var batchCompleted: Int
        public var batchTotal: Int

        public init(from snapshot: TransferLiveSnapshot) {
            fileName = snapshot.fileName
            isUpload = snapshot.isUpload
            fraction = snapshot.fraction
            bytesSent = snapshot.bytesSent
            bytesTotal = snapshot.bytesTotal
            speedLabel = snapshot.speedLabel
            etaLabel = snapshot.etaLabel
            phase = snapshot.phase
            batchCompleted = snapshot.batchCompleted
            batchTotal = snapshot.batchTotal
        }

        private var asSnapshot: TransferLiveSnapshot {
            TransferLiveSnapshot(
                fileName: fileName,
                isUpload: isUpload,
                fraction: fraction,
                bytesSent: bytesSent,
                bytesTotal: bytesTotal,
                speedLabel: speedLabel,
                etaLabel: etaLabel,
                phase: phase,
                batchCompleted: batchCompleted,
                batchTotal: batchTotal
            )
        }

        public var percentLabel: String { asSnapshot.percentLabel }
        public var trailingCompact: String { asSnapshot.trailingCompact }
        public var batchLabel: String { asSnapshot.batchLabel }
    }

    public var hostName: String

    public init(hostName: String) {
        self.hostName = hostName
    }
}

public struct TetherAgentAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable, Sendable {
        /// Mirrors the live program — Activity attributes are fixed at request time.
        public var program: String
        public var displayName: String
        public var phase: AgentLivePhase
        /// Live chip from PTY scrape: Thinking / Working / Running / Editing / Waiting.
        public var statusLabel: String
        public var detail: String
        public var hostName: String
        /// Flipped when phase changes so Island content transitions fire.
        public var pulse: Bool
        /// Indexes CLI thinking frames (`AgentThinkingGlyph`); advanced by the client ticker.
        public var glyphFrame: Int

        public init(
            program: String,
            displayName: String,
            phase: AgentLivePhase,
            statusLabel: String,
            detail: String,
            hostName: String,
            pulse: Bool,
            glyphFrame: Int = 0
        ) {
            self.program = program
            self.displayName = displayName
            self.phase = phase
            self.statusLabel = statusLabel
            self.detail = detail
            self.hostName = hostName
            self.pulse = pulse
            self.glyphFrame = glyphFrame
        }
    }

    public var program: String

    public init(program: String) {
        self.program = program
    }
}
#endif
