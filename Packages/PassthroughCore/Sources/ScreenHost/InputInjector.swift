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
    /// The Fn (globe) key down, or up.
    func function(_ down: Bool)
    /// A trackpad pinch or rotation, at the pointer.
    func gesture(_ gesture: ScreenVideoWire.Gesture, phase: ScreenVideoWire.GesturePhase, value: Double)
    /// The phone is gone: lets go of every button it holds and ends its gestures.
    func releaseAll()
    /// How many times the Mac's clipboard has changed (`NSPasteboard.changeCount`).
    var clipboardChangeCount: Int { get }
    /// What's on the Mac's clipboard now. May block: an app that provides
    /// its data lazily is asked for it.
    func clipboardContents() -> ClipboardContents
}

/// What's on the Mac's clipboard, as a `copy` sees it.
enum ClipboardContents: Equatable {
    case text(String)
    case notText
    /// Not copied on this Mac: from another device (Universal Clipboard), or what a phone pasted.
    case elsewhere
}

/// A phone's input as the Mac's own events (Accessibility lets the app post
/// them), on the display being streamed.
final class InputInjector: InputSink {
    /// The display in global coordinates (points).
    var display: CGRect
    /// Where its events come from. By default macOS ignores the Mac's own keyboard and
    /// trackpad for 0.25 s after each event from a source like this, and for as long as
    /// a button it pressed is down: someone at the Mac couldn't type while a phone moved
    /// the pointer, scrolled or pinched, and not at all after a phone left mid-drag.
    /// So it holds back nothing of theirs.
    let source: CGEventSource? = {
        let source = CGEventSource(stateID: .hidSystemState)
        source?.localEventsSuppressionInterval = 0
        let everything: CGEventFilterMask = [.permitLocalMouseEvents, .permitLocalKeyboardEvents, .permitSystemDefinedEvents]
        source?.setLocalEventsFilterDuringSuppressionState(everything, state: .eventSuppressionStateSuppressionInterval)
        source?.setLocalEventsFilterDuringSuppressionState(everything, state: .eventSuppressionStateRemoteMouseDrag)
        return source
    }()
    private var position: CGPoint
    /// The number of the press under way (or last); starts somewhere new each time, so it
    /// doesn't repeat one an earlier stream used.
    private var eventNumber = Int64.random(in: 10_000...1_000_000)
    /// Movement not yet reported in an event's deltas.
    private var travel = CGPoint.zero
    private var buttons: UInt8 = 0
    /// Gestures begun and not yet ended.
    private var gestures: Set<ScreenVideoWire.Gesture> = []
    /// For double and triple clicks: macOS counts them from this field, not from timing.
    private var lastClick: (time: TimeInterval, point: CGPoint, count: Int)?

    init(display: CGRect) {
        self.display = display
        position = CGPoint(x: display.midX, y: display.midY)
    }

    func pointer(x: UInt16, y: UInt16, buttons new: UInt8) {
        let before = position
        position = CGPoint(x: display.minX + CGFloat(x) / 65535 * (display.width - 1),
                           y: display.minY + CGFloat(y) / 65535 * (display.height - 1))
        travel.x += position.x - before.x
        travel.y += position.y - before.y
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
        // The source's flags would otherwise come along: a ⌃ still held there makes a click a right-click.
        event.flags = []
        if clicks > 0 { event.setIntegerValueField(.mouseEventClickState, value: Int64(clicks)) }
        // How far it moved since the last event, as a real mouse says: apps that move their own
        // window (a custom title bar) or track drags by it get nothing from the position alone.
        let dx = travel.x.rounded(.towardZero), dy = travel.y.rounded(.towardZero)
        travel.x -= dx
        travel.y -= dy
        // Each press has its own number, on it, its drags and its release, as a real mouse's
        // has. With none (0), a window that once got a press without its release (a phone
        // gone mid-drag) took every later press for that same one and ignored it.
        if type == .leftMouseDown || type == .rightMouseDown || type == .otherMouseDown { eventNumber &+= 1 }
        if type != .mouseMoved { event.setIntegerValueField(.mouseEventNumber, value: eventNumber) }
        event.setIntegerValueField(.mouseEventDeltaX, value: Int64(dx))
        event.setIntegerValueField(.mouseEventDeltaY, value: Int64(dy))
        event.post(tap: .cghidEventTap)
    }

