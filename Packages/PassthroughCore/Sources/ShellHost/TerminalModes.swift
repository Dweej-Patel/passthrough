#if os(macOS)
import Foundation

/// The terminal modes a program has turned on, followed through its output:
/// what a replay that starts partway through a session has to turn on first.
///
/// A full-screen program turns its modes on once, when it starts: the
/// alternate screen, mouse reporting, its keyboard protocol. A long session
/// soon pushes that out of the scrollback (Claude Code's fullscreen mode
/// writes megabytes), and a terminal replayed only the rest draws every one
/// of its frames on the main screen, one after another, from scrolling text.
///
/// Only modes that change what is drawn or what the keys and mouse send are
/// followed. Synchronized output (2026) is not: a replay must never begin
/// holding the screen back.
struct TerminalModes {
    /// 47, 1047 or 1049, whichever turned the alternate screen on.
    private(set) var alternateScreen: Int?
    /// 9, 1000, 1001, 1002 or 1003: one at a time, and turning any of them off turns reporting off.
    private(set) var mouseTracking: Int?
    /// 1005, 1006, 1015 or 1016.
    private(set) var mouseEncoding: Int?
    /// Other modes away from their default, by number (`switches`).
    private(set) var changed: [Int: Bool] = [:]
    /// `ESC =`: the keypad sends application sequences.
    private(set) var applicationKeypad = false
    /// xterm's modifyOtherKeys level (`CSI > 4 ; n m`).
    private(set) var modifyOtherKeys: Int?
    /// The kitty keyboard protocol's flags and stack, kept per screen as terminals keep them.
    private(set) var keyboardMain = Keyboard()
    private(set) var keyboardAlternate = Keyboard()

    struct Keyboard: Equatable {
        var flags = 0
        var stack: [Int] = []
        static let stackLimit = 16
    }

    /// The on/off modes followed, with their defaults: cursor keys (1),
    /// autowrap (7), cursor shown (25), keypad (66), focus reports (1004),
    /// bracketed paste (2004), colour-scheme reports (2031).
    static let switches: [Int: Bool] = [1: false, 7: true, 25: true, 66: false, 1004: false, 2004: false, 2031: false]

    // Parser state: sequences can be split across what is scanned.
    private var state = State.ground
    private var collected: [UInt8] = []
    private enum State: Equatable { case ground, escape, csi, ignoring }
    /// Longer parameter strings are not modes; they're skipped.
    private static let collectLimit = 64

    var isAlternateScreen: Bool { alternateScreen != nil }

    mutating func scan(_ bytes: Data) {
        var index = bytes.startIndex
        while index < bytes.endIndex {
            // Nearly all output is text: in it, only an escape can change a mode.
            if state == .ground {
                guard let escape = bytes[index...].firstIndex(of: 0x1B) else { return }
                index = escape
            }
            step(bytes[index])
            index += 1
        }
    }

    func scanned(_ bytes: Data) -> TerminalModes {
        var copy = self
        copy.scan(bytes)
        return copy
    }

    /// What turns a terminal just reset into one in these modes (empty when
    /// nothing is on). The main screen's keyboard flags come before the
    /// switch to the alternate screen, its own after.
    var restoring: Data {
        var out = ""
        out += Self.restore(keyboardMain)
        if let alternateScreen { out += "\u{1b}[?\(alternateScreen)h" }
        if isAlternateScreen { out += Self.restore(keyboardAlternate) }
        for (mode, on) in changed.sorted(by: { $0.key < $1.key }) { out += "\u{1b}[?\(mode)\(on ? "h" : "l")" }
        if let mouseTracking { out += "\u{1b}[?\(mouseTracking)h" }
        if let mouseEncoding { out += "\u{1b}[?\(mouseEncoding)h" }
        if applicationKeypad { out += "\u{1b}=" }
        if let modifyOtherKeys { out += "\u{1b}[>4;\(modifyOtherKeys)m" }
        return Data(out.utf8)
    }

    /// Sets the flags at the bottom of the stack, then pushes each one above.
    private static func restore(_ keyboard: Keyboard) -> String {
        let levels = keyboard.stack + [keyboard.flags]
        guard levels.contains(where: { $0 != 0 }) else { return "" }
        var out = "\u{1b}[=\(levels[0]);1u"
        for flags in levels.dropFirst() { out += "\u{1b}[>\(flags)u" }
        return out
    }

