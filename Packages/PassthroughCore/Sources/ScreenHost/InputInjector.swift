#if os(macOS)
import AppKit
import CoreGraphics
import Foundation
import PassthroughCore

/// What the streamer does with a phone's input: `InputInjector`, or a test's record.
protocol InputSink: AnyObject {
    func pointer(x: UInt16, y: UInt16, buttons: UInt8)
    func scroll(dx: Int16, dy: Int16)
    func key(keysym: UInt32, modifiers: UInt8)
    func text(_ text: String)
    func clipboard(_ text: String)
}

/// A phone's input as the Mac's own events (Accessibility lets the app post
/// them), on the display being streamed.
final class InputInjector: InputSink {
    /// The display in global coordinates (points).
    var display: CGRect
    private let source = CGEventSource(stateID: .hidSystemState)
    private var position: CGPoint
    private var buttons: UInt8 = 0
    /// For double and triple clicks: macOS counts them from this field, not from timing.
    private var lastClick: (time: TimeInterval, point: CGPoint, count: Int)?

    init(display: CGRect) {
        self.display = display
        position = CGPoint(x: display.midX, y: display.midY)
    }

    func pointer(x: UInt16, y: UInt16, buttons new: UInt8) {
        position = CGPoint(x: display.minX + CGFloat(x) / 65535 * (display.width - 1),
                           y: display.minY + CGFloat(y) / 65535 * (display.height - 1))
        let changed = (new ^ buttons) & 0b111
        guard changed != 0 else {
            let type: CGEventType = buttons & 1 != 0 ? .leftMouseDragged : buttons & 4 != 0 ? .rightMouseDragged
                : buttons & 2 != 0 ? .otherMouseDragged : .mouseMoved
            return post(mouse: type, button: buttons & 4 != 0 ? .right : buttons & 2 != 0 ? .center : .left)
        }
        for (bit, button, down, up): (UInt8, CGMouseButton, CGEventType, CGEventType) in [
            (1, .left, .leftMouseDown, .leftMouseUp), (4, .right, .rightMouseDown, .rightMouseUp), (2, .center, .otherMouseDown, .otherMouseUp),
        ] where changed & bit != 0 {
            let pressed = new & bit != 0
            var count = 1
            if bit == 1 {
                if pressed {
                    let now = ProcessInfo.processInfo.systemUptime
                    if let last = lastClick, now - last.time < NSEvent.doubleClickInterval,
                       hypot(position.x - last.point.x, position.y - last.point.y) < 5 {
                        count = last.count + 1
                    }
                    lastClick = (now, position, count)
                } else {
                    count = lastClick?.count ?? 1
                }
            }
            post(mouse: pressed ? down : up, button: button, clicks: count)
        }
        buttons = new & 0b111
    }

    private func post(mouse type: CGEventType, button: CGMouseButton, clicks: Int = 0) {
        guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: position, mouseButton: button) else { return }
        if clicks > 0 { event.setIntegerValueField(.mouseEventClickState, value: Int64(clicks)) }
        event.post(tap: .cghidEventTap)
    }

    func scroll(dx: Int16, dy: Int16) {
        CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2, wheel1: Int32(dy), wheel2: Int32(dx), wheel3: 0)?
            .post(tap: .cghidEventTap)
    }

    func key(keysym: UInt32, modifiers: UInt8) {
        let held = ScreenVideoWire.Modifiers(rawValue: modifiers)
        // Plain typing goes as text, which every keyboard layout gets right.
        if held.subtracting(.shift).isEmpty, Self.printable(keysym), let scalar = Unicode.Scalar(Self.codePoint(keysym)) {
            return text(String(Character(scalar)))
        }
        guard let (code, shifted, extraFlags) = Self.keyCode(keysym) else {
            // A character with modifiers this layout table doesn't know: typed as is. Other keys: nothing.
            if Self.printable(keysym), let scalar = Unicode.Scalar(Self.codePoint(keysym)) { text(String(Character(scalar))) }
            return
        }
        var flags = extraFlags
        if held.contains(.command) { flags.insert(.maskCommand) }
        if held.contains(.shift) || shifted { flags.insert(.maskShift) }
        if held.contains(.option) { flags.insert(.maskAlternate) }
        if held.contains(.control) { flags.insert(.maskControl) }
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else { continue }
            event.flags = flags
            event.post(tap: .cghidEventTap)
        }
    }

    func text(_ text: String) {
        let units = Array(text.utf16)
        // Events carry at most 20 UTF-16 units each.
        for start in stride(from: 0, to: units.count, by: 20) {
            var chunk = Array(units[start..<min(start + 20, units.count)])
            for down in [true, false] {
                guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down) else { continue }
                event.flags = []
                event.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: &chunk)
                event.post(tap: .cghidEventTap)
            }
        }
    }

    /// At once, not on the main queue: the ⌘V that usually follows must find it there.
    func clipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: Keys

    private static func printable(_ keysym: UInt32) -> Bool {
        (0x20...0x7E).contains(keysym) || (0xA0...0xFF).contains(keysym) || keysym >= 0x0100_0000
    }

    private static func codePoint(_ keysym: UInt32) -> UInt32 { keysym >= 0x0100_0000 ? keysym - 0x0100_0000 : keysym }

    /// The ANSI key for a keysym, whether it needs shift, and flags a real keyboard sends with it
    /// (arrows and function keys carry Fn, which Mission Control's shortcuts expect).
    static func keyCode(_ keysym: UInt32) -> (CGKeyCode, shifted: Bool, CGEventFlags)? {
        let fn = CGEventFlags.maskSecondaryFn, pad = CGEventFlags.maskNumericPad
        switch keysym {
        case RFBKeys.returnKey: return (36, false, [])
        case RFBKeys.tab: return (48, false, [])
        case RFBKeys.backspace: return (51, false, [])
        case RFBKeys.escape: return (53, false, [])
        case RFBKeys.delete: return (117, false, fn)
        case RFBKeys.home: return (115, false, fn)
        case RFBKeys.end: return (119, false, fn)
        case RFBKeys.pageUp: return (116, false, fn)
        case RFBKeys.pageDown: return (121, false, fn)
        case RFBKeys.left: return (123, false, [fn, pad])
        case RFBKeys.right: return (124, false, [fn, pad])
        case RFBKeys.down: return (125, false, [fn, pad])
        case RFBKeys.up: return (126, false, [fn, pad])
        case 0xFFBE...0xFFC9:
            let codes: [CGKeyCode] = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111]
            return (codes[Int(keysym - 0xFFBE)], false, fn)
        case 0x20: return (49, false, [])
        default: break
        }
        guard keysym < 0x80, let scalar = Unicode.Scalar(keysym) else { return nil }
        let character = Character(scalar)
        if let code = unshifted[character] { return (code, false, []) }
        if let base = shiftedBase[character], let code = unshifted[base] { return (code, true, []) }
        if character.isUppercase, let code = unshifted[Character(character.lowercased())] { return (code, true, []) }
        return nil
    }

    private static let unshifted: [Character: CGKeyCode] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13,
        "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25,
        "7": 26, "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "l": 37, "j": 38,
        "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46, ".": 47, "`": 50,
    ]

    private static let shiftedBase: [Character: Character] = [
        "!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6", "&": "7", "*": "8", "(": "9", ")": "0",
        "_": "-", "+": "=", "{": "[", "}": "]", "|": "\\", ":": ";", "\"": "'", "<": ",", ">": ".", "?": "/", "~": "`",
    ]
}
#endif
