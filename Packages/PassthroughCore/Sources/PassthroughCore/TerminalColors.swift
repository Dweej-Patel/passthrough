import Foundation
#if os(macOS)
import Darwin
#endif

/// The colours a terminal window on the Mac draws with, so a phone can draw
/// the same session the same way: `#rrggbb` each. A program's output only
/// names colours ("blue", "the default background"); the shades are the
/// terminal's own, and every terminal has different ones.
public struct ShellTheme: Codable, Equatable, Sendable {
    public var foreground: String?
    public var background: String?
    /// The 16 ANSI colours, in order; absent unless all 16 are known.
    public var palette: [String]?

    public init(foreground: String? = nil, background: String? = nil, palette: [String]? = nil) {
        self.foreground = foreground; self.background = background; self.palette = palette
    }

    /// Red, green and blue (0...255) of a `#rrggbb` colour; nil for anything else.
    public static func rgb(_ text: String) -> (red: UInt8, green: UInt8, blue: UInt8)? {
        let bytes = Array(text.utf8)
        guard bytes.count == 7, bytes[0] == UInt8(ascii: "#"), let value = UInt32(text.dropFirst(), radix: 16) else { return nil }
        return (UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF))
    }

    /// Only what is well formed, as nobody should trust a colour they were
    /// sent; nil when nothing is left.
    public var sanitized: ShellTheme? {
        func valid(_ text: String?) -> String? { text.flatMap { Self.rgb($0) == nil ? nil : $0.lowercased() } }
        var palette = palette?.compactMap { valid($0) }
        if palette?.count != 16 { palette = nil }
        let theme = ShellTheme(foreground: valid(foreground), background: valid(background), palette: palette)
        return theme.foreground == nil && theme.background == nil && theme.palette == nil ? nil : theme
    }
}

/// Asking a terminal for its colours (xterm's OSC 10, 11 and 4 queries) and
/// reading what it says.
public enum TerminalColors {
    /// Text, background and the 16 ANSI colours, then the terminal's device
    /// attributes: every terminal answers that last one, so its answer marks
    /// the end whether or not the colours were answered.
    public static let question: Data = {
        var text = "\u{1B}]10;?\u{1B}\\\u{1B}]11;?\u{1B}\\"
        for index in 0..<16 { text += "\u{1B}]4;\(index);?\u{1B}\\" }
        return Data((text + "\u{1B}[c").utf8)
    }()

    /// Whether `answer` has reached the device attributes' reply (`ESC [ ? … c`).
    public static func isComplete(_ answer: Data) -> Bool {
        guard let start = answer.range(of: Data("\u{1B}[?".utf8)) else { return false }
        return answer[start.upperBound...].contains(UInt8(ascii: "c"))
    }

    /// The colours in a terminal's answer; nil when it gave none.
    public static func parse(_ answer: Data) -> ShellTheme? {
        var theme = ShellTheme()
        var palette = [String?](repeating: nil, count: 16)
        // Each reply is `ESC ] code ; … ` ended by BEL or `ESC \`.
        let text = String(decoding: answer, as: UTF8.self)
        for piece in text.components(separatedBy: "\u{1B}]").dropFirst() {
            let body = piece.prefix { $0 != "\u{07}" && $0 != "\u{1B}" }
            let fields = body.split(separator: ";", omittingEmptySubsequences: false).map(String.init)
            switch fields.first {
            case "10" where fields.count == 2: theme.foreground = colour(fields[1])
            case "11" where fields.count == 2: theme.background = colour(fields[1])
            case "4" where fields.count == 3:
                if let index = Int(fields[1]), palette.indices.contains(index) { palette[index] = colour(fields[2]) }
            default: break
            }
        }
        let known = palette.compactMap { $0 }
        if known.count == 16 { theme.palette = known }
        return theme.sanitized
    }

    /// `rgb:RRRR/GGGG/BBBB` (one to four hex digits each) as `#rrggbb`.
    static func colour(_ text: String) -> String? {
        guard text.hasPrefix("rgb:") else { return nil }
        let parts = text.dropFirst(4).split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var hex = "#"
        for part in parts {
            guard (1...4).contains(part.count), let value = UInt32(part, radix: 16) else { return nil }
            // Scaled to eight bits whatever the digits: f, ff, fff and ffff are all full.
            let full = UInt32(1) << (4 * UInt32(part.count)) - 1
            let eight = (value * 255 + full / 2) / full
            hex += String(format: "%02x", eight)
        }
        return hex
    }

    #if os(macOS)
    /// Asks the terminal on `output` and reads its answer from `input`, which
    /// must be in raw mode (the answer is not a line, and must not be echoed).
    /// Gives up after `timeout`: a terminal that says nothing has no colours to give.
    public static func ask(input: Int32, output: Int32, timeout: TimeInterval) -> ShellTheme? {
        guard timeout > 0 else { return nil }
        let sent = question.withUnsafeBytes { write(output, $0.baseAddress, question.count) }
        guard sent == question.count else { return nil }
        var answer = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        let deadline = Date().addingTimeInterval(timeout)
        while !isComplete(answer), answer.count < 16_384 {
            let left = deadline.timeIntervalSinceNow
            guard left > 0 else { break }
            var p = pollfd(fd: input, events: Int16(POLLIN), revents: 0)
            let ready = poll(&p, 1, Int32(max(1, left * 1000)))
            if ready < 0, errno == EINTR { continue }
            guard ready > 0 else { break }
            let n = read(input, &buffer, buffer.count)
            guard n > 0 else { break }
            answer.append(contentsOf: buffer[0..<n])
        }
        return parse(answer)
    }
    #endif
}
