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
