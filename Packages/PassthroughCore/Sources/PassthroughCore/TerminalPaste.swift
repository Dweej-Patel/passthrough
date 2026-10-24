import Foundation

/// Text pasted into a shell, made safe to send. Like xterm and Termux, it
/// drops escape characters and C1 controls, so a paste can neither end a
/// bracketed paste early nor send terminal commands of its own; the other
/// control characters (^C, ^D, backspace…) go too, so it can't press keys,
/// tabs aside. Line breaks (NEL and the Unicode line and paragraph
/// separators among them) are sent as \n to a program that asked for
/// bracketed paste, and as Return to one that didn't (as Ghostty does).
public struct TerminalPaste: Equatable, Sendable {
    /// What is pasted, with every line break as \n.
    public let text: String

    public init(_ raw: String) {
        var out = String.UnicodeScalarView()
        var afterReturn = false
        for scalar in raw.unicodeScalars {
            switch scalar.value {
            case 0x0A where afterReturn:
                afterReturn = false   // \r\n is one line break, whatever was dropped between
            case 0x0D, 0x0A, 0x85, 0x2028, 0x2029:   // CR, LF, NEL, line and paragraph separators
                out.append("\n")
                afterReturn = scalar.value == 0x0D
            case 0x00...0x1F where scalar.value != 0x09, 0x7F, 0x80...0x9F:
                continue
            default:
                out.append(scalar)
                afterReturn = false
            }
        }
        text = String(out)
    }

    /// Line breaks in it: lines a shell runs as they arrive when the program
    /// hasn't turned on bracketed paste.
    public var lineBreaks: Int { text.unicodeScalars.reduce(0) { $0 + ($1 == "\n" ? 1 : 0) } }

    /// The bytes to send: between the bracketed-paste markers when the
    /// program asked for them, otherwise with each line break as Return.
    public func bytes(bracketed: Bool) -> [UInt8] {
        let utf8 = Array(text.utf8)
        return bracketed ? Self.bracketStart + utf8 + Self.bracketEnd : utf8.map { $0 == 0x0A ? 0x0D : $0 }
    }

    static let bracketStart: [UInt8] = Array("\u{1B}[200~".utf8)
    static let bracketEnd: [UInt8] = Array("\u{1B}[201~".utf8)
}
