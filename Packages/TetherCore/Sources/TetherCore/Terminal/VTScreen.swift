import Foundation

public enum VTColor: Equatable, Sendable {
    case standard
    case indexed(UInt8)
    case rgb(UInt8, UInt8, UInt8)
}

public struct VTCell: Equatable, Sendable {
    public var grapheme: String
    public var width: Int
    public var foreground: VTColor
    public var background: VTColor
    public var bold: Bool
    public var dim: Bool
    public var underline: Bool
    public var inverse: Bool
    public var hidden: Bool
    /// Non-zero when this cell belongs to an OSC 8 hyperlink. The screen owns the address.
    public var linkID: UInt32

    public static let blank = VTCell(
        grapheme: " ",
        width: 1,
        foreground: .standard,
        background: .standard,
        bold: false,
        dim: false,
        underline: false,
        inverse: false,
        hidden: false,
        linkID: 0
    )
}

/// What the phone sends when a key is pressed. The screen decides the exact bytes
/// because application cursor mode and bracketed paste change them.
public enum VTInput: Equatable, Sendable {
    case text(String)
    case backspace
    case enter
    case tab
    case backtab
    case escape
    case up, down, left, right
    case home, end
    case control(Character)
}

public enum VTKeys {
    public static func encode(_ input: VTInput, applicationCursor: Bool, bracketedPaste: Bool) -> Data {
        switch input {
        case let .text(text):
            let bytes = Data(text.utf8)
            let literal = text.contains { character in
                guard let ascii = character.asciiValue else { return false }
                return ascii < 0x20 || ascii == 0x7f
            }
            guard bracketedPaste, text.count > 1, !literal else { return bytes }
            var wrapped = Data("\u{1b}[200~".utf8)
            wrapped.append(bytes)
            wrapped.append(Data("\u{1b}[201~".utf8))
            return wrapped
        case .backspace:
            return Data([0x7f])
        case .enter:
            return Data([0x0d])
        case .tab:
            return Data([0x09])
        case .backtab:
            return Data("\u{1b}[Z".utf8)
        case .escape:
            return Data([0x1b])
        case .up:
            return arrow("A", application: applicationCursor)
        case .down:
            return arrow("B", application: applicationCursor)
        case .right:
            return arrow("C", application: applicationCursor)
        case .left:
            return arrow("D", application: applicationCursor)
        case .home:
            return Data("\u{1b}[H".utf8)
        case .end:
            return Data("\u{1b}[F".utf8)
        case let .control(character):
            guard let ascii = character.asciiValue else { return Data() }
            return Data([ascii & 0x1f])
        }
    }

    private static func arrow(_ letter: String, application: Bool) -> Data {
        Data((application ? "\u{1b}O\(letter)" : "\u{1b}[\(letter)").utf8)
    }
}

/// A terminal grid. Bytes from the Mac are applied here; replies (cursor reports,
/// device attributes) go back to the Mac unchanged.
public struct VTScreen: Equatable, Sendable {
    public private(set) var columns: Int
    public private(set) var rows: Int
    public private(set) var cells: [VTCell]
    public private(set) var cursorRow: Int
    public private(set) var cursorColumn: Int
    public private(set) var cursorVisible: Bool
    public private(set) var title: String
    public private(set) var applicationCursorKeys: Bool
    public private(set) var bracketedPaste: Bool
    /// Lines that scrolled off the top of the live screen. The newest line is last.
    public private(set) var scrollback: [[VTCell]] = []
    /// Picture identity for each live row. A row keeps its stamp until its cells change,
    /// so the phone can reuse the bitmap it already drew.
    private var rowStamp: [UInt32]
    private var scrollStamp: [UInt32] = []
    private var nextStamp: UInt32 = 1

    private var pen: VTCell
    private var wrap: Bool
    private var wrapPending: Bool
    private var originMode: Bool
    private var scrollTop: Int
    private var scrollBottom: Int
    private var state: Parse
    private var privateMarker: UInt8
    private var params: [Int]
    private var param: Int
    private var paramSeen: Bool
    private var osc: [UInt8]
    private var utfBuffer: [UInt8]
    private var utfExpected: Int
    private var savedCursor: SavedCursor?
    private var primary: [VTCell]?
    private var primaryCursor: SavedPlace?
    private var alternate: Bool
    private var links: [UInt32: String]
    private var idsByLink: [String: UInt32]
    private var nextLinkID: UInt32
    private var activeLinkID: UInt32

