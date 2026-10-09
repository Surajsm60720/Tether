import Foundation

/// CLI-faithful “thinking” marks for Live Activities (ActivityKit forbids GIF/video).
/// Frames mirror Claude Code asterisks, Gemini cli-spinners Braille, Codex blink, Cursor mark.
public enum AgentThinkingGlyph: Sendable {
    case claude
    case gemini
    case codex
    case cursor
    case generic

    /// Claude Code spinner marks (from `@anthropic-ai/claude-code`).
    /// Append `U+FE0E` (text presentation) so dingbats like `✳` don’t render as Apple emoji tiles.
    public static let claudeFrames: [String] = [
        textPresented("·"),
        textPresented("✢"),
        textPresented("✳"),
        textPresented("✶"),
        textPresented("✻"),
        textPresented("✽"),
    ]

    /// Force text-style glyphs (avoids emoji presentation on iOS).
    public static func textPresented(_ scalar: String) -> String {
        scalar + "\u{FE0E}"
    }

    /// `cli-spinners` default `dots` (Braille six-dot).
    public static let geminiFrames: [String] = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]

    /// Short subset of Gemini CLI `WITTY_LOADING_PHRASES` (Apache-2.0), Island-length.
    public static let geminiWittyPhrases: [String] = [
        "I'm Feeling Lucky",
        "Shipping awesomeness",
        "Painting the serifs back on",
        "Navigating the slime mold",
        "Reticulating splines",
        "Warming up the AI hamsters",
        "Asking the magic conch shell",
        "Generating witty retort",
        "Polishing the algorithms",
        "Brewing fresh bytes",
        "Counting electrons",
        "One moment, optimizing humor",
        "Shuffling punchlines",
        "Untangling neural nets",
        "Compiling brilliance",
        "Loading wit.exe",
        "Preparing a witty response",
        "Confuzzling the options",
        "Compiling the 1s and 0s",
        "Rebooting the humor module",
        "Assembling the interwebs",
        "Converting coffee into code",
        "Rewiring the synapses",
        "Pre-heating the servers",
        "Channeling the Force",
        "So say we all",
        "Loading the next great idea",
        "Warp speed engaged",
        "Don't panic",
        "Following the white rabbit",
        "Blowing on the cartridge",
        "Loading… Do a barrel roll!",
        "Waiting for the respawn",
        "Pressing 'A' to continue",
        "Herding digital cats",
        "Polishing the pixels",
        "Almost there… probably",
        "Petting the cat",
        "Rickrolling my boss",
        "Slapping the bass",
        "Tasting the snozberries",
        "Poking the bear",
        "Hmmm… let me think",
        "Trying to exit Vim",
        "Engage.",
        "My other process is a TARDIS",
        "Pondering the orb",
        "Initiating thoughtful gaze",
        "Making it go beep boop.",
        "Releasing the HypnoDrones",
        "Pushing the button, Frank.",
        "Distracting you with wit",
    ]

    public static func style(for program: String) -> AgentThinkingGlyph {
        switch program.lowercased() {
        case "claude": .claude
        case "gemini": .gemini
        case "codex": .codex
        case "cursor", "cursor-agent", "agent": .cursor
        default: .generic
        }
    }

    /// How often the client should bump `glyphFrame` while thinking.
    public var tickInterval: Duration {
        switch self {
        case .claude: .milliseconds(320)
        case .gemini: .milliseconds(120)
        case .codex: .seconds(2)
        /// One perimeter cell per tick (12 × 200 ms ≈ 2.4 s). Sub-cell steps look spotty when ActivityKit coalesces updates.
        case .cursor: .milliseconds(200)
        case .generic: .milliseconds(800)
        }
    }

    public var frames: [String] {
        switch self {
        case .claude: Self.claudeFrames
        case .gemini: Self.geminiFrames
        case .codex: ["·"]
        /// Cursor uses drawn hex dots (`cursorHexOpacity`); character is a fallback only.
        case .cursor: ["⬡"]
        case .generic: ["✦"]
        }
    }

    // MARK: - Cursor DotmHex1-style hex matrix

    /// Flat-top hex row widths (center row is widest).
    public static let cursorHexRowCounts: [Int] = [3, 4, 5, 4, 3]

    /// Perimeter chase path (`row,col` in each row’s local column space).
    public static let cursorHexPerimeter: [(row: Int, col: Int)] = [
        (0, 0), (0, 1), (0, 2),
        (1, 3),
        (2, 4),
        (3, 3),
        (4, 2), (4, 1), (4, 0),
        (3, 0),
        (2, 0),
        (1, 0),
    ]

    /// Packed `row * 8 + col` → perimeter index for O(1) cell lookups.
    private static let cursorHexPathIndexByCell: [Int: Int] = {
        var map: [Int: Int] = [:]
        map.reserveCapacity(cursorHexPerimeter.count)
        for (index, cell) in cursorHexPerimeter.enumerated() {
            map[cell.row * 8 + cell.col] = index
        }
        return map
    }()

    /// One step per perimeter cell — discrete like Gemini’s Braille frames.
    public static let cursorHexPhaseSteps = 12

    /// Opacity for one hex cell at `glyphFrame` (0…1). Port of DotmHex1 perimeter glow,
    /// quantized to whole cells so skipped ActivityKit frames still read as a clean chase.
    public static func cursorHexOpacity(row: Int, col: Int, frame: Int) -> Double {
        let base = 0.12
        let mid = 0.22
        let high = 1.0
        let center = 0.12
        // Short trail: head + ~2 fading cells (Gemini-crisp, not a long soft smear).
        let trailSpan = 2.5
        let pathLen = Double(cursorHexPerimeter.count)
        let halfPath = pathLen / 2

        if row == 2, col == 2 { return center }

        let pathIndex = cursorHexPathIndexByCell[row * 8 + col]
        // Snap heads onto integer perimeter indices — no sub-cell interpolation.
        let headA = Double(abs(frame) % cursorHexPhaseSteps)
        let headB = modPositive(headA + halfPath, pathLen)

        if let pathIndex {
            let glow = max(
                glowAlongPath(head: headA, pathIndex: Double(pathIndex), pathLen: pathLen, trailSpan: trailSpan),
                glowAlongPath(head: headB, pathIndex: Double(pathIndex), pathLen: pathLen, trailSpan: trailSpan) * 0.7
            )
            return min(high, base + glow * (high - base))
        }

        let centerFalloff = col == 2 ? mid : 0.16
        return max(base, centerFalloff)
    }

    private static func modPositive(_ n: Double, _ m: Double) -> Double {
        ((n.truncatingRemainder(dividingBy: m)) + m).truncatingRemainder(dividingBy: m)
    }

    private static func glowAlongPath(head: Double, pathIndex: Double, pathLen: Double, trailSpan: Double) -> Double {
        let distance = modPositive(head - pathIndex, pathLen)
        return 1 - smoothstep(0, trailSpan, distance)
    }

    private static func smoothstep(_ edge0: Double, _ edge1: Double, _ x: Double) -> Double {
        guard edge1 > edge0 else { return x >= edge1 ? 1 : 0 }
        let t = min(1, max(0, (x - edge0) / (edge1 - edge0)))
        return t * t * (3 - 2 * t)
    }

    public func character(frame: Int) -> String {
        let list = frames
        guard !list.isEmpty else { return "·" }
        return list[abs(frame) % list.count]
    }

    /// Six-dot Braille masks (bits 0…5 → dots 1…6) for the current Gemini frame.
    /// Draw these as circles — Apple Braille outline fonts often render empty rings.
    public func brailleSixDotMask(frame: Int) -> UInt8 {
        guard self == .gemini else { return 0 }
        let ch = character(frame: frame)
        guard let scalar = ch.unicodeScalars.first else { return 0 }
        let value = scalar.value
        guard value >= 0x2800, value <= 0x28FF else { return 0 }
        return UInt8(value - 0x2800) & 0x3F
    }

    /// Dot positions in a 2×3 grid: (col, row) for bits 0…5.
    public static let brailleDotPositions: [(col: Int, row: Int)] = [
        (0, 0), (0, 1), (0, 2), (1, 0), (1, 1), (1, 2),
    ]

    public static func brailleDotLit(mask: UInt8, index: Int) -> Bool {
        guard index >= 0, index < 6 else { return false }
        return (mask & (1 << index)) != 0
    }

    /// Codex: interpunct visible on even frames (2 s cadence → blink).
    public func isLit(frame: Int) -> Bool {
        switch self {
        case .codex: frame % 2 == 0
        default: true
        }
    }

    /// Optional status line replacing the generic “Thinking · host” copy.
    public func statusDetail(frame: Int) -> String? {
        switch self {
        case .gemini:
            let phrases = Self.geminiWittyPhrases
            guard !phrases.isEmpty else { return nil }
            // Rotate slower than the Braille spinner (every ~10 ticks ≈ 1.2 s).
            return phrases[(abs(frame) / 10) % phrases.count]
        case .codex:
            return "Following instructions"
        default:
            return nil
        }
    }

    public static func detail(
        program: String,
        phase: AgentLivePhase,
        frame: Int,
        title: String?,
        hostName: String,
        statusLabel: String? = nil,
        readingDetail: String? = nil
    ) -> String {
        // Prefer scraped PTY context when present.
        if let readingDetail, !readingDetail.isEmpty { return readingDetail }

        // Gemini witty lines only when the chip is still generic Thinking.
        let label = (statusLabel ?? "").lowercased()
        if phase == .thinking || phase == .writing {
            if label == "thinking" || label.isEmpty,
               let custom = style(for: program).statusDetail(frame: frame) {
                return custom
            }
        }
        return AgentLivePhaseResolver.detail(phase: phase, title: title, hostName: hostName)
    }
}
