import Foundation
import PassthroughCore

/// What the Windows menu, the three-finger swipes and Copy and Paste send a PC:
/// one key with modifiers held around it, always as scan codes (`WindowsKeymap`).
public enum WindowsShortcut: Equatable, Sendable {
    case ctrlAltDel
    /// The Windows key alone.
    case start
    case taskView
    case altTab
    case showDesktop
    case closeWindow
    case delete
    /// F1…F12.
    case function(Int)
    /// The virtual desktop to the right, and to the left.
    case nextDesktop
    case previousDesktop
    /// Control + Insert, not Control + C (which stops a program in a console).
    case copy
    /// Shift + Insert.
    case paste

    public var chord: (key: UInt32, modifiers: ScreenModifiers) {
        switch self {
        case .ctrlAltDel: (RFBKeys.delete, [.control, .option])
        case .start: (RFBKeys.windows, [])
        case .taskView: (RFBKeys.tab, .windows)
        case .altTab: (RFBKeys.tab, .option)
        case .showDesktop: (0x64, .windows)   // d
        case .closeWindow: (RFBKeys.function(4), .option)
        case .delete: (RFBKeys.delete, [])
        case let .function(number): (RFBKeys.function(number), [])
        case .nextDesktop: (RFBKeys.right, [.control, .windows])
        case .previousDesktop: (RFBKeys.left, [.control, .windows])
        case .copy: (RFBKeys.insert, .control)
        case .paste: (RFBKeys.insert, .shift)
        }
    }

    /// The exact key events, in order.
    public var strokes: [WindowsKeymap.Stroke] {
        WindowsKeymap.strokes(for: chord.key, modifiers: chord.modifiers)
    }

    /// A hardware keyboard's ⌘ on a PC: Control (the default, so ⌘C copies), or the Windows key when the user chose that.
    public static func modifiers(_ modifiers: ScreenModifiers, commandIsWindows: Bool) -> ScreenModifiers {
        guard commandIsWindows, modifiers.contains(.command) else { return modifiers }
        var mapped = modifiers
        mapped.remove(.command)
        mapped.insert(.windows)
        return mapped
    }
}
