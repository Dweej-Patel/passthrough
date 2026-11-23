import Foundation
import PassthroughCore

/// What a PC is sent for the keysyms the canvas and key row carry (`RFBKeys`):
/// scan codes (set 1, US positions) for keys and for characters typed with
/// Control, Alt or the Windows key; Unicode key events for plain text, so
/// dictation, emoji, accents and every input method work whatever the PC's
/// layout is.
public enum WindowsKeymap {
    public struct Scancode: Equatable, Sendable {
        public var code: UInt8
        public var extended: Bool
        /// The character needs Shift at its US position.
        public var shift: Bool
        public init(_ code: UInt8, extended: Bool = false, shift: Bool = false) {
            self.code = code; self.extended = extended; self.shift = shift
        }
    }

    public static let control = Scancode(0x1D)
    public static let shift = Scancode(0x2A)
    public static let alt = Scancode(0x38)
    public static let windows = Scancode(0x5B, extended: true)
    public static let returnKey = Scancode(0x1C)
    public static let tab = Scancode(0x0F)
    public static let insert = Scancode(0x52, extended: true)

    /// Keys that are not characters.
    static let special: [UInt32: Scancode] = {
        var table: [UInt32: Scancode] = [
            RFBKeys.escape: Scancode(0x01), RFBKeys.tab: tab, RFBKeys.returnKey: returnKey, RFBKeys.backspace: Scancode(0x0E),
            RFBKeys.left: Scancode(0x4B, extended: true), RFBKeys.up: Scancode(0x48, extended: true),
            RFBKeys.right: Scancode(0x4D, extended: true), RFBKeys.down: Scancode(0x50, extended: true),
            RFBKeys.home: Scancode(0x47, extended: true), RFBKeys.end: Scancode(0x4F, extended: true),
            RFBKeys.pageUp: Scancode(0x49, extended: true), RFBKeys.pageDown: Scancode(0x51, extended: true),
            RFBKeys.insert: insert, RFBKeys.delete: Scancode(0x53, extended: true),
            RFBKeys.control: control, RFBKeys.shift: shift, RFBKeys.option: alt, RFBKeys.alt: alt,
            RFBKeys.windows: windows, RFBKeys.printScreen: Scancode(0x37, extended: true),
            // ⌘ from the Mac's key row or a hardware keyboard is Control on a PC.
            RFBKeys.command: control,
        ]
        for number in 1...10 { table[RFBKeys.function(number)] = Scancode(0x3B + UInt8(number - 1)) }
        table[RFBKeys.function(11)] = Scancode(0x57)
        table[RFBKeys.function(12)] = Scancode(0x58)
        return table
    }()

    /// Printable ASCII at its US position: unshifted row, then shifted.
    private static let rows: [(String, String, UInt8)] = [
        ("`1234567890-=", "~!@#$%^&*()_+", 0x29),
        ("qwertyuiop[]", "QWERTYUIOP{}", 0x10),
        ("asdfghjkl;'", "ASDFGHJKL:\"", 0x1E),
        ("zxcvbnm,./", "ZXCVBNM<>?", 0x2C),
    ]

    static let characters: [UInt32: Scancode] = {
        var table: [UInt32: Scancode] = [0x20: Scancode(0x39), 0x5C: Scancode(0x2B), 0x7C: Scancode(0x2B, shift: true)]
        for (plain, shifted, first) in rows {
            // The number row starts at ` (0x29), then 1 (0x02): its codes aren't contiguous with the grave key.
            let codes: [UInt8]
            if first == 0x29 {
                codes = [UInt8(0x29)] + Array(UInt8(0x02)...UInt8(0x0D))
            } else {
                codes = Array(first..<(first + UInt8(plain.count)))
            }
            for (index, character) in plain.unicodeScalars.enumerated() { table[character.value] = Scancode(codes[index]) }
            for (index, character) in shifted.unicodeScalars.enumerated() { table[character.value] = Scancode(codes[index], shift: true) }
        }
        return table
    }()

    /// The scan code for a keysym: a key, or a character at its US position. Nil: no such key.
    public static func scancode(for keysym: UInt32) -> Scancode? {
        if let key = special[keysym] { return key }
        return characters[keysym]
    }

    /// The modifiers' scan codes in press order (release is the reverse): control
    /// (⌘ too), alt, shift, windows.
    public static func modifierScancodes(_ modifiers: ScreenModifiers) -> [Scancode] {
        var keys: [Scancode] = []
        if modifiers.contains(.control) || modifiers.contains(.command) { keys.append(control) }
        if modifiers.contains(.option) { keys.append(alt) }
        if modifiers.contains(.shift) { keys.append(shift) }
        if modifiers.contains(.windows) { keys.append(windows) }
        return keys
    }

    /// One key event for the PC.
    public enum Stroke: Equatable, Sendable {
        case key(Scancode, down: Bool)
        case unicode(UInt16, down: Bool)
    }

    /// What one key with `modifiers` held sends. Plain or shifted characters go
    /// as Unicode; anything with Control, Alt, ⌘ or the Windows key, and every
    /// key that isn't a character, as scan codes, modifiers around it. A
    /// character with no US position under such modifiers is dropped.
    public static func strokes(for keysym: UInt32, modifiers: ScreenModifiers) -> [Stroke] {
        let chording = !modifiers.subtracting(.shift).isEmpty
        if special[keysym] == nil, !chording, let unit = unicodeUnits(for: keysym) {
            return unit.flatMap { [.unicode($0, down: true), .unicode($0, down: false)] }
        }
        guard var key = scancode(for: keysym) else { return [] }
        var held = modifiers
        if key.shift { held.insert(.shift) }
        key.shift = false
        let around = modifierScancodes(held)
        return around.map { .key($0, down: true) } + [.key(key, down: true), .key(key, down: false)]
            + around.reversed().map { .key($0, down: false) }
    }

    /// Typed text: Return and Tab as keys, everything else as Unicode.
    public static func strokes(forText text: String) -> [Stroke] {
        var strokes: [Stroke] = []
        for character in text {
            if character == "\n" || character == "\r" || character == "\r\n" {
                strokes += [.key(returnKey, down: true), .key(returnKey, down: false)]
            } else if character == "\t" {
                strokes += [.key(tab, down: true), .key(tab, down: false)]
            } else {
                for unit in String(character).utf16 { strokes += [.unicode(unit, down: true), .unicode(unit, down: false)] }
            }
        }
        return strokes
    }

    /// A keysym's character as UTF-16 (Latin-1 keysyms are the character; 0x01000000 + code point otherwise).
    static func unicodeUnits(for keysym: UInt32) -> [UInt16]? {
        let value: UInt32
        if (0x20...0x7E).contains(keysym) || (0xA0...0xFF).contains(keysym) {
            value = keysym
        } else if keysym >= 0x0100_0000, keysym <= 0x0110_FFFF {
            value = keysym - 0x0100_0000
        } else {
            return nil
        }
        guard let scalar = Unicode.Scalar(value) else { return nil }
        return Array(String(Character(scalar)).utf16)
    }
}
