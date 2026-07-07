#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation

// A tiny keyboard-navigable prompt (single/multi select + confirm) for interactive
// `plumekit new`. Raw-mode termios + ANSI; no dependencies. When stdin/stdout aren't
// a TTY (CI, pipes), every prompt returns its default so scaffolding stays headless.
enum Prompt {
    static var isInteractive: Bool {
        isatty(STDIN_FILENO) != 0 && isatty(STDOUT_FILENO) != 0
    }

    enum Key { case up, down, enter, space, escape, other }

    private static func withRawMode<T>(_ body: () -> T) -> T {
        var original = termios()
        tcgetattr(STDIN_FILENO, &original)
        var raw = original
        raw.c_lflag &= ~(tcflag_t(ECHO) | tcflag_t(ICANON))
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw)
        defer { tcsetattr(STDIN_FILENO, TCSAFLUSH, &original) }
        return body()
    }

    private static func readKey() -> Key {
        var buf = [UInt8](repeating: 0, count: 3)
        let n = read(STDIN_FILENO, &buf, 3)
        if n <= 0 { return .other }
        if buf[0] == 0x1B {                                  // ESC
            if n >= 3, buf[1] == 0x5B {                      // CSI
                if buf[2] == 0x41 { return .up }
                if buf[2] == 0x42 { return .down }
            }
            return .escape
        }
        switch buf[0] {
        case 0x0A, 0x0D: return .enter
        case 0x20:       return .space
        case 0x03, 0x71: return .escape                      // ctrl-c / q
        case 0x6B:       return .up                          // k
        case 0x6A:       return .down                        // j
        default:         return .other
        }
    }

    private static func moveUp(_ n: Int) { if n > 0 { print("\u{1B}[\(n)A", terminator: "") } }

    private static func draw(_ options: [String], current: Int, selected: Set<Int>?) {
        for (i, option) in options.enumerated() {
            let active = i == current
            let cursor = active ? Style.boldCyan("❯ ") : "  "
            var box = ""
            if let selected {
                box = selected.contains(i) ? Style.green("[x] ") : Style.dim("[ ] ")
            }
            let label = active ? Style.bold(option) : option
            // clear the line, draw, newline
            print("\u{1B}[2K\r\(cursor)\(box)\(label)")
        }
        FileHandle.standardOutput.synchronizeFile()
    }

    /// Single choice. Returns the chosen index, or `initial` when non-interactive.
    static func select(_ title: String, _ options: [String], initial: Int = 0) -> Int {
        guard isInteractive, !options.isEmpty else { return initial }
        print(title + "  \u{1B}[2m(↑/↓, enter)\u{1B}[0m")
        var current = min(max(initial, 0), options.count - 1)
        draw(options, current: current, selected: nil)
        return withRawMode {
            while true {
                switch readKey() {
                case .up:    current = (current - 1 + options.count) % options.count
                case .down:  current = (current + 1) % options.count
                case .enter: return current
                case .escape: return initial
                default: continue
                }
                moveUp(options.count)
                draw(options, current: current, selected: nil)
            }
        }
    }

    /// Multiple choice. Returns the chosen indices, or `preselected` when non-interactive.
    static func multiselect(_ title: String, _ options: [String], preselected: Set<Int> = []) -> Set<Int> {
        guard isInteractive, !options.isEmpty else { return preselected }
        print(title + "  \u{1B}[2m(↑/↓, space toggles, enter)\u{1B}[0m")
        var current = 0
        var selected = preselected
        draw(options, current: current, selected: selected)
        return withRawMode {
            while true {
                switch readKey() {
                case .up:    current = (current - 1 + options.count) % options.count
                case .down:  current = (current + 1) % options.count
                case .space: if selected.contains(current) { selected.remove(current) } else { selected.insert(current) }
                case .enter: return selected
                case .escape: return preselected
                default: continue
                }
                moveUp(options.count)
                draw(options, current: current, selected: selected)
            }
        }
    }

    /// Yes/no. Returns `default` when non-interactive.
    static func confirm(_ title: String, default def: Bool = true) -> Bool {
        guard isInteractive else { return def }
        return select(title, ["Yes", "No"], initial: def ? 0 : 1) == 0
    }
}