    func scroll(dx: Int16, dy: Int16) {
        guard let event = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2, wheel1: Int32(dy), wheel2: Int32(dx), wheel3: 0)
        else { return }
        event.flags = []
        event.post(tap: .cghidEventTap)
    }

    /// A trackpad gesture as macOS's own: there's no public API for these, so
    /// they're CoreGraphics' undocumented gesture events (as Mac Mouse Fix posts
    /// them), which AppKit turns into `magnify(with:)` and `rotate(with:)` for the
    /// window under the pointer. Checked on macOS 27: phases and sums arrive intact.
    func gesture(_ gesture: ScreenVideoWire.Gesture, phase: ScreenVideoWire.GesturePhase, value: Double) {
        switch phase {
        case .began: gestures.insert(gesture)
        case .ended, .cancelled: gestures.remove(gesture)
        case .changed: break
        }
        guard let event = CGEvent(source: source) else { return }
        event.setIntegerValueField(Self.eventTypeField, value: 29)   // kCGSEventGesture
        event.setIntegerValueField(Self.gestureTypeField, value: gesture == .magnify ? 8 : 5)   // kIOHIDEventTypeZoom, …Rotation
        event.setIntegerValueField(Self.gesturePhaseField, value: Int64(phase.rawValue))
        event.setDoubleValueField(gesture == .magnify ? Self.zoomField : Self.rotationField, value: value)
        // Where the pointer really is: the Mac's own trackpad may have moved it since the phone did.
        event.location = CGEvent(source: nil)?.location ?? position
        event.flags = []
        event.post(tap: .cghidEventTap)
    }

    /// The Fn key as a keyboard sends it: a "modifiers changed" event of its own, down until it's let go.
    func function(_ down: Bool) {
        guard down != functionDown else { return }
        functionDown = down
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: 63, keyDown: down) else { return }
        event.type = .flagsChanged
        event.flags = down ? [.maskSecondaryFn, .maskNonCoalesced] : .maskNonCoalesced
        event.post(tap: .cghidEventTap)
    }
    private var functionDown = false

    func releaseAll() {
        function(false)
        for gesture in gestures { self.gesture(gesture, phase: .cancelled, value: 0) }
        if buttons & 0b111 != 0 {
            pointer(x: UInt16(clamping: Int(((position.x - display.minX) / max(display.width - 1, 1) * 65535).rounded())),
                    y: UInt16(clamping: Int(((position.y - display.minY) / max(display.height - 1, 1) * 65535).rounded())), buttons: 0)
        }
    }

    private static let eventTypeField = CGEventField(rawValue: 55)!       // kCGSEventTypeField
    private static let gestureTypeField = CGEventField(rawValue: 110)!    // kCGEventGestureHIDType
    private static let zoomField = CGEventField(rawValue: 113)!           // kCGEventGestureZoomValue
    private static let rotationField = CGEventField(rawValue: 114)!       // kCGEventGestureRotationValue
    private static let gesturePhaseField = CGEventField(rawValue: 132)!   // kCGEventGesturePhase

    func key(keysym: UInt32, modifiers: UInt8) {
        let held = ScreenVideoWire.Modifiers(rawValue: modifiers)
        // Plain typing goes as text, which every keyboard layout gets right.
        if held.subtracting(.shift).isEmpty, Self.printable(keysym), let scalar = Unicode.Scalar(Self.codePoint(keysym)) {
            return text(String(Character(scalar)))
        }
        // The key that types it on this layout, as it is with ⌘ held for a ⌘ shortcut (on
        // AZERTY, A is where Q is on ANSI: that table's ⌘A would be ⌘Q). The ANSI table otherwise.
        let character = Self.printable(keysym) ? Unicode.Scalar(Self.codePoint(keysym)).map(Character.init) : nil
        let layoutKey = character.flatMap { typingKeys.shortcutKey(for: $0, command: held.contains(.command)) }
        guard let (code, shifted, extraFlags) = layoutKey.map({ ($0.code, $0.shift, CGEventFlags()) }) ?? Self.keyCode(keysym) else {
            // A character with modifiers this layout table doesn't know: typed as is. Other keys: nothing.
            if Self.printable(keysym), let scalar = Unicode.Scalar(Self.codePoint(keysym)) { text(String(Character(scalar))) }
            return
        }
        var flags: CGEventFlags = []
        if held.contains(.command) { flags.insert(.maskCommand) }
        if held.contains(.shift) || shifted { flags.insert(.maskShift) }
        if held.contains(.option) { flags.insert(.maskAlternate) }
        if held.contains(.control) { flags.insert(.maskControl) }
        press(code, modifiers: flags, extra: extraFlags)
    }

    /// Short text as key presses on the Mac's keyboard layout, each with its character
    /// on it: apps that read the key (Windows App, virtual machines) get the same
    /// as those that read the character. What no key types there, and long text, goes as
    /// characters, which only apps that read them get (`ScreenVideoWire.typedAsKeys`).
    func text(_ text: String) {
        guard text.utf16.count <= ScreenVideoWire.typedAsKeys else { return characters(Array(text.utf16)) }
        var unkeyed: [UniChar] = []
        for character in text {
            let units = Array(character.utf16)
            guard let key = typingKeys.key(for: character) else { unkeyed += units; continue }
            if !unkeyed.isEmpty { characters(unkeyed); unkeyed = [] }
            press(key.code, modifiers: key.shift ? .maskShift : [], characters: units)
        }
        if !unkeyed.isEmpty { characters(unkeyed) }
    }

    /// Characters with no key: on the A key's code. Apps that read the character
    /// get it; apps that read the key (Windows App, virtual machines) get an A.
    private func characters(_ units: [UniChar]) {
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

    private let typingKeys = TypingKeys.shared

    /// `code` pressed as a keyboard presses it (`strokes`), with `characters` on the key's own events.
    private func press(_ code: CGKeyCode, modifiers: CGEventFlags, extra: CGEventFlags = [], characters: [UniChar]? = nil) {
        for stroke in Self.strokes(code, modifiers: modifiers, extra: extra) {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: stroke.code, keyDown: stroke.down) else { continue }
            event.flags = stroke.flags
            if stroke.isKey, var characters { event.keyboardSetUnicodeString(stringLength: characters.count, unicodeString: &characters) }
            event.post(tap: .cghidEventTap)
        }
    }

    struct Stroke: Equatable {
        var code: CGKeyCode
        var down: Bool
        var flags: CGEventFlags
        /// The key itself, not a modifier around it.
        var isKey = false
    }

    /// ⌘, ⇧, ⌥ and ⌃ as their own keys (left ones), in the order they go down, with
    /// the flag a keyboard adds for which of the two is down (IOLLEvent.h's NX_DEVICEL…KEYMASK).
    static let modifierKeys: [(flag: CGEventFlags, side: CGEventFlags, code: CGKeyCode)] = [
        (.maskCommand, CGEventFlags(rawValue: 0x08), 55), (.maskShift, CGEventFlags(rawValue: 0x02), 56),
        (.maskAlternate, CGEventFlags(rawValue: 0x20), 58), (.maskControl, CGEventFlags(rawValue: 0x01), 59),
    ]

    /// What a keyboard sends for `code` with `modifiers` held: each modifier's own key
    /// down, the key down and up (with `extra`, the flags a real keyboard puts on it),
    /// the modifiers up, each event's flags as a keyboard's (non-coalesced, and which
    /// modifier keys are down). Flags on the key alone are enough for most Mac apps, but
    /// apps that follow the modifier keys themselves (Windows App's RDP) need them pressed.
    static func strokes(_ code: CGKeyCode, modifiers: CGEventFlags, extra: CGEventFlags = []) -> [Stroke] {
        let held = modifierKeys.filter { modifiers.contains($0.flag) }
        var strokes: [Stroke] = [], flags: CGEventFlags = .maskNonCoalesced
        for key in held {
            flags.formUnion([key.flag, key.side])
            strokes.append(Stroke(code: key.code, down: true, flags: flags))
        }
        for down in [true, false] { strokes.append(Stroke(code: code, down: down, flags: flags.union(extra), isKey: true)) }
        for key in held.reversed() {
            flags.subtract([key.flag, key.side])
            strokes.append(Stroke(code: key.code, down: false, flags: flags))
        }
        // A key's flags stay in the system's state (as if Fn were still down) until a key comes without them.
        if held.isEmpty, !extra.isEmpty { strokes.append(Stroke(code: 59, down: false, flags: .maskNonCoalesced)) }
        return strokes
    }

    /// At once, not on the main queue: the ⌘V that usually follows must find it there.
    /// Marked concealed and transient (nspasteboard.org), so clipboard managers
    /// leave what a phone pastes, a password often, out of their history.
    func clipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.declareTypes([.string, Self.concealedType, Self.transientType], owner: nil)
        pasteboard.setString(text, forType: .string)
        pasteboard.setData(Data(), forType: Self.concealedType)
        pasteboard.setData(Data(), forType: Self.transientType)
    }

    static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
    static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
    /// What macOS adds to a clipboard that came from another device.
    static let remoteType = NSPasteboard.PasteboardType("com.apple.is-remote-clipboard")

    var clipboardChangeCount: Int { NSPasteboard.general.changeCount }

    func clipboardContents() -> ClipboardContents {
        let pasteboard = NSPasteboard.general
        var types = pasteboard.types ?? []
        // Cleared, and the app's data not written yet: give it a moment.
        for _ in 0..<10 where types.isEmpty {
            Thread.sleep(forTimeInterval: 0.05)
            types = pasteboard.types ?? []
        }
        if types.contains(Self.remoteType) || types.contains(Self.transientType) { return .elsewhere }
        return pasteboard.string(forType: .string).map { .text($0) } ?? .notText
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
