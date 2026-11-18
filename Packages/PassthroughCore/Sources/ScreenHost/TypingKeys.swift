#if os(macOS)
import Carbon.HIToolbox
import CoreGraphics
import Foundation

/// Which key, with or without shift, types each character on the Mac's keyboard
/// layout now, so a phone's typing and shortcuts can go as those keys
/// (`InputInjector`). Read again whenever the input source changes.
final class TypingKeys {
    struct Key: Equatable {
        var code: CGKeyCode
        var shift: Bool
    }

    /// What a layout's keys type: plain (and shifted), and with ⌘ held, which
    /// differs on layouts such as Dvorak – QWERTY ⌘.
    struct Layout: Equatable {
        var typing: [Character: Key] = [:]
        var command: [Character: Key] = [:]
    }

    /// Made as a phone's stream starts (`ScreenVideoStreamer`), so the layout is read before it types.
    static let shared = TypingKeys()

    private let lock = NSLock()
    private var layout = Layout()
    /// While an input method (Japanese, Chinese…) is in use, keys would be composed by it,
    /// and the phone's text is already what it should be: typed as characters instead.
    private var inputMethod = false

    private init() {
        // The text input sources are the main thread's.
        if Thread.isMainThread { start() } else { DispatchQueue.main.async { [self] in start() } }
    }

    private func start() {
        reload()
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String), object: nil, queue: .main
        ) { [weak self] _ in self?.reload() }
    }

    /// The key that types `character`; nil while an input method is in use.
    func key(for character: Character) -> Key? { lock.withLock { inputMethod ? nil : layout.typing[character] } }

    /// The key a shortcut on `character` takes, with ⌘ held or not.
    func shortcutKey(for character: Character, command: Bool) -> Key? {
        lock.withLock { command ? layout.command[character] : layout.typing[character] }
    }

    private func reload() {
        let layout = TISCopyCurrentKeyboardLayoutInputSource().flatMap { Self.layout(of: $0.takeRetainedValue()) } ?? Layout()
        let inputMethod = TISCopyCurrentKeyboardInputSource().map { Self.isInputMethod($0.takeRetainedValue()) } ?? false
        lock.withLock {
            self.layout = layout
            self.inputMethod = inputMethod
        }
    }

    static func isInputMethod(_ source: TISInputSource) -> Bool {
        guard let property = TISGetInputSourceProperty(source, kTISPropertyInputSourceType) else { return false }
        let type = Unmanaged<CFString>.fromOpaque(property).takeUnretainedValue() as String
        return type != kTISTypeKeyboardLayout as String
    }

    /// A layout's keys: the main block's (not the keypad's: Windows takes its digits for
    /// arrows with Num Lock off), plain before shifted, dead keys left out.
    static func layout(of source: TISInputSource) -> Layout? {
        guard let property = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(property).takeUnretainedValue() as Data
        let keyboardType = UInt32(LMGetKbdType())
        return data.withUnsafeBytes { raw -> Layout? in
            guard let keyboard = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return nil }
            func keys(_ modifiers: Int) -> [Character: Key] {
                var keys: [Character: Key] = [:]
                for shift in [false, true] {
                    let state = UInt32(((shift ? shiftKey : 0) | modifiers) >> 8)
                    for code in mainKeys {
                        var deadKeys: UInt32 = 0, length = 0
                        var units = [UniChar](repeating: 0, count: 4)
                        let status = UCKeyTranslate(keyboard, code, UInt16(kUCKeyActionDown), state,
                                                    keyboardType, 0, &deadKeys, units.count, &length, &units)
                        guard status == noErr, deadKeys == 0, length > 0 else { continue }
                        let string = String(utf16CodeUnits: units, count: length)
                        guard string.count == 1, let character = string.first,
                              character.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7F }) else { continue }
                        if keys[character] == nil { keys[character] = Key(code: code, shift: shift) }
                    }
                }
                return keys
            }
            return Layout(typing: keys(0), command: keys(cmdKey))
        }
    }

    /// Letters, digits, punctuation and space on ANSI, ISO and JIS keyboards (Return,
    /// Tab and the rest of this range type no character and are left out).
    private static let mainKeys: [CGKeyCode] = Array(0...50) + [93, 94]
}
#endif
