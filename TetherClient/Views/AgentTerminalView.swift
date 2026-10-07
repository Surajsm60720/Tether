import SwiftUI
import TetherCore
import UIKit

struct AgentTerminalView: View {
    @Bindable var store: ClientStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var control = false
    @State private var keyboardVisible = false
    @State private var focusRequest = 0
    @State private var resignRequest = 0
    @State private var typing = AgentTypingBuffer()
    @State private var following = true
    @State private var jumpToken = 0
    @State private var layoutTask: Task<Void, Never>?
    /// Last size pushed to the Mac. Keyboard avoidance must not shrink the PTY.
    @State private var pinnedColumns = 0
    @State private var pinnedRows = 0

    var body: some View {
        // Key row sits in the normal keyboard-safe layout (no manual lift).
        // PTY rows/columns stay pinned so Claude / Codex / Cursor menus are not clipped.
        ZStack(alignment: .bottom) {
            GeometryReader { geo in
                let metrics = VTMetrics.measure(fontSize: store.fontSize)
                let cover = AgentKeyRow.bandHeight + (control ? AgentKeyRow.hintHeight : 0)
                let usable = max(120, geo.size.height - cover)
                let columns = max(2, Int(geo.size.width / metrics.width))
                let rows = max(2, Int(usable / metrics.height))
                ZStack(alignment: .topLeading) {
                    VTCanvas(
                        surface: store.agentSurface,
                        frame: store.agentFrame,
                        fontSize: store.fontSize,
                        reduceMotion: reduceMotion,
                        jumpToken: jumpToken,
                        control: control,
                        coverBottom: cover,
                        onFollowChange: { following = $0 },
                        onFocus: { focusRequest += 1 },
                        onOpenLink: { openLink($0) }
                    )
                    .accessibilityLabel(store.agentProgram.map { "\(AgentPrograms.displayName($0)) terminal" } ?? "Terminal")
                    if store.agentPaused, !store.agentExited, let name = store.agentProgram {
                        Text("Reconnecting. \(AgentPrograms.displayName(name)) is still running on your Mac.")
                            .font(.caption)
                            .foregroundStyle(TerminalTheme.standard.fg)
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(TerminalTheme.standard.bg.opacity(0.94))
                            .allowsHitTesting(false)
                    } else if let name = store.agentProgram, store.agentError == nil, !store.agentReceived, !store.agentExited {
                        status("Opening \(AgentPrograms.displayName(name)) on your Mac…", name: name)
                    }
                    AgentKeyCapture(focusRequest: focusRequest, resignRequest: resignRequest, typing: typing) { text in
                        type(text)
                    } onInput: { input in
                        if control { control = false }
                        store.sendAgentInput(input)
                    }
                    .frame(width: 1, height: 1)
                    if !following && !store.agentExited {
                        latestButton(cover: cover)
                    }
                    if store.agentExited {
                        ended
                    }
                }
                .onAppear { scheduleLayout(columns: columns, rows: rows, immediate: true) }
                .onChange(of: columns) { _, _ in scheduleLayout(columns: columns, rows: rows, immediate: false) }
                .onChange(of: rows) { _, _ in scheduleLayout(columns: columns, rows: rows, immediate: false) }
                .onChange(of: store.fontSize) { _, _ in scheduleLayout(columns: columns, rows: rows, immediate: false) }
            }

            VStack(spacing: 0) {
                if control {
                    Text("Control on. Type a letter, or tap a link to open it on this iPhone.")
                        .font(.caption2)
                        .foregroundStyle(TerminalTheme.standard.dim)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.top, 4)
                        .frame(height: AgentKeyRow.hintHeight, alignment: .topLeading)
                }
                AgentKeyRow(control: control, keyboardVisible: keyboardVisible) { key in
                    press(key)
                } onKeyboard: {
                    toggleKeyboard()
                }
            }
            .background(TerminalTheme.standard.bg)
        }
        .background(TerminalTheme.standard.bg)
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidShowNotification)) { _ in
            keyboardVisible = true
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidHideNotification)) { _ in
            keyboardVisible = false
        }
        .onChange(of: store.agentExited) { _, exited in
            if exited { resignRequest += 1 }
        }
        .onChange(of: store.agentProgram) { _, _ in
            pinnedColumns = 0
            pinnedRows = 0
        }
        .onChange(of: store.sessionTab) { _, tab in
            // Leaving Terminal drops the keyboard; returning does not force it open.
            if tab != 1 { resignRequest += 1 }
        }
        .onChange(of: store.agentPaused) { wasPaused, paused in
            // After a remote reconnect, put the capture field back so typing / dictation works.
            if wasPaused, !paused, store.sessionTab == 1, !store.agentExited {
                focusRequest += 1
            }
        }
        .onChange(of: store.reconnecting) { wasReconnecting, reconnecting in
            if wasReconnecting, !reconnecting, store.sessionTab == 1,
               store.agentProgram != nil, !store.agentExited, !store.agentPaused {
                focusRequest += 1
            }
        }
        .onDisappear {
            resignRequest += 1
        }
    }

    private func latestButton(cover: CGFloat) -> some View {
        Button {
            following = true
            jumpToken += 1
        } label: {
            Label("Latest", systemImage: "arrow.down")
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 12)
                .frame(minHeight: 44)
                .foregroundStyle(TerminalTheme.standard.bg)
                .background(TerminalTheme.standard.prompt, in: Capsule())
        }
        .buttonStyle(.plain)
        .padding(12)
        .padding(.bottom, cover)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        .accessibilityLabel("Jump to latest output")
    }

    private func scheduleLayout(columns: Int, rows: Int, immediate: Bool) {
        // Inactive tabs can report a collapsed GeometryReader. Never push that size to the Mac.
        guard columns >= 10, rows >= 3 else { return }
        // Keyboard avoidance shrinks the local GeometryReader; keep the remote PTY at the
        // larger pinned size so permission menus (Y / Shift+Tab) are not clipped.
        let nextCols: Int
        let nextRows: Int
        if keyboardVisible, pinnedColumns > 0, pinnedRows > 0 {
            nextCols = max(columns, pinnedColumns)
            nextRows = max(rows, pinnedRows)
        } else {
            nextCols = columns
            nextRows = rows
        }
        layoutTask?.cancel()
        layoutTask = Task { @MainActor in
            if !immediate {
                try? await Task.sleep(for: .milliseconds(120))
            }
            guard !Task.isCancelled else { return }
            pinnedColumns = nextCols
            pinnedRows = nextRows
            store.noteAgentLayout(columns: nextCols, rows: nextRows)
        }
    }

    private func toggleKeyboard() {
        if keyboardVisible {
            resignRequest += 1
        } else {
            focusRequest += 1
        }
    }

    private func openLink(_ raw: String) {
        guard let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return }
        control = false
        UIApplication.shared.open(url)
    }

    private func status(_ text: String, name: String) -> some View {
        Text(text)
            .font(.system(size: store.fontSize, design: .monospaced))
            .foregroundStyle(TerminalTheme.standard.dim)
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .accessibilityLabel(name)
            .allowsHitTesting(false)
    }

    private var ended: some View {
        VStack {
            Spacer()
            VStack(spacing: 8) {
                Text(endedTitle)
                    .font(.subheadline)
                    .foregroundStyle(TerminalTheme.standard.fg)
                    .multilineTextAlignment(.center)
                Button("Back to the shell") {
                    Task { await store.finishAgent() }
                }
                .font(.body.weight(.semibold))
                .frame(minHeight: 44)
                .foregroundStyle(TerminalTheme.standard.bg)
                .padding(.horizontal, 16)
                .background(TerminalTheme.standard.prompt, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .padding(16)
            .frame(maxWidth: .infinity)
            .background(TerminalTheme.standard.bg.opacity(0.94))
        }
    }

    private var endedTitle: String {
        let name = AgentPrograms.displayName(store.agentProgram ?? "Session")
        if let error = store.agentError { return error }
        if store.agentExitCode == 0 { return "\(name) ended" }
        return "\(name) ended (\(store.agentExitCode))"
    }

    private func type(_ text: String) {
        if control {
            control = false
            if let character = text.first {
                store.sendAgentInput(.control(character))
            }
            return
        }
        var chunk = ""
        func flush() {
            guard !chunk.isEmpty else { return }
            store.sendAgentInput(.text(chunk))
            chunk = ""
        }
        for character in text {
            if character == "\t" {
                flush()
                store.sendAgentInput(.tab)
            } else if character == "\n" || character == "\r" {
                flush()
                store.sendAgentInput(.enter)
            } else {
                chunk.append(character)
            }
        }
        flush()
    }

    private func press(_ key: String) {
        typing.discard()
        switch key {
        case "Esc":
            control = false
            store.sendAgentInput(.escape)
        case "Tab":
            store.sendAgentInput(.tab)
        case "S-Tab":
            store.sendAgentInput(.backtab)
        case "Y", "N":
            store.sendAgentInput(.text(key.lowercased()))
        case "Ctrl":
            control.toggle()
        case "C-c":
            control = false
            store.sendAgentInput(.control("c"))
        case "C-z":
            control = false
            store.sendAgentInput(.control("z"))
        case "←":
            store.sendAgentInput(.left)
        case "↑":
            store.sendAgentInput(.up)
        case "↓":
            store.sendAgentInput(.down)
        case "→":
            store.sendAgentInput(.right)
        default:
            break
        }
    }
}

private struct AgentKeyRow: View {
    var control: Bool
    var keyboardVisible: Bool
    var onKey: (String) -> Void
    var onKeyboard: () -> Void
    /// Permission menus from Claude / Codex / Cursor ask for Y and Shift+Tab often.
    private let keys = ["Esc", "Tab", "S-Tab", "Y", "N", "Ctrl", "C-c", "C-z", "←", "↑", "↓", "→"]
    static let bandHeight: CGFloat = 52
    static let hintHeight: CGFloat = 22

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Button(action: onKeyboard) {
                    Image(systemName: keyboardVisible ? "keyboard.chevron.compact.down" : "keyboard")
                        .font(.body)
                        .frame(minWidth: 44, minHeight: 44)
                        .foregroundStyle(TerminalTheme.standard.fg)
                        .overlay {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(TerminalTheme.standard.dim, lineWidth: 1)
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(keyboardVisible ? "Hide keyboard" : "Show keyboard")
                ForEach(keys, id: \.self) { key in
                    Button(key) { onKey(key) }
                        .buttonStyle(.plain)
                        .font(.system(.body, design: .monospaced))
                        .frame(minWidth: 44, minHeight: 44)
                        .padding(.horizontal, 4)
                        .foregroundStyle(TerminalTheme.standard.fg)
                        .background(
                            key == "Ctrl" && control ? TerminalTheme.standard.prompt.opacity(0.28) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(TerminalTheme.standard.dim, lineWidth: 1)
                        }
                        .accessibilityLabel(label(key))
                        .accessibilityHint(key == "Ctrl" ? "Turns Control on. The next letter is sent as Control plus that letter. Tap a link while Control is on to open it on this iPhone. Control C and Control Z also have their own keys." : "")
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
        }
        .frame(height: Self.bandHeight)
        .background(TerminalTheme.standard.bg)
    }

    private func label(_ key: String) -> String {
        switch key {
        case "C-c": "Control C, stop"
        case "C-z": "Control Z, suspend"
        case "S-Tab": "Shift Tab"
        case "Y": "Yes"
        case "N": "No"
        case "←": "Left"
        case "↑": "Up"
        case "↓": "Down"
        case "→": "Right"
        case "Ctrl": control ? "Control, on" : "Control"
        default: key
        }
    }
}

enum VTMetrics {
    static func measure(fontSize: Double) -> (font: UIFont, width: CGFloat, height: CGFloat) {
        let font = UIFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        let width = max(1, ("M" as NSString).size(withAttributes: [.font: font]).width)
        let height = max(1, ceil(font.lineHeight))
        return (font, width, height)
    }
}

private struct VTCanvas: UIViewRepresentable {
    var surface: AgentSurface?
    var frame: Int
    var fontSize: Double
    var reduceMotion: Bool
    var jumpToken: Int
    var control: Bool
    var coverBottom: CGFloat
    var onFollowChange: (Bool) -> Void
    var onFocus: () -> Void
    var onOpenLink: (String) -> Void

    func makeUIView(context: Context) -> VTScrollView {
        let view = VTScrollView()
        view.onFollowChange = onFollowChange
        view.onFocus = onFocus
        view.onOpenLink = onOpenLink
        view.controlHeld = control
        view.coverBottom = coverBottom
        view.canvas.isAccessibilityElement = true
        view.canvas.accessibilityLabel = "Live terminal"
        return view
    }

    func updateUIView(_ view: VTScrollView, context: Context) {
        view.onFollowChange = onFollowChange
        view.onFocus = onFocus
        view.onOpenLink = onOpenLink
        view.controlHeld = control
        view.coverBottom = coverBottom
        let motionChanged = view.canvas.reduceMotion != reduceMotion
        view.canvas.reduceMotion = reduceMotion
        if motionChanged { view.canvas.restartBlink() }
        view.surface = surface
        let previousFrame = context.coordinator.frame
        view.apply(fontSize: fontSize)
        if previousFrame != frame {
            context.coordinator.frame = frame
            if view.follow {
                view.scrollToEnd(animated: false)
            }
        }
        if context.coordinator.jumpToken != jumpToken {
            context.coordinator.jumpToken = jumpToken
            view.follow = true
            view.scrollToEnd(animated: true)
            onFollowChange(true)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var jumpToken = 0
        var frame = -1
    }
}

private final class VTScrollView: UIScrollView, UIScrollViewDelegate {
    let canvas = VTDrawView()
    var surface: AgentSurface?
    var follow = true
    var controlHeld = false
    /// Key row covering the bottom of this scroll view.
    var coverBottom: CGFloat = 0 {
        didSet {
            guard abs(coverBottom - oldValue) > 0.5 else { return }
            updateBottomInset()
            if follow { scrollToEnd(animated: false) }
        }
    }
    var onFollowChange: ((Bool) -> Void)?
    var onFocus: (() -> Void)?
    var onOpenLink: ((String) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = VTPalette.background
        alwaysBounceVertical = true
        keyboardDismissMode = .none
        contentInsetAdjustmentBehavior = .never
        delaysContentTouches = false
        delegate = self
        addSubview(canvas)
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
        tap.cancelsTouchesInView = false
        addGestureRecognizer(tap)
    }

    required init?(coder: NSCoder) { return nil }

    func apply(fontSize: Double) {
        canvas.surface = surface
        guard let screen = surface?.screen else {
            canvas.setNeedsDisplay()
            return
        }
        let metrics = VTMetrics.measure(fontSize: fontSize)
        let lines = screen.scrollback.count + screen.rows
        let width = max(bounds.width, 1)
        let height = max(bounds.height, CGFloat(lines) * metrics.height)
        contentSize = CGSize(width: width, height: height)
        canvas.fontSize = fontSize
        canvas.metrics = metrics
        canvas.surface = surface
        canvas.isOpaque = true
        canvas.backgroundColor = VTPalette.background
        positionCanvas()
        updateBottomInset()
        if follow, !isTracking, !isDragging, !isDecelerating {
            scrollToEnd(animated: false)
        }
    }

    private func positionCanvas() {
        guard bounds.width > 1, bounds.height > 1 else { return }
        let next = CGRect(x: 0, y: contentOffset.y, width: bounds.width, height: bounds.height)
        if canvas.frame != next { canvas.frame = next }
        canvas.originY = contentOffset.y
        canvas.setNeedsDisplay()
    }

    func scrollToEnd(animated: Bool) {
        layoutIfNeeded()
        let top = adjustedContentInset.top
        let inset = adjustedContentInset.bottom
        let visible = bounds.height - inset - top
        // Short startup output stays pinned to the top; a large bottom inset must not
        // scroll the first lines off-screen (that looked like a stuck "Latest" jump).
        let y: CGFloat
        if contentSize.height <= visible + 0.5 {
            y = -top
        } else {
            y = max(-top, contentSize.height - bounds.height + inset)
        }
        if !animated, abs(contentOffset.y - y) < 0.5 { return }
        setContentOffset(CGPoint(x: 0, y: y), animated: animated)
    }

    @objc private func tapped(_ gesture: UITapGestureRecognizer) {
        let modified = controlHeld || gesture.modifierFlags.contains(.control) || gesture.modifierFlags.contains(.command)
        if modified, let target = link(at: gesture.location(in: canvas)) {
            onOpenLink?(target)
            return
        }
        onFocus?()
    }

    private func link(at point: CGPoint) -> String? {
        guard let screen = surface?.screen else { return nil }
        let metrics = canvas.metrics
        guard metrics.width > 0, metrics.height > 0 else { return nil }
        let line = Int((canvas.originY + point.y) / metrics.height)
        let column = Int(point.x / metrics.width)
        guard line >= 0, column >= 0 else { return nil }
        return screen.linkTarget(line: line, column: column)
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        guard follow else { return }
        follow = false
        onFollowChange?(false)
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { settleFollow() }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        settleFollow()
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        positionCanvas()
    }

    private func settleFollow() {
        let distance = contentSize.height - bounds.height + adjustedContentInset.bottom - contentOffset.y
        let atEnd = distance < 24
        guard atEnd != follow else { return }
        follow = atEnd
        onFollowChange?(atEnd)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        positionCanvas()
        updateBottomInset()
    }

    private func updateBottomInset() {
        let overlap = max(0, coverBottom)
        guard abs(contentInset.bottom - overlap) > 0.5 else { return }
        contentInset.bottom = overlap
        verticalScrollIndicatorInsets.bottom = overlap
    }
}

private struct LinePicture {
    var stamp: UInt32
    var columns: Int
    var font: Double
    var scale: CGFloat
    var fingerprint: UInt64
    var image: UIImage
}

private final class VTDrawView: UIView {
    var surface: AgentSurface?
    var originY: CGFloat = 0
    var metrics: (font: UIFont, width: CGFloat, height: CGFloat) = VTMetrics.measure(fontSize: 14)
    var fontSize: Double = 14
    var reduceMotion = false
    private var cursorOn = true
    private var blink: Timer?
    private var linePictures: [Int: LinePicture] = [:]
    private var picturesByFingerprint: [UInt64: UIImage] = [:]

    override func didMoveToWindow() {
        super.didMoveToWindow()
        isOpaque = true
        backgroundColor = VTPalette.background
        restartBlink()
    }

    func restartBlink() {
        blink?.invalidate()
        blink = nil
        cursorOn = true
        guard !reduceMotion, window != nil else { return }
        let timer = Timer(timeInterval: 0.53, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.cursorOn.toggle()
                self?.setNeedsDisplay()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        blink = timer
    }

    override func draw(_ rect: CGRect) {
        guard let screen = surface?.screen else { return }
        let metrics = self.metrics
        let scale = max(contentScaleFactor, 1)
        VTPalette.background.setFill()
        UIRectFill(rect)
        let total = screen.lineCount
        guard total > 0, metrics.height > 0 else { return }
        let first = max(0, Int((originY + rect.minY) / metrics.height))
        let last = min(total - 1, Int((originY + rect.maxY) / metrics.height))
        guard first <= last else { return }
        var usedLines: [Int] = []
        var usedPrints: [UInt64] = []
        usedLines.reserveCapacity(last - first + 1)
        for line in first...last {
            let columns = screen.lineLength(line)
            let stamp = screen.stamp(forLine: line)
            let image: UIImage
            if let cached = linePictures[line],
               cached.stamp == stamp,
               cached.columns == columns,
               cached.font == fontSize,
               cached.scale == scale {
                image = cached.image
                usedPrints.append(cached.fingerprint)
            } else {
                let fingerprint = Self.fingerprint(screen, line: line)
                let rendered = picturesByFingerprint[fingerprint] ?? rasterize(screen, line: line, columns: columns, metrics: metrics, scale: scale)
                picturesByFingerprint[fingerprint] = rendered
                linePictures[line] = LinePicture(
                    stamp: stamp,
                    columns: columns,
                    font: fontSize,
                    scale: scale,
                    fingerprint: fingerprint,
                    image: rendered
                )
                image = rendered
                usedPrints.append(fingerprint)
            }
            usedLines.append(line)
            let y = CGFloat(line) * metrics.height - originY
            image.draw(at: CGPoint(x: 0, y: y))
        }
        if linePictures.count > usedLines.count + 4 {
            let keep = Set(usedLines)
            linePictures = linePictures.filter { keep.contains($0.key) }
        }
        if picturesByFingerprint.count > usedPrints.count + 4 {
            let keep = Set(usedPrints)
            picturesByFingerprint = picturesByFingerprint.filter { keep.contains($0.key) }
        }
        guard screen.cursorVisible, cursorOn || reduceMotion else { return }
        let cursor = screen.drawCursor
        let frame = CGRect(
            x: CGFloat(cursor.column) * metrics.width,
            y: CGFloat(screen.scrollback.count + cursor.row) * metrics.height - originY,
            width: metrics.width,
            height: metrics.height
        )
        guard rect.intersects(frame) else { return }
        VTPalette.cursor.setFill()
        UIRectFill(frame)
    }

    private func rasterize(
        _ screen: VTScreen,
        line: Int,
        columns: Int,
        metrics: (font: UIFont, width: CGFloat, height: CGFloat),
        scale: CGFloat
    ) -> UIImage {
        let row = screen.withLine(line) { Array($0) }
        let width = max(1, metrics.width * CGFloat(max(columns, 1)))
        let height = max(1, metrics.height)
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = true
        return UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { renderer in
            VTPalette.background.setFill()
            renderer.fill(CGRect(x: 0, y: 0, width: width, height: height))
            draw(row, metrics: metrics)
        }
    }

    private static func fingerprint(_ screen: VTScreen, line: Int) -> UInt64 {
        screen.withLine(line) { cells in
            var hash: UInt64 = 0xcbf29ce484222325
            for cell in cells {
                hash ^= UInt64(truncatingIfNeeded: cell.grapheme.hashValue)
                hash &*= 0x100000001b3
                hash ^= UInt64(cell.width) &<< 48
                hash ^= colorHash(cell.foreground)
                hash &*= 0x100000001b3
                hash ^= colorHash(cell.background) &<< 1
                var flags: UInt64 = 0
                if cell.bold { flags |= 1 }
                if cell.dim { flags |= 2 }
                if cell.underline { flags |= 4 }
                if cell.inverse { flags |= 8 }
                if cell.hidden { flags |= 16 }
                hash ^= flags &<< 32
                hash &*= 0x100000001b3
            }
            return hash
        }
    }

    private static func colorHash(_ color: VTColor) -> UInt64 {
        switch color {
        case .standard:
            return 0
        case let .indexed(index):
            return 0x100 | UInt64(index)
        case let .rgb(red, green, blue):
            return 0x200 | (UInt64(red) << 16) | (UInt64(green) << 8) | UInt64(blue)
        }
    }

    private func draw(_ row: [VTCell], metrics: (font: UIFont, width: CGFloat, height: CGFloat)) {
        struct Run {
            var text = ""
            var foreground: UIColor
            var background: UIColor?
            var underline = false
            var column = 0
            var columns = 0
        }
        var runs: [Run] = []
        var column = 0
        while column < row.count {
            let cell = row[column]
            if cell.width == 0 {
                column += 1
                continue
            }
            let span = max(cell.width, 1)
            let colors = VTPalette.colors(for: cell)
            let background = (cell.background != .standard || cell.inverse) ? colors.background : nil
            let glyph = cell.hidden || cell.grapheme.isEmpty ? " " : cell.grapheme
            if var last = runs.last,
               last.foreground == colors.foreground,
               last.background == background,
               last.underline == cell.underline,
               last.column + last.columns == column {
                last.text.append(glyph)
                last.columns += span
                runs[runs.count - 1] = last
            } else {
                runs.append(Run(
                    text: glyph,
                    foreground: colors.foreground,
                    background: background,
                    underline: cell.underline,
                    column: column,
                    columns: span
                ))
            }
            column += span
        }
        let baseline = (metrics.height - metrics.font.lineHeight) / 2
        for run in runs {
            if let background = run.background {
                background.setFill()
                UIRectFill(CGRect(
                    x: metrics.width * CGFloat(run.column),
                    y: 0,
                    width: metrics.width * CGFloat(run.columns),
                    height: metrics.height
                ))
            }
            var attributes: [NSAttributedString.Key: Any] = [
                .font: metrics.font,
                .foregroundColor: run.foreground,
            ]
            if run.underline {
                attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
            }
            NSAttributedString(string: run.text, attributes: attributes).draw(
                at: CGPoint(x: metrics.width * CGFloat(run.column), y: baseline)
            )
        }
    }

}

private enum VTPalette {
    static let background = UIColor(named: "termBg") ?? UIColor(red: 0.07, green: 0.08, blue: 0.09, alpha: 1)
    static let foreground = UIColor(named: "termFg") ?? UIColor(red: 0.90, green: 0.88, blue: 0.84, alpha: 1)
    static let cursor = (UIColor(named: "termPrompt") ?? UIColor(red: 0.91, green: 0.69, blue: 0.29, alpha: 1)).withAlphaComponent(0.45)
    private static let indexedColors: [UIColor] = (0..<256).map(makeIndexed)
    private static let dimForeground = foreground.withAlphaComponent(0.65)

    static func colors(for cell: VTCell) -> (foreground: UIColor, background: UIColor) {
        var foreground = paint(cell.foreground, bold: cell.bold, fallback: self.foreground)
        var background = paint(cell.background, bold: false, fallback: self.background)
        if cell.inverse { swap(&foreground, &background) }
        if cell.dim {
            foreground = foreground == self.foreground ? dimForeground : foreground.withAlphaComponent(0.65)
        }
        return (foreground, background)
    }

    private static func paint(_ color: VTColor, bold: Bool, fallback: UIColor) -> UIColor {
        switch color {
        case .standard:
            return fallback
        case let .indexed(index):
            let adjusted = bold && index < 8 ? index + 8 : index
            return indexedColors[Int(adjusted)]
        case let .rgb(red, green, blue):
            return UIColor(red: CGFloat(red) / 255, green: CGFloat(green) / 255, blue: CGFloat(blue) / 255, alpha: 1)
        }
    }

    private static func makeIndexed(_ index: Int) -> UIColor {
        if index < 16 { return hex(ansi[index]) }
        if index < 232 {
            let value = index - 16
            let levels = [0, 95, 135, 175, 215, 255]
            return UIColor(
                red: CGFloat(levels[(value / 36) % 6]) / 255,
                green: CGFloat(levels[(value / 6) % 6]) / 255,
                blue: CGFloat(levels[value % 6]) / 255,
                alpha: 1
            )
        }
        let gray = 8 + (index - 232) * 10
        return UIColor(white: CGFloat(gray) / 255, alpha: 1)
    }

    private static let ansi: [UInt32] = [
        0x1c1c1c, 0xff7b72, 0x7ee787, 0xe8b04a, 0x6cb6ff, 0xd2a8ff, 0x79c0ff, 0xe6e1d6,
        0x484f58, 0xffa198, 0xa5f3a5, 0xf2cc60, 0x9ecbff, 0xe2c5ff, 0xa5d6ff, 0xffffff,
    ]

    private static func hex(_ value: UInt32) -> UIColor {
        UIColor(
            red: CGFloat((value >> 16) & 0xff) / 255,
            green: CGFloat((value >> 8) & 0xff) / 255,
            blue: CGFloat(value & 0xff) / 255,
            alpha: 1
        )
    }
}

private final class AgentTypingBuffer {
    weak var field: AgentTextField?
    func discard() { field?.discardBuffer() }
}

private struct AgentKeyCapture: UIViewRepresentable {
    var focusRequest: Int
    var resignRequest: Int
    var typing: AgentTypingBuffer
    var onText: (String) -> Void
    var onInput: (VTInput) -> Void

    func makeUIView(context: Context) -> AgentTextField {
        let field = AgentTextField()
        field.delegate = context.coordinator
        field.coordinator = context.coordinator
        field.autocorrectionType = .no
        field.autocapitalizationType = .none
        field.spellCheckingType = .no
        field.smartQuotesType = .no
        field.smartDashesType = .no
        field.smartInsertDeleteType = .no
        field.keyboardAppearance = .dark
        field.tintColor = .clear
        field.textColor = .clear
        field.backgroundColor = .clear
        field.isUserInteractionEnabled = true
        field.addTarget(field, action: #selector(AgentTextField.editingChanged), for: .editingChanged)
        typing.field = field
        return field
    }

    func updateUIView(_ field: AgentTextField, context: Context) {
        context.coordinator.onText = onText
        context.coordinator.onInput = onInput
        typing.field = field
        if context.coordinator.resignRequest != resignRequest {
            context.coordinator.resignRequest = resignRequest
            if resignRequest > 0 {
                field.needsFocus = false
                field.resignFirstResponder()
            }
        }
        guard context.coordinator.focusRequest != focusRequest else { return }
        let request = focusRequest
        field.needsFocus = true
        let focus = {
            guard field.needsFocus, field.window != nil else { return }
            guard field.isFirstResponder || field.becomeFirstResponder() else { return }
            context.coordinator.focusRequest = request
            field.needsFocus = false
        }
        focus()
        if field.needsFocus {
            DispatchQueue.main.async(execute: focus)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(onText: onText, onInput: onInput) }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var onText: (String) -> Void
        var onInput: (VTInput) -> Void
        var focusRequest = 0
        var resignRequest = 0

        init(onText: @escaping (String) -> Void, onInput: @escaping (VTInput) -> Void) {
            self.onText = onText
            self.onInput = onInput
        }

        func textField(_ textField: UITextField, shouldChangeCharactersIn range: NSRange, replacementString string: String) -> Bool {
            if string == "\t" {
                (textField as? AgentTextField)?.discardBuffer()
                emit(.tab, mark: "tab")
                return false
            }
            if string == "\n" || string == "\r" {
                (textField as? AgentTextField)?.submitLine()
                return false
            }
            // Accept the edit so dictation and paste land in one pass. Rejecting
            // them makes the keyboard drip the phrase out a word at a time.
            return true
        }

        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            (textField as? AgentTextField)?.submitLine()
            return false
        }

        private var recent: (mark: String, at: Date)?

        /// Hardware Tab and Control can be delivered twice, once as a key and once as text.
        /// A second copy makes completion jump to the next name.
        func emit(_ input: VTInput, mark: String) {
            let now = Date()
            if let recent, recent.mark == mark, now.timeIntervalSince(recent.at) < 0.05 { return }
            recent = (mark, now)
            onInput(input)
        }
    }
}

private final class AgentTextField: UITextField {
    weak var coordinator: AgentKeyCapture.Coordinator?
    var needsFocus = false
    private var mirror = ""
    private var updating = false

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil, needsFocus else { return }
        if becomeFirstResponder() { needsFocus = false }
    }

    /// Empty terminal prompts still need Backspace. The software keyboard only
    /// sends it when the field reports that it has text.
    override var hasText: Bool { true }

    func discardBuffer() {
        if markedTextRange != nil {
            let committed = text ?? ""
            updating = true
            unmarkText()
            text = committed
            updating = false
            pushDifference()
        }
        updating = true
        text = ""
        mirror = ""
        updating = false
    }

    func submitLine() {
        if markedTextRange != nil {
            let committed = text ?? ""
            updating = true
            unmarkText()
            text = committed
            updating = false
        }
        pushDifference()
        discardBuffer()
        coordinator?.emit(.enter, mark: "enter")
    }

    @objc func editingChanged() {
        pushDifference()
    }

    override func deleteBackward() {
        if markedTextRange != nil {
            super.deleteBackward()
            return
        }
        if let current = text, !current.isEmpty {
            updating = true
            let next = String(current.dropLast())
            text = next
            mirror = next
            updating = false
        }
        coordinator?.onInput(.backspace)
    }

    private func pushDifference() {
        guard !updating, markedTextRange == nil else { return }
        let next = text ?? ""
        if next.hasPrefix(mirror) {
            let suffix = String(next.dropFirst(mirror.count))
            mirror = next
            if !suffix.isEmpty { coordinator?.onText(suffix) }
            return
        }
        if mirror.hasPrefix(next) {
            let removed = mirror.count - next.count
            mirror = next
            for _ in 0..<removed { coordinator?.onInput(.backspace) }
            return
        }
        let common = sharedPrefixCount(mirror, next)
        let removed = mirror.count - common
        let suffix = String(next.dropFirst(common))
        mirror = next
        for _ in 0..<removed { coordinator?.onInput(.backspace) }
        if !suffix.isEmpty { coordinator?.onText(suffix) }
    }

    private func sharedPrefixCount(_ left: String, _ right: String) -> Int {
        var count = 0
        for (a, b) in zip(left, right) {
            if a != b { break }
            count += 1
        }
        return count
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var rest = Set<UIPress>()
        for press in presses {
            if let key = press.key, handle(key) { continue }
            rest.insert(press)
        }
        if !rest.isEmpty { super.pressesBegan(rest, with: event) }
    }

    private func handle(_ key: UIKey) -> Bool {
        guard let coordinator else { return false }
        if key.modifierFlags.contains(.command) { return false }
        if key.modifierFlags.contains(.control),
           let character = key.charactersIgnoringModifiers.first,
           character.isASCII {
            discardBuffer()
            coordinator.emit(.control(character), mark: "control-\(String(character).lowercased())")
            return true
        }
        switch key.keyCode {
        case .keyboardUpArrow:
            discardBuffer()
            coordinator.onInput(.up)
        case .keyboardDownArrow:
            discardBuffer()
            coordinator.onInput(.down)
        case .keyboardLeftArrow:
            discardBuffer()
            coordinator.onInput(.left)
        case .keyboardRightArrow:
            discardBuffer()
            coordinator.onInput(.right)
        case .keyboardEscape:
            discardBuffer()
            coordinator.onInput(.escape)
        case .keyboardTab:
            discardBuffer()
            if key.modifierFlags.contains(.shift) {
                coordinator.emit(.backtab, mark: "backtab")
            } else {
                coordinator.emit(.tab, mark: "tab")
            }
        case .keyboardHome:
            discardBuffer()
            coordinator.onInput(.home)
        case .keyboardEnd:
            discardBuffer()
            coordinator.onInput(.end)
        case .keyboardDeleteOrBackspace:
            return false
        default:
            return false
        }
        return true
    }

    override var keyCommands: [UIKeyCommand]? {
        let tab = UIKeyCommand(input: "\t", modifierFlags: [], action: #selector(pressTab))
        tab.wantsPriorityOverSystemBehavior = true
        let backtab = UIKeyCommand(input: "\t", modifierFlags: .shift, action: #selector(pressBacktab))
        backtab.wantsPriorityOverSystemBehavior = true
        var commands = [tab, backtab]
        for letter in ["c", "z", "d", "l", "a", "e", "k", "u", "w"] {
            let command = UIKeyCommand(input: letter, modifierFlags: .control, action: #selector(pressControl(_:)))
            command.wantsPriorityOverSystemBehavior = true
            commands.append(command)
        }
        return commands
    }

    @objc private func pressTab() {
        discardBuffer()
        coordinator?.emit(.tab, mark: "tab")
    }

    @objc private func pressBacktab() {
        discardBuffer()
        coordinator?.emit(.backtab, mark: "backtab")
    }

    @objc private func pressControl(_ sender: UIKeyCommand) {
        guard let character = sender.input?.first else { return }
        discardBuffer()
        coordinator?.emit(.control(character), mark: "control-\(String(character).lowercased())")
    }
}
