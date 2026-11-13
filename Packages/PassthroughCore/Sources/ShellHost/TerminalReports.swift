#if os(macOS)
import Foundation

/// What a terminal sends a shell by itself, not because anyone pressed a key:
/// its answers to a program's questions (where the cursor is, what it is,
/// its colours and size, which modes are on), and focus in and out.
///
/// A session shown in two terminals at once (a phone and a window on the
/// Mac) gets these from both. Only the terminal the session follows should
/// answer, or the program reads the second answer as typing (`^[[24;1R` at
/// the prompt); and none of them is a sign that someone took over the
/// keyboard (`ShellSessionManager.input`).
enum TerminalReports {
    /// `data` without the reports in it, whole ones only: anything cut off
    /// or not known is left, as typing.
    static func removing(from data: Data) -> Data {
        guard data.contains(0x1B) else { return data }   // typing, as nearly all of it is
        let bytes = [UInt8](data)
        var kept = Data()
        kept.reserveCapacity(bytes.count)
        var index = 0
        while index < bytes.count {
            if bytes[index] == 0x1B, let end = report(in: bytes, at: index) {
                index = end
            } else {
                kept.append(bytes[index])
                index += 1
            }
        }
        return kept
    }

    /// Where the report that starts at `start` (an ESC) ends, or nil when none does.
    private static func report(in bytes: [UInt8], at start: Int) -> Int? {
        guard start + 1 < bytes.count else { return nil }
        switch bytes[start + 1] {
        case UInt8(ascii: "["):
            return controlSequence(in: bytes, at: start)
        case UInt8(ascii: "]"), UInt8(ascii: "P"), UInt8(ascii: "_"):
            // OSC (colours, the title, the clipboard), DCS (settings, the
            // version, termcap) and APC (images): a key never sends one.
            return stringEnd(in: bytes, from: start + 2)
        default:
            return nil
        }
    }

    /// `ESC [ params intermediates final`, when it is one a terminal reports with.
    private static func controlSequence(in bytes: [UInt8], at start: Int) -> Int? {
        var index = start + 2
        let paramsStart = index
        while index < bytes.count, (0x30...0x3F).contains(bytes[index]) { index += 1 }
        let params = bytes[paramsStart..<index]
        let interStart = index
        while index < bytes.count, (0x20...0x2F).contains(bytes[index]) { index += 1 }
        let intermediates = bytes[interStart..<index]
        guard index < bytes.count, (0x40...0x7E).contains(bytes[index]) else { return nil }
        let final = bytes[index]
        let first = params.first
        let isReport: Bool
        switch final {
        case UInt8(ascii: "R"):
            // The cursor's place: `row ; column`. (Ctrl-F3 looks the same in some terminals.)
            isReport = intermediates.isEmpty && params.contains(UInt8(ascii: ";"))
        case UInt8(ascii: "c"):
            // What the terminal is (primary, secondary, tertiary attributes).
            isReport = intermediates.isEmpty && (first == UInt8(ascii: "?") || first == UInt8(ascii: ">") || first == UInt8(ascii: "="))
        case UInt8(ascii: "n"):
            // Status: `0 n` (fine), `3 n`, or a `? … n` private one.
            isReport = intermediates.isEmpty && (Array(params) == [UInt8(ascii: "0")] || Array(params) == [UInt8(ascii: "3")] || first == UInt8(ascii: "?"))
        case UInt8(ascii: "y"):
            // Whether a mode is set (`… $ y`).
            isReport = Array(intermediates) == [UInt8(ascii: "$")]
        case UInt8(ascii: "u"):
            // The keyboard protocol in use (`? flags u`).
            isReport = intermediates.isEmpty && first == UInt8(ascii: "?")
        case UInt8(ascii: "t"):
            // The window's size, place or state.
            isReport = intermediates.isEmpty && !params.isEmpty
        case UInt8(ascii: "I"), UInt8(ascii: "O"):
            // Focus in and out.
            isReport = params.isEmpty && intermediates.isEmpty
        default:
            isReport = false
        }
        return isReport ? index + 1 : nil
    }

    /// Past the BEL or `ESC \` that ends a string sequence; nil when it isn't ended yet.
    private static func stringEnd(in bytes: [UInt8], from start: Int) -> Int? {
        var index = start
        while index < bytes.count {
            if bytes[index] == 0x07 { return index + 1 }
            if bytes[index] == 0x1B {
                return index + 1 < bytes.count && bytes[index + 1] == UInt8(ascii: "\\") ? index + 2 : nil
            }
            index += 1
        }
        return nil
    }
}
#endif
