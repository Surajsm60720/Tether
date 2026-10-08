import ActivityKit
import SwiftUI
import TetherCore
import WidgetKit

struct AgentLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TetherAgentAttributes.self) { context in
            AgentLockScreenView(program: liveProgram(context), state: context.state)
                .widgetURL(TetherDeepLink.terminal)
        } dynamicIsland: { context in
            let program = liveProgram(context)
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    EmptyView()
                }
                DynamicIslandExpandedRegion(.center) {
                    HStack(alignment: .center, spacing: IslandExpandedRow.spacing) {
                        AgentLeadingMark(
                            program: program,
                            phase: context.state.phase,
                            pulse: context.state.pulse,
                            glyphFrame: context.state.glyphFrame,
                            size: IslandExpandedRow.markSize,
                            emphasize: true
                        )
                        VStack(alignment: .leading, spacing: 4) {
                            Text(context.state.displayName)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(TetherLiveTheme.label)
                                .lineLimit(1)
                            Text(context.state.detail)
                                .font(thinkingMono(program, context.state.phase) ? .caption.monospaced() : .caption)
                                .fontWeight(thinkingMono(program, context.state.phase) ? .bold : .regular)
                                .foregroundStyle(TetherLiveTheme.secondary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.85)
                                .contentTransition(.opacity)
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(liveDotColor(context.state.phase))
                                    .frame(width: 6, height: 6)
                                Text(context.state.statusLabel)
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(statusColor(context.state.phase))
                                    .contentTransition(.opacity)
                            }
                            .padding(.top, 1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    EmptyView()
                }
            } compactLeading: {
                AgentLeadingMark(
                    program: program,
                    phase: context.state.phase,
                    pulse: context.state.pulse,
                    glyphFrame: context.state.glyphFrame,
                    size: 20
                )
            } compactTrailing: {
                Text(context.state.statusLabel)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(
                        context.state.phase == .waiting ? TetherLiveTheme.warning : TetherLiveTheme.accent
                    )
                    .minimumScaleFactor(0.7)
                    .lineLimit(1)
                    .fixedSize()
            } minimal: {
                AgentLeadingMark(
                    program: program,
                    phase: context.state.phase,
                    pulse: context.state.pulse,
                    glyphFrame: context.state.glyphFrame,
                    size: 18
                )
            }
            .widgetURL(TetherDeepLink.terminal)
            .keylineTint(TetherLiveTheme.accent)
        }
    }

    /// Prefer ContentState.program — attributes are sticky from Activity.request.
    private func liveProgram(_ context: ActivityViewContext<TetherAgentAttributes>) -> String {
        let fromState = context.state.program
        return fromState.isEmpty ? context.attributes.program : fromState
    }

    private func liveDotColor(_ phase: AgentLivePhase) -> Color {
        switch phase {
        case .exited: TetherLiveTheme.tertiary
        case .paused, .waiting: TetherLiveTheme.warning
        case .opening, .thinking, .writing: TetherLiveTheme.success
        }
    }

    private func statusColor(_ phase: AgentLivePhase) -> Color {
        phase == .waiting ? TetherLiveTheme.warning : TetherLiveTheme.accent
    }

    private func thinkingMono(_ program: String, _ phase: AgentLivePhase) -> Bool {
        phase == .thinking && (AgentThinkingGlyph.style(for: program) == .codex
            || AgentThinkingGlyph.style(for: program) == .gemini)
    }
}

/// Leading mark: CLI glyph while the agent is actively working; brand asset otherwise.
struct AgentLeadingMark: View {
    var program: String
    var phase: AgentLivePhase
    var pulse: Bool
    var glyphFrame: Int
    var size: CGFloat = 28
    var emphasize: Bool = false

    var body: some View {
        if phase.animatesThinkingGlyph, AgentThinkingGlyph.style(for: program) != .generic {
            CLIThinkingGlyph(
                program: program,
                frame: glyphFrame,
                size: size,
                emphasize: emphasize
            )
        } else {
            AgentBrandMark(program: program, pulse: pulse, size: size, emphasize: emphasize)
        }
    }
}

