import Foundation

public enum TerminalSyntax {
    /// True when the line uses shell syntax the virtual commands do not parse.
    public static func requiresShell(_ line: String) -> Bool {
        var quote: Character?
        var previous: Character?
        for character in line {
            if let active = quote {
                if character == active { quote = nil }
                previous = character
                continue
            }
            if character == "\"" || character == "'" {
                quote = character
                previous = character
                continue
            }
            if "|><;&`$".contains(character) { return true }
            if character == "&", previous == "&" { return true }
            previous = character
        }
        return false
    }
}