    // MARK: Parsing

    private mutating func step(_ byte: UInt8) {
        switch state {
        case .ground:
            if byte == 0x1B { state = .escape }
        case .escape:
            switch byte {
            case UInt8(ascii: "["): state = .csi; collected.removeAll(keepingCapacity: true)
            case UInt8(ascii: "="): applicationKeypad = true; state = .ground
            case UInt8(ascii: ">"): applicationKeypad = false; state = .ground
            case UInt8(ascii: "c"): self = TerminalModes(); return   // full reset
            // A string (OSC, DCS, APC…) is read as text: nothing in it but an
            // escape matters, and an escape ends it and begins a sequence, as
            // in the phone's terminal (SwiftTerm), so its sequences count.
            case 0x1B: break
            default: state = .ground
            }
        case .csi, .ignoring:
            switch byte {
            case 0x1B: state = .escape
            case 0x18, 0x1A: state = .ground   // CAN, SUB: the sequence is abandoned
            case 0x20...0x3F:
                if state == .csi {
                    if collected.count < Self.collectLimit { collected.append(byte) } else { state = .ignoring }
                }
            case 0x40...0x7E:
                if state == .csi { dispatch(final: byte) }
                state = .ground
            default: break   // other controls inside a sequence are carried out, not part of it
            }
        }
    }

    private mutating func dispatch(final: UInt8) {
        guard let lead = collected.first else { return }
        let marker: UInt8? = (0x3C...0x3F).contains(lead) ? lead : nil
        let params = (marker == nil ? collected[...] : collected.dropFirst())
            .split(separator: UInt8(ascii: ";"), omittingEmptySubsequences: false)
            .map { Int(String(decoding: $0, as: UTF8.self)) }
        let first = params.first ?? nil
        switch (marker, final) {
        case (UInt8(ascii: "?"), UInt8(ascii: "h")), (UInt8(ascii: "?"), UInt8(ascii: "l")):
            for case let mode? in params { set(mode, final == UInt8(ascii: "h")) }
        case (UInt8(ascii: ">"), UInt8(ascii: "u")):
            updateKeyboard { keyboard in
                if keyboard.stack.count >= Keyboard.stackLimit { keyboard.stack.removeFirst() }
                keyboard.stack.append(keyboard.flags)
                keyboard.flags = first ?? 0
            }
        case (UInt8(ascii: "<"), UInt8(ascii: "u")):
            let count = max(first ?? 1, 1)
            updateKeyboard { keyboard in
                if count > keyboard.stack.count { keyboard = Keyboard(); return }
                for _ in 0..<count { keyboard.flags = keyboard.stack.removeLast() }
            }
        case (UInt8(ascii: "="), UInt8(ascii: "u")):
            let flags = first ?? 0
            let mode = params.count > 1 ? (params[1] ?? 1) : 1
            updateKeyboard { keyboard in
                switch mode {
                case 1: keyboard.flags = flags
                case 2: keyboard.flags |= flags
                case 3: keyboard.flags &= ~flags
                default: break
                }
            }
        case (UInt8(ascii: ">"), UInt8(ascii: "m")):
            guard first == 4 else { return }
            modifyOtherKeys = params.count > 1 ? params[1] : nil
            if modifyOtherKeys == 0 { modifyOtherKeys = nil }
        case (nil, UInt8(ascii: "p")) where collected == [UInt8(ascii: "!")]:
            softReset()   // DECSTR, `CSI ! p`
        default:
            break
        }
    }

    private mutating func set(_ mode: Int, _ on: Bool) {
        switch mode {
        case 47, 1047, 1049:
            alternateScreen = on ? mode : nil
        case 9, 1000, 1001, 1002, 1003:
            mouseTracking = on ? mode : nil
        case 1005, 1006, 1015, 1016:
            if on { mouseEncoding = mode } else if mouseEncoding == mode { mouseEncoding = nil }
        default:
            guard let initial = Self.switches[mode] else { return }
            changed[mode] = on == initial ? nil : on
        }
    }

    private mutating func softReset() {
        changed[1] = nil
        changed[25] = nil
        changed[66] = nil
        applicationKeypad = false
    }

    private mutating func updateKeyboard(_ change: (inout Keyboard) -> Void) {
        if isAlternateScreen { change(&keyboardAlternate) } else { change(&keyboardMain) }
    }
}
#endif
