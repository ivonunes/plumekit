#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation

// ANSI styling for CLI output. Colors are applied only when stdout is a real
// terminal and the user hasn't opted out (the conventional NO_COLOR env var, or
// TERM=dumb), so piped/CI output stays clean plain text.
enum Style {
    static let enabled: Bool = {
        if ProcessInfo.processInfo.environment["NO_COLOR"] != nil { return false }
        if ProcessInfo.processInfo.environment["TERM"] == "dumb" { return false }
        return isatty(STDOUT_FILENO) != 0
    }()

    private static func wrap(_ text: String, _ code: String) -> String {
        enabled ? "\u{1B}[\(code)m\(text)\u{1B}[0m" : text
    }

    static func bold(_ s: String) -> String { wrap(s, "1") }
    static func dim(_ s: String) -> String { wrap(s, "2") }
    static func red(_ s: String) -> String { wrap(s, "31") }
    static func green(_ s: String) -> String { wrap(s, "32") }
    static func yellow(_ s: String) -> String { wrap(s, "33") }
    static func blue(_ s: String) -> String { wrap(s, "34") }
    static func cyan(_ s: String) -> String { wrap(s, "36") }
    static func boldCyan(_ s: String) -> String { wrap(s, "1;36") }
}