    private struct SavedCursor: Equatable {
        var row: Int
        var column: Int
        var pen: VTCell
        var linkID: UInt32
    }

    private struct SavedPlace: Equatable {
        var row: Int
        var column: Int
        var wrap: Bool
    }

    private enum Parse: Equatable {
        case ground, escape, csi, osc, oscEsc, charset, ss3
    }

    public init(columns: Int = 80, rows: Int = 24) {
        let columns = max(2, columns)
        let rows = max(2, rows)
        self.columns = columns
        self.rows = rows
        cells = Array(repeating: .blank, count: columns * rows)
        rowStamp = Array(repeating: 0, count: rows)
        cursorRow = 0
        cursorColumn = 0
        cursorVisible = true
        title = ""
        applicationCursorKeys = false
        bracketedPaste = false
        pen = .blank
        wrap = true
        wrapPending = false
        originMode = false
        scrollTop = 0
        scrollBottom = rows - 1
        state = .ground
        privateMarker = 0
        params = []
        param = 0
        paramSeen = false
        osc = []
        utfBuffer = []
        utfExpected = 0
        savedCursor = nil
        primary = nil
        primaryCursor = nil
        alternate = false
        links = [:]
        idsByLink = [:]
        nextLinkID = 1
        activeLinkID = 0
    }

    /// Address under a cell when Control-click should open it on this device.
    /// OSC 8 hyperlinks win. Plain http and https text is recognized otherwise.
    /// Anything that is not a web address returns nil so it stays on the Mac.
    public func linkTarget(line: Int, column: Int) -> String? {
        guard column >= 0, line >= 0, line < lineCount else { return nil }
        return withLine(line) { slice in
            let cells = Array(slice)
            guard column < cells.count else { return nil }
            var probe = column
            if cells[probe].width == 0, probe > 0 { probe -= 1 }
            if cells[probe].linkID != 0, let raw = links[cells[probe].linkID] {
                return VTBrowserLink.webAddress(raw)
            }
            return VTBrowserLink.plainAddress(in: cells, column: column)
        }
    }

    public var drawCursor: (row: Int, column: Int) {
        (cursorRow, min(max(0, cursorColumn), columns - 1))
    }

    public func glyph(row: Int, column: Int) -> String {
        guard row >= 0, row < rows, column >= 0, column < columns else { return "" }
        return cells[row * columns + column].grapheme
    }

    public func cell(row: Int, column: Int) -> VTCell {
        guard row >= 0, row < rows, column >= 0, column < columns else { return .blank }
        return cells[row * columns + column]
    }

    public func rowCells(_ row: Int) -> [VTCell] {
        guard row >= 0, row < rows else { return [] }
        let start = row * columns
        return Array(cells[start..<(start + columns)])
    }

    public var lineCount: Int { scrollback.count + rows }

    /// Stable for as long as that line's cells stay the same. Zero is a blank line.
    public func stamp(forLine line: Int) -> UInt32 {
        if line < scrollback.count {
            guard line < scrollStamp.count else { return 0 }
            return scrollStamp[line]
        }
        let row = line - scrollback.count
        guard row >= 0, row < rowStamp.count else { return 0 }
        return rowStamp[row]
    }

    public func lineLength(_ line: Int) -> Int {
        if line < scrollback.count { return scrollback[line].count }
        if line < lineCount { return columns }
        return 0
    }

    /// The closure must finish before the screen changes. It sees the cells in place.
    public func withLine<T>(_ line: Int, _ body: (ArraySlice<VTCell>) -> T) -> T {
        if line < scrollback.count {
            let row = scrollback[line]
            return body(row[...])
        }
        let row = line - scrollback.count
        guard row >= 0, row < rows else { return body(ArraySlice<VTCell>()) }
        let start = row * columns
        return body(cells[start..<(start + columns)])
    }

    /// History plus the live screen, trailing blank lines removed.
    public func plainText() -> String {
        var lines = scrollback.map(lineText)
        for row in 0..<rows {
            lines.append(lineText(rowSlice(row)))
        }
        while lines.last?.isEmpty == true {
            lines.removeLast()
        }
        return lines.joined(separator: "\n")
    }

    @discardableResult
    public mutating func ingest(_ data: Data) -> Data {
        var replies = Data()
        for byte in data {
            if let reply = feed(byte), !reply.isEmpty {
                replies.append(reply)
            }
        }
        return replies
    }

