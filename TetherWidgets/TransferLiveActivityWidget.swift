import ActivityKit
import SwiftUI
import TetherCore
import WidgetKit

struct TransferLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TetherTransferAttributes.self) { context in
            TransferLockScreenView(state: context.state, hostName: context.attributes.hostName)
                .widgetURL(TetherDeepLink.transfers)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    EmptyView()
                }
                DynamicIslandExpandedRegion(.center) {
                    // One row — side columns mis-align marks vs center text on Device Island.
                    HStack(alignment: .center, spacing: IslandExpandedRow.spacing) {
                        TransferDirectionBadge(
                            isUpload: context.state.isUpload,
                            size: IslandExpandedRow.markSize
                        )
                        TransferExpandedCenter(state: context.state)
                        Text(context.state.percentLabel)
                            .font(.system(size: 20, weight: .bold, design: .rounded).monospacedDigit())
                            .foregroundStyle(TetherLiveTheme.accent)
                            .contentTransition(.numericText())
                            .fixedSize()
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    EmptyView()
                }
            } compactLeading: {
                TransferDirectionBadge(isUpload: context.state.isUpload, size: 18)
            } compactTrailing: {
                Text(context.state.trailingCompact)
                    .font(.caption.monospacedDigit().weight(.bold))
                    .foregroundStyle(TetherLiveTheme.accent)
                    .contentTransition(.numericText())
                    .minimumScaleFactor(0.7)
                    .fixedSize()
            } minimal: {
                Text(context.state.percentLabel)
                    .font(.caption2.monospacedDigit().weight(.bold))
                    .foregroundStyle(TetherLiveTheme.accent)
                    .minimumScaleFactor(0.7)
                    .fixedSize()
            }
            .widgetURL(TetherDeepLink.transfers)
            .keylineTint(TetherLiveTheme.accent)
        }
    }
}

struct TransferExpandedCenter: View {
    var state: TetherTransferAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(TetherLiveTheme.shortFileName(state.fileName, limit: 22))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(TetherLiveTheme.label)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                if !state.batchLabel.isEmpty {
                    Text(state.batchLabel)
                        .font(.system(size: 10, weight: .bold, design: .rounded).monospacedDigit())
                        .foregroundStyle(TetherLiveTheme.accent)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(TetherLiveTheme.accent.opacity(0.16)))
                }
            }
            Text("\(FormatBytes.string(state.bytesSent)) / \(FormatBytes.string(state.bytesTotal))")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(TetherLiveTheme.secondary)
            TransferProgressBar(fraction: state.fraction, phase: state.phase)
                .padding(.top, 1)
            if !status.isEmpty {
                Text(status)
                    .font(.caption2.monospacedDigit().weight(.medium))
                    .foregroundStyle(TetherLiveTheme.tertiary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var status: String {
        switch state.phase {
        case .active:
            var parts: [String] = []
            if !state.speedLabel.isEmpty { parts.append(state.speedLabel) }
            if !state.etaLabel.isEmpty { parts.append(state.etaLabel) }
            return parts.joined(separator: " · ")
        case .paused: return "Paused — reopen Tether"
        case .completed: return "Complete"
        case .failed: return "Couldn't finish"
        }
    }
}

struct TransferDirectionBadge: View {
    var isUpload: Bool
    var size: CGFloat

    var body: some View {
        ZStack {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [TetherLiveTheme.accent.opacity(0.35), TetherLiveTheme.accentDeep.opacity(0.2)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            Circle()
                .strokeBorder(TetherLiveTheme.accent.opacity(0.55), lineWidth: 1)
            Image(systemName: isUpload ? "arrow.up" : "arrow.down")
                .font(.system(size: size * 0.4, weight: .bold))
                .foregroundStyle(TetherLiveTheme.accent)
        }
        .frame(width: size, height: size)
    }
}

struct TransferProgressBar: View {
    var fraction: Double
    var phase: TransferLivePhase

    var body: some View {
        GeometryReader { geo in
            let fill = max(0, min(1, fraction))
            ZStack(alignment: .leading) {
                Capsule().fill(TetherLiveTheme.track)
                Capsule()
                    .fill(barColor)
                    .frame(width: max(geo.size.width * fill, fill > 0 ? 8 : 0))
            }
        }
        .frame(height: 6)
    }

    private var barColor: Color {
        switch phase {
        case .completed: TetherLiveTheme.success
        case .failed: TetherLiveTheme.danger
        case .paused: TetherLiveTheme.warning
        case .active: TetherLiveTheme.accent
        }
    }
}

enum FormatBytes {
    static func string(_ value: UInt64) -> String {
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

struct TransferLockScreenView: View {
    var state: TetherTransferAttributes.ContentState
    var hostName: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                TransferDirectionBadge(isUpload: state.isUpload, size: 38)
                VStack(alignment: .leading, spacing: 2) {
                    Text(state.fileName)
                        .font(.headline)
                        .foregroundStyle(TetherLiveTheme.label)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    HStack(spacing: 6) {
                        Text(hostName.isEmpty ? "Tether" : hostName)
                            .font(.caption)
                            .foregroundStyle(TetherLiveTheme.secondary)
                            .lineLimit(1)
                        if !state.batchLabel.isEmpty {
                            Text("·")
                                .foregroundStyle(TetherLiveTheme.tertiary)
                            Text(state.batchLabel)
                                .font(.caption.monospacedDigit().weight(.semibold))
                                .foregroundStyle(TetherLiveTheme.accent)
                        }
                    }
                }
                Spacer(minLength: 8)
                Text(state.percentLabel)
                    .font(.title2.monospacedDigit().weight(.bold))
                    .foregroundStyle(TetherLiveTheme.accent)
                    .contentTransition(.numericText())
                    .fixedSize()
            }
            TransferProgressBar(fraction: state.fraction, phase: state.phase)
            Text(lockDetail)
                .font(.caption.monospacedDigit().weight(.medium))
                .foregroundStyle(TetherLiveTheme.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .activityBackgroundTint(Color.black.opacity(0.55))
        .activitySystemActionForegroundColor(TetherLiveTheme.accent)
    }

    private var lockDetail: String {
        switch state.phase {
        case .active:
            var parts = [
                "\(FormatBytes.string(state.bytesSent)) / \(FormatBytes.string(state.bytesTotal))"
            ]
            if !state.speedLabel.isEmpty { parts.append(state.speedLabel) }
            if !state.etaLabel.isEmpty { parts.append(state.etaLabel) }
            return parts.joined(separator: " · ")
        case .paused: return "Paused — reopen Tether to finish"
        case .completed: return "Transfer complete"
        case .failed: return "Couldn't finish — reopen Tether"
        }
    }
}