/// Phase trailing glyph. Thinking brand CLIs already animate in the leading slot.
struct PhaseGlyph: View {
    var program: String
    var phase: AgentLivePhase
    var pulse: Bool
    var glyphFrame: Int
    var compact: Bool = false
    @Environment(\.isLuminanceReduced) private var dimmed

    var body: some View {
        Group {
            if phase == .thinking {
                if AgentThinkingGlyph.style(for: program) == .generic {
                    CLIThinkingGlyph(
                        program: program,
                        frame: glyphFrame,
                        size: compact ? 18 : 28,
                        emphasize: !compact
                    )
                } else if compact {
                    Text("···")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(TetherLiveTheme.accent.opacity(dimmed ? 0.45 : 0.85))
                        .frame(width: 18, height: 18)
                } else {
                    Color.clear.frame(width: 32, height: 32)
                }
            } else {
                Image(systemName: phase.symbolName)
                    .font(compact ? .caption.weight(.bold) : .body.weight(.semibold))
                    .foregroundStyle(phase == .exited ? TetherLiveTheme.success : TetherLiveTheme.accent)
                    .symbolEffect(.pulse, options: .repeating, isActive: shouldPulse && !dimmed)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: compact ? 18 : 32, height: compact ? 18 : 32)
                    .background {
                        if !compact {
                            Circle()
                                .fill(TetherLiveTheme.accent.opacity(phase == .exited ? 0.1 : 0.18))
                        }
                    }
                    .overlay {
                        if !compact {
                            Circle().strokeBorder(TetherLiveTheme.accent.opacity(0.35), lineWidth: 1)
                        }
                    }
            }
        }
    }

    private var shouldPulse: Bool {
        phase == .writing || phase == .opening
    }
}

/// Unicode / crystal thinking mark driven by `glyphFrame` ContentState updates.
struct CLIThinkingGlyph: View {
    var program: String
    var frame: Int
    var size: CGFloat
    var emphasize: Bool = false
    @Environment(\.isLuminanceReduced) private var dimmed

    private var style: AgentThinkingGlyph { AgentThinkingGlyph.style(for: program) }

    var body: some View {
        Group {
            switch style {
            case .cursor:
                CursorCrystalShape()
                    .fill(TetherLiveTheme.label, style: FillStyle(eoFill: true))
                    .frame(width: size * 0.78, height: size * 0.78)
            case .codex:
                Text(style.character(frame: frame))
                    .font(.system(size: size * 0.72, weight: .bold, design: .monospaced))
                    .foregroundStyle(TetherLiveTheme.label)
                    .opacity(style.isLit(frame: frame) && !dimmed ? 1 : 0.12)
                    .contentTransition(.opacity)
            case .claude:
                Text(style.character(frame: frame))
                    .font(.system(size: size * 0.78, weight: .semibold, design: .rounded))
                    .foregroundStyle(TetherLiveTheme.claudeTerracotta)
                    // Dingbat frames must stay monochrome text — never Apple emoji tiles.
                    .environment(\.colorScheme, .dark)
                    .contentTransition(.opacity)
                    .animation(.easeInOut(duration: 0.18), value: frame)
            case .gemini:
                BrailleSixDotView(
                    mask: style.brailleSixDotMask(frame: frame),
                    color: TetherLiveTheme.geminiBlue,
                    size: size * 0.72
                )
                .contentTransition(.opacity)
            case .generic:
                Text(style.character(frame: frame))
                    .font(.system(size: size * 0.7, weight: .semibold))
                    .foregroundStyle(TetherLiveTheme.accent)
            }
        }
        .frame(width: size, height: size)
        .background {
            if emphasize {
                RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                    .fill(TetherLiveTheme.badgeFill)
            }
        }
        .overlay {
            if emphasize {
                RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                    .strokeBorder(TetherLiveTheme.accent.opacity(0.4), lineWidth: 1)
            }
        }
        .opacity(dimmed ? 0.7 : 1)
    }
}

/// Drawn Braille six-dot cell — avoids AppleBraille-Outline empty rings.
struct BrailleSixDotView: View {
    var mask: UInt8
    var color: Color
    var size: CGFloat