    public mutating func resize(columns: Int, rows: Int) {
        let columns = max(2, columns)
        let rows = max(2, rows)
        guard columns != self.columns || rows != self.rows else { return }
        cells = resized(cells, fromColumns: self.columns, toColumns: columns, toRows: rows)
        if let saved = primary {
            primary = resized(saved, fromColumns: self.columns, toColumns: columns, toRows: rows)
        }
        self.columns = columns
        self.rows = rows
        var stamps = Array(repeating: UInt32(0), count: rows)
        let keep = min(rowStamp.count, rows)
        for row in 0..<keep { stamps[row] = rowStamp[row] }
        rowStamp = stamps
        scrollTop = 0
        scrollBottom = rows - 1
        cursorRow = min(cursorRow, rows - 1)
        cursorColumn = min(cursorColumn, columns)
    }

    private func resized(_ source: [VTCell], fromColumns: Int, toColumns: Int, toRows: Int) -> [VTCell] {
        var next = Array(repeating: VTCell.blank, count: toColumns * toRows)
        let fromRows = source.count / max(fromColumns, 1)
        let copyRows = min(fromRows, toRows)
        let copyColumns = min(fromColumns, toColumns)
        for row in 0..<copyRows {
            for column in 0..<copyColumns {
                next[row * toColumns + column] = source[row * fromColumns + column]
            }
        }
        return next
    }

    private mutating func feed(_ byte: UInt8) -> Data? {
        switch state {
        case .ground:
            return ground(byte)
        case .escape:
            return escape(byte)
        case .csi:
            return csi(byte)
        case .osc:
            if byte == 0x07 {
                finishOSC()
                state = .ground
            } else if byte == 0x1b {
                state = .oscEsc
            } else if osc.count < 4096 {
                osc.append(byte)
            }
            return nil
        case .oscEsc:
            if byte == 0x5c {
                finishOSC()
            }
            state = .ground
            if byte != 0x5c { return feed(byte) }
            return nil
        case .charset, .ss3:
            state = .ground
            return nil
        }
    }

    private mutating func ground(_ byte: UInt8) -> Data? {
        switch byte {
        case 0x1b:
            utfBuffer.removeAll()
            state = .escape
        case 0x08:
            backspace()
        case 0x09:
            tab()
        case 0x0a, 0x0b, 0x0c:
            lineFeed()
        case 0x0d:
            carriageReturn()
        case 0x00...0x1f, 0x7f:
            break
        default:
            pushUTF8(byte)
        }
        return nil
    }

    private mutating func escape(_ byte: UInt8) -> Data? {
        state = .ground
        switch byte {
        case 0x5b:
            resetCSI()
            state = .csi
        case 0x5d:
            osc.removeAll(keepingCapacity: true)
            state = .osc
        case 0x37:
            savedCursor = SavedCursor(row: cursorRow, column: cursorColumn, pen: pen, linkID: activeLinkID)
        case 0x38:
            restoreCursor()
        case 0x44:
            lineFeed()
        case 0x4d:
            reverseIndex()
        case 0x45:
            lineFeed()
            carriageReturn()
        case 0x63:
            resetScreen()
        case 0x28, 0x29, 0x2a, 0x2b:
            state = .charset
        case 0x4f:
            state = .ss3
        default:
            break
        }
        return nil
    }

    private mutating func csi(_ byte: UInt8) -> Data? {
        if byte >= 0x40 && byte <= 0x7e {
            let reply = dispatchCSI(final: byte)
            resetCSI()
            state = .ground
            return reply
        }
        if byte == 0x3f || byte == 0x3e || byte == 0x21 {
            if privateMarker == 0 && params.isEmpty && !paramSeen {
                privateMarker = byte
            }
            return nil
        }
        if byte >= 0x30 && byte <= 0x39 {
            paramSeen = true
            param = min(9999, param * 10 + Int(byte - 0x30))
            return nil
        }
        if byte == 0x3b {
            guard params.count < 16 else { return nil }
            params.append(paramSeen ? param : 0)
            param = 0
            paramSeen = false
            return nil
        }
        if byte >= 0x20 && byte <= 0x2f {
            return nil
        }
        resetCSI()
        state = .ground
        return nil
    }

