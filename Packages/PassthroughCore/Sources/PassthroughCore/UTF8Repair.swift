import Foundation

/// Makes a terminal's byte stream valid UTF-8 before it reaches the terminal
/// view: every byte that isn't part of a well-formed sequence becomes U+FFFD.
///
/// A shell counts each such byte as one column (zsh, measuring its prompt),
/// and so does a desktop terminal, which draws a replacement mark for it.
/// SwiftTerm draws nothing, so the two disagree about where the cursor is: a
/// prompt with a stray byte in it is redrawn over the wrong cells, and the
/// cursor lands at the start of the line. One replacement per byte keeps the
/// widths equal.
///
/// Output arrives in chunks that can split a character, so an unfinished
/// sequence at the end of a chunk is held for the next one.
public struct UTF8Repair {
    private var held: [UInt8] = []
    private static let replacement: [UInt8] = [0xEF, 0xBF, 0xBD]

    public init() {}

    /// Forgets a held partial character (a new stream begins).
    public mutating func reset() { held.removeAll() }

    public mutating func repair(_ data: Data) -> [UInt8] {
        // Nearly all output is ASCII, with nothing held: pass it straight on.
        if held.isEmpty, !data.contains(where: { $0 >= 0x80 }) { return [UInt8](data) }
        let bytes = held + data
        held.removeAll(keepingCapacity: true)
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count + 8)
        var i = 0
        while i < bytes.count {
            let lead = bytes[i]
            if lead < 0x80 { out.append(lead); i += 1; continue }
            // The sequence's length and the range its second byte must be in
            // (which rules out overlong forms, surrogates and past U+10FFFF).
            let length: Int, second: ClosedRange<UInt8>
            switch lead {
            case 0xC2...0xDF: length = 2; second = 0x80...0xBF
            case 0xE0: length = 3; second = 0xA0...0xBF
            case 0xE1...0xEC, 0xEE...0xEF: length = 3; second = 0x80...0xBF
            case 0xED: length = 3; second = 0x80...0x9F
            case 0xF0: length = 4; second = 0x90...0xBF
            case 0xF1...0xF3: length = 4; second = 0x80...0xBF
            case 0xF4: length = 4; second = 0x80...0x8F
            default: out += Self.replacement; i += 1; continue
            }
            var valid = 1
            while valid < length, i + valid < bytes.count,
                  (valid == 1 ? second : 0x80...0xBF).contains(bytes[i + valid]) { valid += 1 }
            if valid == length {
                out += bytes[i..<(i + length)]
                i += length
            } else if i + valid == bytes.count {
                // Well-formed so far, and the chunk ended: the rest may follow.
                held = Array(bytes[i...])
                break
            } else {
                // Only the lead byte is replaced: what follows is judged by itself.
                out += Self.replacement
                i += 1
            }
        }
        return out
    }
}
