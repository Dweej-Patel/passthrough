import Foundation

/// Pointer buttons held, whatever shows the screen. Raw values are RFB's, so
/// both of the Mac's wire formats keep their bytes (`RFBClient.Buttons`,
/// `ScreenVideoWire` pointer messages).
public struct ScreenButtons: OptionSet, Sendable, Hashable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    public static let left = ScreenButtons(rawValue: 1)
    public static let middle = ScreenButtons(rawValue: 2)
    public static let right = ScreenButtons(rawValue: 4)
}

/// An account on the computer being viewed: a Mac's for Screen Sharing, a
/// PC's for Remote Desktop. `username` is as typed ("name", "PC\\name",
/// "name@outlook.com").
public struct ScreenLogin: Sendable, Equatable {
    public var username: String
    public var password: String
    public init(username: String, password: String) { self.username = username; self.password = password }
}

/// Printing a login never shows its password.
extension ScreenLogin: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String { "ScreenLogin(username: \(username), password: <redacted>)" }
    public var debugDescription: String { description }
    /// `dump` and debuggers see the same redacted fields.
    public var customMirror: Mirror {
        Mirror(self, children: ["username": username, "password": "<redacted>"], displayStyle: .struct)
    }
}

/// A key by X keysym (`RFBKeys`): what the canvas, the key row and both of the
/// Mac's wire formats carry.
public typealias ScreenKey = UInt32

/// Modifiers held around one key. Raw values 1…8 are `ScreenVideoWire.Modifiers`'.
public struct ScreenModifiers: OptionSet, Sendable, Hashable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    public static let command = ScreenModifiers(rawValue: 1)
    public static let shift = ScreenModifiers(rawValue: 2)
    /// Alt on a PC.
    public static let option = ScreenModifiers(rawValue: 4)
    public static let control = ScreenModifiers(rawValue: 8)
    public static let windows = ScreenModifiers(rawValue: 16)

    /// The modifiers among `keysyms` (the key row's held keys, a hardware key's
    /// flags); anything else in it is not a modifier and is left out.
    public init(keysyms: [UInt32]) {
        self = keysyms.reduce(into: []) { set, keysym in
            switch keysym {
            case RFBKeys.command: set.insert(.command)
            case RFBKeys.shift: set.insert(.shift)
            case RFBKeys.option, RFBKeys.alt: set.insert(.option)
            case RFBKeys.control: set.insert(.control)
            case RFBKeys.windows: set.insert(.windows)
            default: break
            }
        }
    }

    /// The Mac's keysyms for these, in press order (release is the reverse):
    /// control, option, shift, command, windows.
    public var keysyms: [UInt32] {
        var keys: [UInt32] = []
        if contains(.control) { keys.append(RFBKeys.control) }
        if contains(.option) { keys.append(RFBKeys.option) }
        if contains(.shift) { keys.append(RFBKeys.shift) }
        if contains(.command) { keys.append(RFBKeys.command) }
        if contains(.windows) { keys.append(RFBKeys.windows) }
        return keys
    }
}