    private mutating func dispatchCSI(final: UInt8) -> Data? {
        let values = collectedParams()
        switch final {
        case 0x41: moveVertical(-number(values, default: 1))
        case 0x42: moveVertical(number(values, default: 1))
        case 0x43: moveHorizontal(number(values, default: 1))
        case 0x44: moveHorizontal(-number(values, default: 1))
        case 0x45:
            moveVertical(number(values, default: 1))
            carriageReturn()
        case 0x46:
            moveVertical(-number(values, default: 1))
            carriageReturn()
        case 0x47:
            cursorColumn = min(columns - 1, max(0, number(values, default: 1) - 1))
            wrapPending = false
        case 0x48, 0x66:
            place(row: number(values, at: 0, default: 1), column: number(values, at: 1, default: 1))
        case 0x4a:
            eraseDisplay(values.first ?? 0)
        case 0x4b:
            eraseLine(values.first ?? 0)
        case 0x4c:
            insertLines(number(values, default: 1))
        case 0x4d:
            deleteLines(number(values, default: 1))
        case 0x50:
            deleteCharacters(number(values, default: 1))
        case 0x53:
            scroll(number(values, default: 1))
        case 0x54:
            scroll(-number(values, default: 1))
        case 0x58:
            eraseCharacters(number(values, default: 1))
        case 0x40:
            insertCharacters(number(values, default: 1))
        case 0x64:
            place(row: number(values, default: 1), column: cursorColumn + 1)
        case 0x6d:
            sgr(values.isEmpty ? [0] : values)
        case 0x68:
            setMode(values.isEmpty ? [0] : values, enable: true)
        case 0x6c:
            setMode(values.isEmpty ? [0] : values, enable: false)
        case 0x6e:
            return report(values.first ?? 0)
        case 0x72:
            setScrollRegion(values)
        case 0x73:
            savedCursor = SavedCursor(row: cursorRow, column: cursorColumn, pen: pen, linkID: activeLinkID)
        case 0x75:
            restoreCursor()
        case 0x63:
            if privateMarker == 0x3e { return Data("\u{1b}[>0;95;0c".utf8) }
            return Data("\u{1b}[?64;1;2c".utf8)
        case 0x74:
            if (values.first ?? 0) == 18 { return Data("\u{1b}[8;\(rows);\(columns)t".utf8) }
        default:
            break
        }
        return nil
    }

    private func collectedParams() -> [Int] {
        var all = params
        if paramSeen || !params.isEmpty {
            all.append(paramSeen ? param : 0)
        }
        return all
    }

    private func number(_ values: [Int], at index: Int = 0, default fallback: Int) -> Int {
        guard index < values.count else { return fallback }
        let value = values[index]
        return value == 0 ? fallback : value
    }

    private mutating func report(_ code: Int) -> Data? {
        switch code {
        case 5:
            return Data("\u{1b}[0n".utf8)
        case 6:
            let row = cursorRow + 1
            let column = min(cursorColumn, columns - 1) + 1
            return Data("\u{1b}[\(row);\(column)R".utf8)
        default:
            return nil
        }
    }

    private mutating func sgr(_ values: [Int]) {
        var index = 0
        while index < values.count {
            let code = values[index]
            switch code {
            case 0:
                pen = .blank
            case 1: pen.bold = true
            case 2: pen.dim = true
            case 4: pen.underline = true
            case 7: pen.inverse = true
            case 8: pen.hidden = true
            case 22: pen.bold = false
            case 23: break
            case 24: pen.underline = false
            case 27: pen.inverse = false
            case 28: pen.hidden = false
            case 39: pen.foreground = .standard
            case 49: pen.background = .standard
            case 30...37: pen.foreground = .indexed(UInt8(code - 30))
            case 40...47: pen.background = .indexed(UInt8(code - 40))
            case 90...97: pen.foreground = .indexed(UInt8(code - 90 + 8))
            case 100...107: pen.background = .indexed(UInt8(code - 100 + 8))
            case 38, 48:
                let color = readColor(values, from: index)
                if code == 38 { pen.foreground = color.color } else { pen.background = color.color }
                index += color.consumed
                continue
            default:
                break
            }
            index += 1
        }
    }

    private func readColor(_ values: [Int], from index: Int) -> (color: VTColor, consumed: Int) {
        guard index + 1 < values.count else { return (.standard, 1) }
        if values[index + 1] == 5, index + 2 < values.count {
            return (.indexed(UInt8(clamping: values[index + 2])), 3)
        }
        if values[index + 1] == 2, index + 4 < values.count {
            return (.rgb(UInt8(clamping: values[index + 2]), UInt8(clamping: values[index + 3]), UInt8(clamping: values[index + 4])), 5)
        }
        return (.standard, 1)
    }

