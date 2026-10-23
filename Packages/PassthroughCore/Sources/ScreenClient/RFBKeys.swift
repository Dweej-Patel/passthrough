import Foundation

/// X keysyms, as RFB key events carry them, for what a phone types. macOS
/// Screen Sharing takes Command as Hyper and Option as Meta.
public enum RFBKeys {
    public static let backspace: UInt32 = 0xFF08
    public static let tab: UInt32 = 0xFF09
    public static let returnKey: UInt32 = 0xFF0D
    public static let escape: UInt32 = 0xFF1B
    public static let delete: UInt32 = 0xFFFF
    public static let home: UInt32 = 0xFF50
    public static let left: UInt32 = 0xFF51
    public static let up: UInt32 = 0xFF52
    public static let right: UInt32 = 0xFF53
    public static let down: UInt32 = 0xFF54
    public static let pageUp: UInt32 = 0xFF55
    public static let pageDown: UInt32 = 0xFF56
    public static let end: UInt32 = 0xFF57
    public static let shift: UInt32 = 0xFFE1
    public static let control: UInt32 = 0xFFE3
    public static let option: UInt32 = 0xFFE7    // Meta_L
    public static let command: UInt32 = 0xFFED   // Hyper_L

    /// F1…F12.
    public static func function(_ number: Int) -> UInt32 { 0xFFBE + UInt32(max(1, min(number, 12)) - 1) }

    /// The keysym for one typed character: Latin-1 as itself, newline and tab
    /// as their keys, anything else as a Unicode keysym.
    public static func keysym(for character: Character) -> UInt32? {
        if character == "\n" || character == "\r" { return returnKey }
        if character == "\t" { return tab }
        guard let scalar = character.unicodeScalars.first, character.unicodeScalars.count == 1 else { return nil }
        let value = scalar.value
        if (0x20...0x7E).contains(value) || (0xA0...0xFF).contains(value) { return value }
        return 0x0100_0000 + value
    }
}
