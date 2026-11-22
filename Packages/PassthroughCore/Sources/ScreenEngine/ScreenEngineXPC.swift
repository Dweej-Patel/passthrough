#if os(macOS)
import Foundation
import IOSurface

/// What the Mac app asks of the engine helper (an XPC service inside the app,
/// sandboxed, one process per window): a PC's Remote Desktop session, run
/// where the app's keys and the network are out of reach. The helper gets the
/// session's bytes over a socket pair and never a network socket.
@objc public protocol ScreenEngineXPC {
    /// Starts the one session this helper runs. `transport`: the helper's end of the socket pair that carries Remote
    /// Desktop's bytes. `certSHA256`: the certificate the PC's Remote Desktop must present (64 lowercase hex).
    /// The reply says whether the session started; what happens to it comes through `ScreenEngineClientXPC`.
    func start(username: String, password: String, certSHA256: String, clientName: String, width: Int, height: Int,
               desktopScale: Int, deviceScale: Int, transport: FileHandle, reply: @escaping (Bool) -> Void)
    /// The pointer at (x, y) in desktop pixels with `buttons` held (1 left, 2 middle, 4 right).
    func pointer(x: Int, y: Int, buttons: Int)
    /// Content follows the fingers by (dx, dy) desktop pixels, the pointer at (x, y); `notch`: pixels a wheel notch is worth.
    func scroll(x: Int, y: Int, dx: Double, dy: Double, notch: Double)
    func scrollEnded()
    /// One key (an X keysym) with modifiers held around it (`ScreenModifiers`' raw value).
    func key(_ keysym: UInt32, modifiers: Int)
    func text(_ text: String)
    /// Offers `text` to the PC's clipboard and pastes it there. The reply is false when it is too long.
    func paste(_ text: String, reply: @escaping (Bool) -> Void)
    /// Copies the PC's selection; `copied` answers.
    func copySelection()
    func reshape(width: Int, height: Int, desktopScale: Int, deviceScale: Int)
    /// The window can be seen (true) or not: a PC stops sending pictures to one that can't.
    func setActive(_ active: Bool)
    /// The picture up to `sequence` is on screen: at most two updates wait for this.
    func presented(_ sequence: UInt64)
    func stop()
}

/// What the helper tells the app. Every value is checked by the app before it is used (`ScreenEngineCodes`).
@objc public protocol ScreenEngineClientXPC {
    func phase(_ code: Int)
    /// The desktop's pixels from here on: a BGRA surface of this size (again after every resize).
    func surface(_ surface: IOSurface, width: Int, height: Int)
    /// That part of the surface changed.
    func dirty(x: Int, y: Int, width: Int, height: Int, sequence: UInt64)
    /// The pointer's look: BGRA with straight alpha.
    func pointerShape(_ bgra: Data, width: Int, height: Int, hotX: Int, hotY: Int)
    func pointerHidden()
    func pointerPosition(x: Int, y: Int)
    func copied(_ code: Int, text: String?)
    func ended(_ code: Int, detail: String?)
}

public enum ScreenEngineService {
    /// The helper's bundle identifier, beside the app's.
    public static func name(appBundleID: String) -> String { "\(appBundleID).screen-engine" }

    public static func interface() -> NSXPCInterface { NSXPCInterface(with: ScreenEngineXPC.self) }
    public static func clientInterface() -> NSXPCInterface { NSXPCInterface(with: ScreenEngineClientXPC.self) }

    /// The other end must be signed by the same team as this process. Nil when this process has no team
    /// (an unsigned or ad-hoc build): there is then nothing to hold the other end to.
    public static func sameTeamRequirement() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any], let team = dict[kSecCodeInfoTeamIdentifier as String] as? String,
              team.range(of: "^[A-Z0-9]{10}$", options: .regularExpression) != nil else { return nil }
        return "anchor apple generic and certificate leaf[subject.OU] = \"\(team)\""
    }
}
#endif