    private mutating func setMode(_ values: [Int], enable: Bool) {
        let dec = privateMarker == 0x3f
        for value in values {
            guard dec else { continue }
            switch value {
            case 1: applicationCursorKeys = enable
            case 6:
                originMode = enable
                place(row: 1, column: 1)
            case 7: wrap = enable
            case 25: cursorVisible = enable
            case 47: if enable { enterAlternate(clear: false) } else { leaveAlternate() }
            case 1047: if enable { enterAlternate(clear: true) } else { leaveAlternate() }
            case 1049: if enable { enterAlternate(clear: true) } else { leaveAlternate() }
            case 2004: bracketedPaste = enable
            default: break
            }
        }
    }

    private mutating func enterAlternate(clear: Bool) {
        guard !alternate else { return }
        primary = cells
        primaryCursor = SavedPlace(row: cursorRow, column: cursorColumn, wrap: wrapPending)
        alternate = true
        if clear {
            cells = Array(repeating: .blank, count: columns * rows)
            rowStamp = Array(repeating: 0, count: rows)
            cursorRow = 0
            cursorColumn = 0
            wrapPending = false
        }
    }

    private mutating func leaveAlternate() {
        guard alternate, let saved = primary else {
            alternate = false
            return
        }
        cells = saved
        primary = nil
        if let cursor = primaryCursor {
            cursorRow = min(cursor.row, rows - 1)
            cursorColumn = min(cursor.column, columns)
            wrapPending = cursor.wrap
        }
        primaryCursor = nil
        alternate = false
        if rowStamp.count != rows {
            rowStamp = Array(repeating: 0, count: rows)
        }
        for row in 0..<rows { touchRow(row) }
    }

    private mutating func setScrollRegion(_ values: [Int]) {
        let top = max(1, values.first ?? 1) - 1
        let bottom = min(rows, values.count > 1 ? max(1, values[1]) : rows) - 1
        if top < bottom {
            scrollTop = top
            scrollBottom = bottom
        } else {
            scrollTop = 0
            scrollBottom = rows - 1
        }
        place(row: 1, column: 1)
    }

    private mutating func place(row: Int, column: Int) {
        let row = max(1, row) - 1
        let column = max(1, column) - 1
        if originMode {
            cursorRow = min(scrollBottom, scrollTop + row)
        } else {
            cursorRow = min(rows - 1, row)
        }
        cursorColumn = min(columns - 1, column)
        wrapPending = false
    }

    private mutating func moveVertical(_ delta: Int) {
        if delta >= 0 {
            cursorRow = min(rows - 1, cursorRow + delta)
        } else {
            cursorRow = max(0, cursorRow + delta)
        }
        wrapPending = false
    }

    private mutating func moveHorizontal(_ delta: Int) {
        if delta >= 0 {
            cursorColumn = min(columns - 1, cursorColumn + delta)
        } else {
            cursorColumn = max(0, cursorColumn + delta)
        }
        wrapPending = false
    }

    private mutating func eraseDisplay(_ mode: Int) {
        switch mode {
        case 0:
            blank(from: cursorRow * columns + min(cursorColumn, columns - 1), through: cells.count - 1)
        case 1:
            blank(from: 0, through: cursorRow * columns + min(cursorColumn, columns - 1))
        case 2:
            cells = Array(repeating: .blank, count: columns * rows)
            rowStamp = Array(repeating: 0, count: rows)
        case 3:
            cells = Array(repeating: .blank, count: columns * rows)
            rowStamp = Array(repeating: 0, count: rows)
            scrollback.removeAll()
            scrollStamp.removeAll()
        default:
            break
        }
    }

    private mutating func eraseLine(_ mode: Int) {
        let start = cursorRow * columns
        let column = min(cursorColumn, columns - 1)
        switch mode {
        case 0: blank(from: start + column, through: start + columns - 1)
        case 1: blank(from: start, through: start + column)
        case 2: blank(from: start, through: start + columns - 1)
        default: break
        }
    }

    private mutating func eraseCharacters(_ count: Int) {
        let start = cursorRow * columns + min(cursorColumn, columns - 1)
        let end = min(cells.count - 1, start + max(0, count) - 1)
        guard count > 0 else { return }
        blank(from: start, through: end)
    }