    var body: some View {
        let gap = size * 0.14
        let dot = size * 0.22
        VStack(spacing: gap) {
            ForEach(0..<3, id: \.self) { row in
                HStack(spacing: gap) {
                    ForEach(0..<2, id: \.self) { col in
                        let index = AgentThinkingGlyph.brailleDotPositions.firstIndex(where: {
                            $0.col == col && $0.row == row
                        }) ?? 0
                        Circle()
                            .fill(color.opacity(AgentThinkingGlyph.brailleDotLit(mask: mask, index: index) ? 1 : 0.18))
                            .frame(width: dot, height: dot)
                    }
                }
            }
        }
        .frame(width: size, height: size)
    }
}

/// Boxicons-style Cursor crystal (path from boxicons v3 / Cursor CLI mark).
struct CursorCrystalShape: Shape {
    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height) / 24
        let o = CGPoint(x: rect.midX - 12 * s, y: rect.midY - 12 * s)
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: o.x + x * s, y: o.y + y * s)
        }
        var path = Path()
        path.move(to: p(20.42, 6.73))
        path.addLine(to: p(12.42, 2.11))
        path.addLine(to: p(3.58, 6.73))
        path.addLine(to: p(3.58, 16.05))
        path.addLine(to: p(12.0, 20.67))
        path.addLine(to: p(20.42, 16.05))
        path.closeSubpath()
        path.move(to: p(19.92, 7.71))
        path.addLine(to: p(12.19, 21.1))
        path.addLine(to: p(12.0, 12.33))
        path.addLine(to: p(4.41, 7.95))
        path.addLine(to: p(19.92, 7.71))
        path.closeSubpath()
        return path
    }
}

struct AgentBrandMark: View {
    var program: String
    var pulse: Bool
    var size: CGFloat = 28
    var emphasize: Bool = false
    @Environment(\.isLuminanceReduced) private var dimmed

    private var isCursor: Bool {
        switch program.lowercased() {
        case "cursor", "cursor-agent", "agent": true
        default: false
        }
    }

    var body: some View {
        Group {
            if isCursor {
                CursorCrystalShape()
                    .fill(style: FillStyle(eoFill: true))
                    .foregroundStyle(TetherLiveTheme.label)
                    .frame(width: size * 0.78, height: size * 0.78)
                    .frame(width: size, height: size)
                    .background(
                        RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                            .fill(Color.black.opacity(0.35))
                    )
            } else {
                Image(AgentLivePhase.brandAssetName(for: program))
                    .resizable()
                    .scaledToFit()
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                .strokeBorder(
                    TetherLiveTheme.accent.opacity(pulse && !dimmed ? 0.85 : emphasize ? 0.55 : 0.4),
                    lineWidth: emphasize ? 1.5 : 1
                )
        }
        .shadow(color: TetherLiveTheme.accent.opacity(emphasize && !dimmed ? 0.35 : 0), radius: 4, y: 0)
        .opacity(dimmed ? 0.75 : 1)
    }
}

struct AgentLockScreenView: View {
    var program: String
    var state: TetherAgentAttributes.ContentState
    @Environment(\.isLuminanceReduced) private var dimmed

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            AgentLeadingMark(
                program: program,
                phase: state.phase,
                pulse: state.pulse,
                glyphFrame: state.glyphFrame,
                size: 40,
                emphasize: true
            )
            VStack(alignment: .leading, spacing: 3) {
                Text(state.displayName)
                    .font(.headline)
                    .foregroundStyle(TetherLiveTheme.label)
                Text(state.detail)
                    .font(
                        state.phase == .thinking
                            && (AgentThinkingGlyph.style(for: program) == .codex
                                || AgentThinkingGlyph.style(for: program) == .gemini)
                            ? .caption.monospaced() : .caption
                    )
                    .foregroundStyle(TetherLiveTheme.secondary)
                    .lineLimit(2)
                    .contentTransition(.opacity)
                HStack(spacing: 6) {
                    Circle()
                        .fill(state.phase == .exited ? TetherLiveTheme.tertiary : TetherLiveTheme.success)
                        .frame(width: 6, height: 6)
                    Text(state.statusLabel)
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(
                            state.phase == .waiting ? TetherLiveTheme.warning : TetherLiveTheme.accent
                        )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .activityBackgroundTint(Color.black.opacity(0.55))
        .activitySystemActionForegroundColor(TetherLiveTheme.accent)
        .opacity(dimmed ? 0.9 : 1)
    }
}
