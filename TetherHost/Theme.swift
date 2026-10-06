import SwiftUI

struct TetherColors {
    let accent = Color("accent")
    let accentText = Color("accentText")
    let success = Color("success")
    let warning = Color("warning")
    let danger = Color("danger")
}

struct TerminalTheme {
    let bg = Color("termBg")
    let fg = Color("termFg")
    let dim = Color("termDim")
    let prompt = Color("termPrompt")
    let dir = Color("termDir")
    let file = Color("termFile")
    let exec = Color("termExec")
    let error = Color("termError")
}

extension Color {
    static let tether = TetherColors()
}

extension TerminalTheme {
    static let standard = TerminalTheme()
}

enum TetherType {
    static let hero = Font.largeTitle
    static let title = Font.title2
    static let section = Font.headline
    static let body = Font.body
    static let secondary = Font.subheadline
    static let meta = Font.caption
    static let footnote = Font.footnote
    static let code = Font.system(.title3, design: .monospaced)
}

enum TetherMotion {
    static func spring(_ reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeOut(duration: 0.2) : .spring(duration: 0.35, bounce: 0.15)
    }

    static func fade(_ reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeOut(duration: 0.12) : .spring(duration: 0.28, bounce: 0)
    }
}