    private mutating func blank(from start: Int, through end: Int) {
        guard start <= end, start >= 0, end < cells.count else { return }
        var row = start / columns
        var dirty = false
        for index in start...end {
            let nextRow = index / columns
            if nextRow != row {
                if dirty { touchRow(row) }
                row = nextRow
                dirty = false
            }
            if cells[index] != .blank {
                cells[index] = .blank
                dirty = true
            }
        }
        if dirty { touchRow(row) }
    }

    private mutating func insertLines(_ count: Int) {
        guard cursorRow >= scrollTop, cursorRow <= scrollBottom, count > 0 else { return }
        for _ in 0..<count {
            for row in stride(from: scrollBottom, to: cursorRow, by: -1) {
                copyRow(row - 1, to: row)
            }
            clearRow(cursorRow)
        }
    }

    private mutating func deleteLines(_ count: Int) {
        guard cursorRow >= scrollTop, cursorRow <= scrollBottom, count > 0 else { return }
        for _ in 0..<min(count, scrollBottom - cursorRow + 1) {
            for row in cursorRow..<scrollBottom {
                copyRow(row + 1, to: row)
            }
            clearRow(scrollBottom)
        }
    }

    private mutating func insertCharacters(_ count: Int) {
        guard count > 0, cursorColumn < columns else { return }
        let row = cursorRow
        let start = cursorColumn
        for column in stride(from: columns - 1, to: start, by: -1) {
            let source = column - count
            cells[row * columns + column] = source >= start ? cells[row * columns + source] : .blank
        }
        touchRow(row)
    }

    private mutating func deleteCharacters(_ count: Int) {
        guard count > 0, cursorColumn < columns else { return }
        let row = cursorRow
        for column in cursorColumn..<columns {
            let source = column + count
            cells[row * columns + column] = source < columns ? cells[row * columns + source] : .blank
        }
        touchRow(row)
    }

    private mutating func backspace() {
        if wrapPending {
            wrapPending = false
            return
        }
        if cursorColumn > 0 { cursorColumn -= 1 }
    }

    private mutating func tab() {
        wrapPending = false
        let next = min(columns - 1, ((cursorColumn / 8) + 1) * 8)
        cursorColumn = next
    }

    private mutating func carriageReturn() {
        cursorColumn = 0
        wrapPending = false
    }

    private mutating func lineFeed() {
        wrapPending = false
        if cursorRow == scrollBottom {
            scroll(1)
        } else if cursorRow < rows - 1 {
            cursorRow += 1
        }
    }

    private mutating func reverseIndex() {
        wrapPending = false
        if cursorRow == scrollTop {
            scroll(-1)
        } else if cursorRow > 0 {
            cursorRow -= 1
        }
    }

    private mutating func scroll(_ delta: Int) {
        guard delta != 0 else { return }
        if delta > 0, scrollTop == 0, !alternate {
            let leaving = min(delta, scrollBottom + 1)
            for row in 0..<leaving {
                archiveRow(row)
            }
        }
        if delta > 0 {
            for row in scrollTop...scrollBottom {
                let source = row + delta
                if source <= scrollBottom {
                    copyRow(source, to: row)
                } else {
                    clearRow(row)
                }
            }
        } else {
            let distance = -delta
            for row in stride(from: scrollBottom, through: scrollTop, by: -1) {
                let source = row - distance
                if source >= scrollTop {
                    copyRow(source, to: row)
                } else {
                    clearRow(row)
                }
            }
        }
    }

    private mutating func copyRow(_ source: Int, to destination: Int) {
        guard source != destination, source >= 0, destination >= 0, source < rows, destination < rows else { return }
        let from = source * columns
        let to = destination * columns
        for column in 0..<columns {
            cells[to + column] = cells[from + column]
        }
        if source < rowStamp.count, destination < rowStamp.count {
            rowStamp[destination] = rowStamp[source]
        }
    }

    private mutating func clearRow(_ row: Int) {
        guard row >= 0, row < rows else { return }
        for column in 0..<columns {
            cells[row * columns + column] = .blank
        }
        if row < rowStamp.count { rowStamp[row] = 0 }
    }

    private mutating func touchRow(_ row: Int) {
        guard row >= 0, row < rowStamp.count else { return }
        let stamp = nextStamp
        nextStamp &+= 1
        if nextStamp == 0 { nextStamp = 1 }
        rowStamp[row] = stamp
    }

