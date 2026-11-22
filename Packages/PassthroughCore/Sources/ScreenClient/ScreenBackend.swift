import CoreGraphics
import CoreMedia
import Foundation
import PassthroughCore

/// What the view may offer for the backend in use. The menus and the key row
/// read these, never the backend's type.
public struct ScreenCapabilities: OptionSet, Sendable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }
    /// The Mac's own stream: curtain, sound, microphone, Use Here, gestures, fn,
    /// quality, the Mac's display or one in this device's shape (`MacStreamControls`).
    public static let macStream = ScreenCapabilities(rawValue: 1 << 0)
    /// Scrolls by pixels; without it, by wheel notches.
    public static let smoothScroll = ScreenCapabilities(rawValue: 1 << 1)
    /// `text(_:)` carries any character.
    public static let unicodeText = ScreenCapabilities(rawValue: 1 << 2)
    /// The far screen takes this device's shape when asked.
    public static let resize = ScreenCapabilities(rawValue: 1 << 3)
    /// Frames leave the pointer out; pointer events say where it is and what it looks like.
    public static let drawsOwnPointer = ScreenCapabilities(rawValue: 1 << 4)
    /// Needs a `ScreenLogin`.
    public static let signIn = ScreenCapabilities(rawValue: 1 << 5)
    /// A PC: the Windows key row, menu and gestures.
    public static let windowsKeys = ScreenCapabilities(rawValue: 1 << 6)
    /// `presented(_:)` must be called for every sample.
    public static let frameAcks = ScreenCapabilities(rawValue: 1 << 7)
}

/// The answer to `copySelection()`.
public enum ScreenCopyResult: Sendable, Equatable {
    case text(String)
    /// The clipboard didn't change: nothing was selected.
    case nothing
    case tooLong
    /// Something that isn't text (an image, a file).
    case notText
}

/// Why the far computer refused a login.
public enum ScreenSignInProblem: Sendable, Equatable {
    case wrongPassword, passwordExpired, accountLocked, accountDisabled, notAllowedRemotely
    case other(String?)
}

/// Why a view ended.
public enum ScreenEnd: Sendable, Equatable {
    /// `close()` was called.
    case closedHere
    /// The connection ended underneath.
    case connectionLost
    case signIn(ScreenSignInProblem)
    /// Not what the host said would answer: a PC's Remote Desktop with another
    /// certificate, or "Screen Sharing" on a Mac that offered no login.
    case identityMismatch
    /// Someone signed in at the computer, or another connection took the session.
    case takenOver
    /// The remote session signed out.
    case signedOut
    /// The host ended it and said why (a licence, a policy).
    case hostEnded(String)
    /// A peer this backend can't talk to.
    case unsupported(String)
    case protocolError(String)
}

/// How far a connection that signs in has got (Remote Desktop).
public enum ScreenConnectPhase: Sendable, Equatable {
    /// The first request is out.
    case negotiating
    /// The far end proved it is the one the host announced.
    case identityChecked
    /// The login was accepted.
    case signedIn
}

/// What only the Mac's own stream says (`ScreenVideoClient.Event`).
public enum MacStreamEvent: Sendable {
    case fitted(ScreenVideoWire.Fit)
    case viewers([String])
    /// Another device took this view over; `.ended` follows.
    case movedAway(to: String)
    case curtained(Bool)
    case microphone(ScreenVideoWire.MicrophoneState)
    case sound(ScreenVideoWire.SoundState)
    case soundPacket(Data)
}

/// What a backend says, on the queue it was given (main).
public enum ScreenBackendEvent: @unchecked Sendable {
    case phase(ScreenConnectPhase)
    /// The screen in pixels: the first one means it shows the screen.
    case size(width: Int, height: Int)
    /// A whole picture (Screen Sharing, Remote Desktop).
    case image(CGImage)
    /// A frame for a display layer (the Mac's stream): show it, then `presented(number)`.
    case sample(CMSampleBuffer, number: UInt32)
    /// Where the far pointer is, in screen pixels, and whether it's on this screen.
    case pointerPosition(CGPoint, visible: Bool)
    /// What the pointer looks like, `size` in screen pixels, its tip at `hotSpot` in them.
    case pointerShape(CGImage, size: CGSize, hotSpot: CGPoint)
    case pointerHidden
    case copied(ScreenCopyResult)
    /// The far clipboard changed without being asked (Screen Sharing); never this
    /// device's own paste coming back.
    case clipboardChanged(String)
    case bell
    case macStream(MacStreamEvent)
    /// Over; nothing follows.
    case ended(ScreenEnd)
}

/// Whatever shows a computer's screen: the Mac's own stream, Screen Sharing,
/// or a PC's Remote Desktop. Input is called on main; events arrive on the
/// queue given to the backend (main).
public protocol ScreenBackend: AnyObject, Sendable {
    var capabilities: ScreenCapabilities { get }
    /// The Mac's own stream only: its extra controls. Nil elsewhere.
    var macStream: (any MacStreamControls)? { get }

    func start()
    /// Ends it. Safe to call twice.
    func close()

    /// The pointer at `point` (screen pixels of the last `.size`) with `buttons` held.
    func pointer(at point: CGPoint, buttons: ScreenButtons)
    /// Fingers moved `delta` pixels with the pointer at `point`: content follows them.
    /// `notch`: pixels a wheel notch is worth. The backend keeps the remainder.
    func scroll(at point: CGPoint, by delta: CGPoint, notch: CGFloat)
    func scrollEnded()
    /// Press and release, with `modifiers` held around it.
    func key(_ key: ScreenKey, modifiers: ScreenModifiers)
    /// Typed text, no modifiers.
    func text(_ text: String)
    /// Puts `text` on the far clipboard and pastes it there. False: too long, nothing sent.
    func paste(_ text: String) -> Bool
    /// Copies the far selection; `.copied` or `.clipboardChanged` answers.
    func copySelection()

    /// Sample `number` is on screen (`.frameAcks`).
    func presented(_ number: UInt32)
    /// The display lost its place: start again from a whole picture.
    func needsKeyframe()
    /// The app left the foreground (false) or came back (true).
    func setActive(_ active: Bool)
}

extension ScreenBackend {
    /// The Mac's backends do nothing on their own when the app goes away (the model handles their sound and curtain).
    public func setActive(_ active: Bool) {}
}

/// The Mac's own stream's extra controls.
public protocol MacStreamControls: AnyObject, Sendable {
    func relayout(_ layout: ScreenVideoClient.Layout)
    func useHere()
    func curtain(_ hidden: Bool)
    func sound(_ on: Bool)
    func microphone(_ on: Bool)
    func voice(_ samples: Data)
    func function(_ down: Bool)
    func gesture(_ gesture: ScreenVideoWire.Gesture, phase: ScreenVideoWire.GesturePhase, value: Double)
}
