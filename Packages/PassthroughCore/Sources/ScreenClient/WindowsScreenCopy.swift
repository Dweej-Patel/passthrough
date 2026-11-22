import Foundation
import PassthroughCore

/// The sentence for each way a PC's screen can be refused or end
/// (docs/plans/windows-remote/stage-6-ios-rdp.md, section 7), and whether
/// trying again can help.
public enum WindowsScreenCopy {
    public struct Ending: Equatable, Sendable {
        public var sentence: String
        public var canTryAgain: Bool
        public init(_ sentence: String, canTryAgain: Bool) { self.sentence = sentence; self.canTryAgain = canTryAgain }
    }

    /// The host's answer to `rdp` when it isn't `rdpReady`. Nil: not a refusal this
    /// view words itself (`screen_only`, `not_authorized`: the host's message or the generic one).
    public static func refusal(_ error: ShellError, detail: String?, retryAfter: Int?, _ w: HostWords) -> Ending? {
        switch error {
        case .screenNotAllowed:
            return Ending("Screen is off for this \(w.device). On \(w.name), open Passthrough's settings and turn on Screen for it.",
                          canTryAgain: false)
        case .tooManyScreens:
            return Ending("\(w.name)'s screen is already open on as many devices as it allows.", canTryAgain: true)
        case .tryLater:
            return Ending("Too many sign-ins from this \(w.device). Try again \(wait(retryAfter)).", canTryAgain: false)
        case .rdpUnavailable:
            switch detail {
            case "off":
                return Ending("Remote Desktop is off on \(w.name). Turn it on in Passthrough's settings there.", canTryAgain: true)
            case "edition":
                return Ending("\(w.name) runs Windows Home, which has no Remote Desktop. The shell works.", canTryAgain: false)
            case "account":
                return Ending("Your account on \(w.name) has no password Remote Desktop can use. Add one on \(w.the).", canTryAgain: false)
            case "exposed":
                return Ending("Remote Desktop on \(w.name) is open to the network, so Passthrough won't use it. "
                              + "Close it in Passthrough's settings there.", canTryAgain: false)
            case "policy":
                return Ending("A policy on \(w.name) keeps Remote Desktop from being used. Check Remote Desktop in Passthrough's settings there.",
                              canTryAgain: false)
            default:   // "service", and any reason this version doesn't know
                return Ending("Remote Desktop isn't running on \(w.name). Restart \(w.the), or turn it on in Passthrough's settings there.",
                              canTryAgain: true)
            }
        case .badRequest:
            return Ending("Update Passthrough on \(w.name) to see its screen.", canTryAgain: false)
        default:
            return nil
        }
    }

    /// "in 10 minutes", "in a minute", "in 30 seconds", "later".
    static func wait(_ seconds: Int?) -> String {
        guard let seconds, seconds > 0 else { return "later" }
        if seconds < 60 { return "in \(seconds) seconds" }
        let minutes = (seconds + 59) / 60
        return minutes == 1 ? "in a minute" : "in \(minutes) minutes"
    }

    /// Why a view ended, when the host said (`screenEnded` on the other connection). Nil: a reason this version doesn't know.
    public static func screenEnded(_ reason: String, _ w: HostWords) -> Ending? {
        switch reason {
        case "switched_off": Ending("\(w.name) turned Screen off for this \(w.device).", canTryAgain: false)
        case "stopped": Ending("This view was stopped from \(w.name).", canTryAgain: true)
        case "taken": Ending("Someone signed in at \(w.name), so this view ended.", canTryAgain: true)
        default: nil
        }
    }

    /// A session's ending. Nil: no sentence (`closedHere`), or one the sign-in sheet says (`signIn(.wrongPassword)`, `.other`).
    public static func ending(_ end: ScreenEnd, _ w: HostWords) -> Ending? {
        switch end {
        case .closedHere, .signIn(.wrongPassword), .signIn(.other):
            return nil
        case .identityMismatch:
            return Ending("This isn't the Remote Desktop \(w.name) told us to expect, so nothing was sent.", canTryAgain: false)
        case .signIn(.accountLocked):
            return Ending("Windows has locked this account after too many wrong passwords. Wait, or unlock it at \(w.the).",
                          canTryAgain: false)
        case .signIn(.passwordExpired):
            return Ending("Windows wants a new password for this account. Change it at \(w.the).", canTryAgain: false)
        case .signIn(.notAllowedRemotely):
            return Ending("This account isn't allowed to sign in through Remote Desktop. Allow it in Passthrough's settings on \(w.name).",
                          canTryAgain: false)
        case .signIn(.accountDisabled):
            return Ending("This account is turned off on \(w.name).", canTryAgain: false)
        case .unsupported:
            return Ending("\(w.name)'s Remote Desktop wouldn't sign in the way Passthrough requires. "
                          + "Check Remote Desktop in Passthrough's settings there.", canTryAgain: true)
        case .takenOver:
            return Ending("Someone signed in at \(w.name), so this view ended.", canTryAgain: true)
        case .signedOut:
            return Ending("You were signed out of Windows on \(w.name).", canTryAgain: true)
        case let .hostEnded(why):
            return Ending(why == "licence" ? "Windows on \(w.name) ended the session: it has no Remote Desktop licence to give."
                                           : "Windows on \(w.name) ended the session.", canTryAgain: true)
        case .protocolError, .connectionLost:
            return Ending("The connection to \(w.name) was lost.", canTryAgain: true)
        }
    }

    /// The sign-in sheet's error line for a refused login.
    public static func signInError(_ end: ScreenEnd) -> String? {
        switch end {
        case .signIn(.wrongPassword): "Windows didn't accept that password. If you changed it, type the new one."
        default: nil
        }
    }
}