    private mutating func put(_ grapheme: String, width: Int) {
        if width == 0 {
            attach(grapheme)
            return
        }
        if wrapPending || cursorColumn >= columns {
            if wrap {
                lineFeed()
                carriageReturn()
            } else {
                cursorColumn = columns - 1
            }
        }
        if cursorColumn + width > columns, wrap {
            lineFeed()
            carriageReturn()
        }
        let column = min(cursorColumn, columns - 1)
        let row = cursorRow
        let coveredWide = cells[row * columns + column].width != 1
        clearWide(at: column)
        var cell = pen
        cell.grapheme = grapheme
        cell.width = width
        cell.linkID = activeLinkID
        let index = row * columns + column
        var changed = cells[index] != cell
        cells[index] = cell
        if width == 2, column + 1 < columns {
            var spacer = VTCell.blank
            spacer.grapheme = ""
            spacer.width = 0
            spacer.linkID = activeLinkID
            if cells[index + 1] != spacer { changed = true }
            cells[index + 1] = spacer
        }
        cursorColumn = column + width
        if cursorColumn >= columns {
            cursorColumn = columns
            wrapPending = wrap
        }
        if changed || coveredWide { touchRow(row) }
    }

    private mutating func attach(_ grapheme: String) {
        var column = min(cursorColumn, columns) - 1
        if column < 0 { return }
        if cells[cursorRow * columns + column].width == 0, column > 0 { column -= 1 }
        cells[cursorRow * columns + column].grapheme.append(grapheme)
        touchRow(cursorRow)
    }

    private mutating func clearWide(at column: Int) {
        let index = cursorRow * columns + column
        if cells[index].width == 0, column > 0 {
            cells[index - 1] = .blank
            cells[index] = .blank
        } else if cells[index].width == 2, column + 1 < columns {
            cells[index + 1] = .blank
        }
    }

    private mutating func pushUTF8(_ byte: UInt8) {
        if byte < 0x80 {
            utfBuffer.removeAll()
            emit(Unicode.Scalar(byte))
            return
        }
        if byte & 0xc0 == 0x80, !utfBuffer.isEmpty {
            utfBuffer.append(byte)
            guard utfBuffer.count >= utfExpected else { return }
            let data = Data(utfBuffer)
            utfBuffer.removeAll()
            if let scalar = String(data: data, encoding: .utf8)?.unicodeScalars.first {
                emit(scalar)
            } else {
                emit(Unicode.Scalar(0xfffd)!)
            }
            return
        }
        if byte & 0xe0 == 0xc0 {
            utfBuffer = [byte]
            utfExpected = 2
        } else if byte & 0xf0 == 0xe0 {
            utfBuffer = [byte]
            utfExpected = 3
        } else if byte & 0xf8 == 0xf0 {
            utfBuffer = [byte]
            utfExpected = 4
        } else {
            utfBuffer.removeAll()
            emit(Unicode.Scalar(0xfffd)!)
        }
    }

    private static let asciiGlyphs: [String] = (0..<128).map { String(Unicode.Scalar(UInt32($0))!) }

    private mutating func emit(_ scalar: Unicode.Scalar) {
        let width = Self.columnWidth(scalar)
        if width == 1, scalar.value < 128 {
            put(Self.asciiGlyphs[Int(scalar.value)], width: 1)
        } else {
            put(String(scalar), width: width)
        }
    }

    private static func columnWidth(_ scalar: Unicode.Scalar) -> Int {
        if scalar.value == 0x200d || scalar.value == 0xfe0e || scalar.value == 0xfe0f { return 0 }
        if scalar.properties.canonicalCombiningClass != .notReordered { return 0 }
        if scalar.properties.isEmojiPresentation { return 2 }
        switch scalar.value {
        case 0x1100...0x115f, 0x2329...0x232a, 0x2e80...0xa4cf, 0xac00...0xd7a3,
             0xf900...0xfaff, 0xfe10...0xfe19, 0xfe30...0xfe6f, 0xff00...0xff60,
             0xffe0...0xffe6, 0x1f300...0x1f64f, 0x1f900...0x1f9ff, 0x20000...0x3fffd:
            return 2
        default:
            return 1
        }
    }

