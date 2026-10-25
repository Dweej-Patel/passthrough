#if os(macOS)
import Foundation

/// Whether a shell that has gone quiet is waiting on a person: a question
/// near the bottom of its output ("Do you want to make this edit?",
/// "Continue? [y/N]", a password prompt). A heuristic over the screen's last
/// lines, never over anything typed; nil means nothing looked like one.
enum ShellQuestion {
    /// How far up from the bottom a question may sit (menus of choices often follow it).
    static let linesLooked = 12
    static let maxLength = 120

    static func find(in tail: Data) -> String? {
        let lines = visibleLines(String(decoding: tail, as: UTF8.self))
        for line in lines.suffix(linesLooked).reversed() where looksAsked(line) {
            return line.count > maxLength ? String(line.prefix(maxLength - 1)) + "…" : line
        }
        return nil
    }

    private static func looksAsked(_ line: String) -> Bool {
        let lower = line.lowercased()
        for choice in ["[y/n]", "(y/n)", "[yes/no]", "(yes/no)"] where lower.contains(choice) { return true }
        if lower.hasSuffix("password:") || lower.hasSuffix("passphrase:") || lower.contains("password for ") { return true }
        // A sentence ending in a question mark, not a lone "?" or a path with one.
        guard line.hasSuffix("?") else { return false }
        return line.split(separator: " ").count >= 2 && line.count >= 8
    }

    /// The text a terminal would show, one line per row: escape sequences
    /// dropped, cursor moves and carriage returns taken as line breaks, box
    /// drawing and selection markers trimmed.
    static func visibleLines(_ text: String) -> [String] {
        var out = ""
        var chars = text.unicodeScalars.makeIterator()
        while let c = chars.next() {
            switch c {
            case "\u{1B}":
                guard let next = chars.next() else { break }
                if next == "[" {
                    // CSI: parameters, then a final byte in @...~.
                    while let p = chars.next() {
                        if (0x40...0x7E).contains(p.value) {
                            // Moves to another row or clears: a new line as far as reading goes.
                            if "HfABEFdJ".unicodeScalars.contains(p) { out.append("\n") }
                            break
                        }
                    }
                } else if next == "]" {
                    // OSC (titles, links): up to BEL or ESC \.
                    while let p = chars.next(), p != "\u{07}" {
                        if p == "\u{1B}" { _ = chars.next(); break }
                    }
                }
            case "\r", "\n":
                out.append("\n")
            default:
                if c.value >= 0x20 { out.unicodeScalars.append(c) }
            }
        }
        let trim = CharacterSet.whitespaces.union(CharacterSet(charactersIn: "│┃║╭╮╰╯─━═┌┐└┘|❯›>•·*"))
        return out.split(separator: "\n").map { $0.trimmingCharacters(in: trim) }.filter { !$0.isEmpty }
    }
}
#endif