    private mutating func finishOSC() {
        let text = String(decoding: osc, as: UTF8.self)
        osc.removeAll(keepingCapacity: true)
        let parts = text.split(separator: ";", maxSplits: 2, omittingEmptySubsequences: false)
        guard let code = parts.first else { return }
        if code == "0" || code == "2" {
            let titleParts = text.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)
            title = titleParts.count > 1 ? String(titleParts[1]) : ""
            return
        }
        guard code == "8" else { return }
        let uri = parts.count > 2 ? String(parts[2]) : ""
        setActiveLink(uri)
    }

    private mutating func setActiveLink(_ uri: String) {
        let trimmed = uri.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            activeLinkID = 0
            return
        }
        if let existing = idsByLink[trimmed] {
            activeLinkID = existing
            return
        }
        let id = nextLinkID
        nextLinkID &+= 1
        if nextLinkID == 0 { nextLinkID = 1 }
        links[id] = trimmed
        idsByLink[trimmed] = id
        activeLinkID = id
    }

    private mutating func restoreCursor() {
        guard let saved = savedCursor else { return }
        cursorRow = min(saved.row, rows - 1)
        cursorColumn = min(saved.column, columns)
        pen = saved.pen
        activeLinkID = saved.linkID
        wrapPending = false
    }

    private mutating func resetScreen() {
        let columns = self.columns
        let rows = self.rows
        self = VTScreen(columns: columns, rows: rows)
    }

    private mutating func resetCSI() {
        privateMarker = 0
        params.removeAll(keepingCapacity: true)
        param = 0
        paramSeen = false
    }

    private func rowSlice(_ row: Int) -> [VTCell] {
        let start = row * columns
        return Array(cells[start..<(start + columns)])
    }

    private func lineText(_ line: [VTCell]) -> String {
        var text = ""
        var column = 0
        while column < line.count {
            let cell = line[column]
            if cell.width == 0 {
                column += 1
                continue
            }
            text.append(cell.grapheme.isEmpty ? " " : cell.grapheme)
            column += max(cell.width, 1)
        }
        return trimmingTrailingSpaces(text)
    }

    private mutating func archiveRow(_ row: Int) {
        scrollback.append(rowSlice(row))
        scrollStamp.append(row < rowStamp.count ? rowStamp[row] : 0)
        if scrollback.count > 2_000 {
            let extra = scrollback.count - 2_000
            scrollback.removeFirst(extra)
            scrollStamp.removeFirst(min(extra, scrollStamp.count))
        }
    }

    private func trimmingTrailingSpaces(_ text: String) -> String {
        var end = text.endIndex
        while end > text.startIndex {
            let previous = text.index(before: end)
            if text[previous] == " " { end = previous } else { break }
        }
        return String(text[..<end])
    }
}

enum VTBrowserLink {
    private static let trailing = CharacterSet(charactersIn: ".,;:!?)]}'\">")

    /// http and https addresses only. File and other schemes stay on the Mac.
    static func webAddress(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty else { return nil }
        return trimmed
    }

    static func plainAddress(in cells: [VTCell], column: Int) -> String? {
        var characters: [Character] = []
        var columns: [Int] = []
        var cursor = 0
        characters.reserveCapacity(cells.count)
        for cell in cells {
            if cell.width == 0 { continue }
            let glyph = cell.grapheme.isEmpty ? " " : cell.grapheme
            for character in glyph {
                characters.append(character)
                columns.append(cursor)
            }
            cursor += max(cell.width, 1)
        }
        let text = String(characters)
        var index = text.startIndex
        while index < text.endIndex {
            let rest = text[index...]
            let schemeCount: Int
            if rest.prefix(8).lowercased() == "https://" {
                schemeCount = 8
            } else if rest.prefix(7).lowercased() == "http://" {
                schemeCount = 7
            } else {
                index = text.index(after: index)
                continue
            }
            var end = text.index(index, offsetBy: schemeCount)
            while end < text.endIndex, !text[end].isWhitespace, !"<>\"'`".contains(text[end]) {
                end = text.index(after: end)
            }
            var address = String(text[index..<end])
            while let last = address.unicodeScalars.last, trailing.contains(last) {
                address.removeLast()
            }
            let startOffset = text.distance(from: text.startIndex, to: index)
            let endOffset = startOffset + address.count
            if startOffset < columns.count, endOffset > startOffset, endOffset <= columns.count {
                let firstColumn = columns[startOffset]
                let lastColumn = columns[endOffset - 1]
                if column >= firstColumn, column <= lastColumn, let accepted = webAddress(address) {
                    return accepted
                }
            }
            index = end
        }
        return nil
    }
}
