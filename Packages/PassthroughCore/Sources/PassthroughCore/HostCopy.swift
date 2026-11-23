import Foundation

/// The sentences about one computer that differ by its kind in more than the
/// noun (`HostWords` has the nouns). Each Mac variant is the sentence the app
/// showed before PCs, unchanged (`HostCopyTests` holds them). Times come in
/// already formatted, so this is text only.
public enum HostCopy {
    // MARK: Reaching it

    public static func needsPasscode(_ w: HostWords) -> String { "Set a device passcode to use Remote shell." }

    public static func locked(_ w: HostWords) -> String { "Unlock Passthrough to use Remote shell." }

    public static func keyUnavailable(_ w: HostWords) -> String {
        "Couldn't read the Remote shell key. Plug into \(w.the) again to renew access."
    }

    /// Paired (or granted once), and no shell access now.
    public static func noAccess(_ w: HostWords) -> String {
        switch w.kind {
        case .mac: "Turn on Remote shell in Passthrough on your Mac, then connect this \(w.device) with the cable once."
        case .windows: "Paired. Turn on Remote access on \(w.name), then plug this \(w.device) in once."
        case .other, nil: "Turn on Remote access in Passthrough on \(w.name), then connect this \(w.device) with the cable once."
        }
    }

    /// It refused the key this phone holds. A Mac has always said `noAccess` here.
    public static func revoked(_ w: HostWords) -> String {
        switch w.kind {
        case .mac: noAccess(w)
        case .windows, .other, nil: "\(w.name) no longer lets this \(w.device) in. Plug it into \(w.the) to get access again."
        }
    }

    /// Can't be reached, cause unknown. `lastHeard`: when it last answered, formatted.
    public static func unreachable(_ w: HostWords, fromAnywhere: Bool, lastHeard: String? = nil) -> String {
        let advice = unreachableAdvice(w, fromAnywhere: fromAnywhere) ?? mayBeAsleep + "."
        switch w.kind {
        case .mac:
            return "Can't reach your Mac. " + advice
        case .windows, .other, nil:
            return "Can't reach \(w.name). " + advice + (fromAnywhere ? lastHeard.map { " Last heard \($0)." } ?? "" : "")
        }
    }

    /// The hero's line while it can't be reached, cause unknown.
    public static let mayBeAsleep = "It may be asleep, off, or offline"

    /// What `unreachable` advises, without its "Can't reach…" or "Last heard", for a page whose title and
    /// caption already say those; nil when `mayBeAsleep` is all there is to say.
    public static func unreachableAdvice(_ w: HostWords, fromAnywhere: Bool) -> String? {
        guard fromAnywhere else { return "Use the same Wi-Fi, or turn on Tailscale on both devices." }
        return w.kind == .mac ? "Check that Remote shell is on and the Mac is awake." : nil
    }

    /// `sleepsAfter`: how long it waits before sleeping, formatted ("30 minutes"); nil when not known or never.
    public static func wentToSleep(_ w: HostWords, at: String, sleepsAfter: String?) -> String {
        if let sleepsAfter {
            return "\(w.name) went to sleep at \(at). It sleeps after \(sleepsAfter); turn on Stay awake in Passthrough on \(w.the)."
        }
        return "\(w.name) went to sleep at \(at). Turn on Stay awake in Passthrough on \(w.the) to keep it reachable."
    }

    public static func turnedOff(_ w: HostWords, at: String) -> String {
        "Remote access was turned off on \(w.name) at \(at). Turn it on there."
    }

    public static func shutDown(_ w: HostWords, at: String) -> String {
        switch w.kind {
        case .windows: "\(w.name) was shut down or restarted at \(at). It is reachable again once Windows has started."
        case .mac, .other, nil: "\(w.name) was shut down or restarted at \(at). It is reachable again once it has started."
        }
    }

    public static func noRelay(_ w: HostWords) -> String {
        "Can't reach \(w.name) from here. The relay isn't answering; it works on \(w.the)'s own network or Tailscale."
    }

    /// The sentence for a page's state; nil where the page says nothing more than its title.
    /// `at` formats a farewell's time, `sleepsAfter` is the stored `HostInfo.sleepAfter`, formatted.
    public static func state(_ state: HostPageState, _ w: HostWords, fromAnywhere: Bool, lastHeard: String?,
                             at: (Date) -> String, sleepsAfter: String?) -> String? {
        switch state {
        case .connected, .connecting, .reconnecting: nil
        case .unreachable: unreachable(w, fromAnywhere: fromAnywhere, lastHeard: lastHeard)
        case let .wentToSleep(date): wentToSleep(w, at: at(date), sleepsAfter: sleepsAfter)
        case let .turnedOff(date): turnedOff(w, at: at(date))
        case let .shutDown(date): shutDown(w, at: at(date))
        case .noRelay: noRelay(w)
        case .revoked: revoked(w)
        case .pairedNoAccess: noAccess(w)
        case .locked: locked(w)
        case .needsPasscode: needsPasscode(w)
        case .keyUnavailable: keyUnavailable(w)
        }
    }

    /// The page's big title for a PC (a Mac's hero keeps its own, which knows Keep awake).
    public static func title(_ state: HostPageState) -> String {
        switch state {
        case .connected: "Reachable"
        case .connecting: "Connecting…"
        case .reconnecting: "Reconnecting…"
        case .unreachable: "Can't reach it"
        case .wentToSleep: "Asleep"
        case .turnedOff: "Remote access is off"
        case .shutDown: "Shut down"
        case .noRelay: "Can't reach it from here"
        case .revoked: "No access"
        case .pairedNoAccess: "Paired"
        case .locked: "Unlock to continue"
        case .needsPasscode: "Needs a passcode"
        case .keyUnavailable: "Plug in to renew"
        }
    }

    /// The short status beside its name: "Can't reach Mac".
    public static func cantReach(_ w: HostWords) -> String { "Can't reach \(w.noun)" }

    // MARK: Shell and screen

    /// Why no shell can start there; nil when one can.
    public static func shell(_ state: HostShellState, _ w: HostWords) -> String? {
        switch state {
        case .available: nil
        case .nobodySignedIn: "Sign in to \(w.name) to use its shell."
        case .someoneElseSignedIn: "Someone else is signed in to \(w.name). Its shell starts when you sign in."
        case .appNotOpen: "Passthrough isn't open on \(w.name). Open it there."
        // Neither a Mac nor a PC has a per-phone Shell switch: a phone's shell comes with its access, which it gets
        // by being plugged in while the computer lets phones in.
        case .switchedOff:
            "\(w.name) doesn't let this \(w.device) open shells. Plug this \(w.device) into \(w.the) with \(w.feature) on to get access again."
        }
    }

    /// The Screen row's sentence; nil for no row.
    public static func screen(_ state: HostScreenState, _ w: HostWords) -> String? {
        switch state {
        case .available: "See and control \(w.the)'s screen"
        case .notInThisVersion: "\(w.name)'s screen isn't in this version of Passthrough yet. Its shell works."
        case .switchedOff: "Screen is off for this \(w.device). On \(w.name), open \(w.settingsPage) and turn on Screen for it."
        case .remoteDesktopOff: "Remote Desktop is off on \(w.name). Turn it on in \(w.settingsPage) there."
        case .windowsHome: "\(w.name) runs Windows Home, which has no Remote Desktop. The shell works."
        case .noPassword: "Your account on \(w.name) has no password Remote Desktop can use. Add one on \(w.the)."
        case .remoteDesktopProblem: "Remote Desktop on \(w.name) needs a look. Open Passthrough's settings on \(w.the)."
        case .noRow: nil
        }
    }

    /// Under the page's rows when they can't be used yet because it has no access.
    public static func reachBlockNoAccess(_ w: HostWords) -> String {
        switch w.kind {
        case .mac: "To change these from this \(w.device), set up Remote shell on the Mac. The steps are below."
        case .windows, .other, nil: "To use \(w.name) from this \(w.device), turn on Remote access there. The steps are below."
        }
    }

    /// The switcher's row for a computer paired without shell access.
    public static func pairedNoShell(_ kind: HostKind) -> String {
        kind == .mac ? "Paired, no Remote shell" : "Paired, no access yet"
    }

    // MARK: Sharing it with another computer

    /// Under the Share row when the computer doesn't let this device share it: the switch, by the name it has there.
    public static func shareOff(_ w: HostWords) -> String {
        switch w.kind {
        case .mac: "Turn on May share access with other computers for this \(w.device) in Passthrough's settings on \(w.name)."
        case .windows, .other, nil: "Turn on Share for this \(w.device) in \(w.settingsPage) on \(w.name)."
        }
    }

    /// Under the Share row when a Mac lets this device pass on only its screen, to another Mac (a screen pass).
    public static func shareScreenOnly(_ w: HostWords) -> String {
        "Its screen, with another of your Macs. To share its shell or share with a PC, " + lowercasedFirst(shareOff(w))
    }

    /// Why the computer being given access can't take it: its `host` came without an identity key. A PC
    /// sends none while no one is signed in or its Passthrough isn't open; otherwise it's an older build.
    public static func cantTakeAccess(_ host: HostInfo?, _ w: HostWords) -> String {
        if host?.signedIn == false { return "Sign in to \(w.name) and open Passthrough there, then try again." }
        if host?.app == false { return "Open Passthrough on \(w.name), then try again." }
        return "\(w.name) needs the latest Passthrough to use other computers."
    }

    /// While the computer being given access keeps it. A PC asks its owner first (Windows Hello or the
    /// account's password), and has about half a minute for it, so the phone says to look there.
    public static func handingOver(_ w: HostWords) -> String {
        switch w.kind {
        case .windows: "Confirm on \(w.name) when it asks (Windows Hello or the account's password)…"
        case .mac, .other, nil: "Handing it to \(w.name)…"
        }
    }

    /// The Activity tab for a computer whose Passthrough keeps no timeline (a PC answers with none).
    public static func noActivity(_ w: HostWords) -> String { "\(w.name) doesn't record activity yet." }

    private static func lowercasedFirst(_ s: String) -> String { s.prefix(1).lowercased() + s.dropFirst() }

    /// What a refusal says (nil for one shown another way: a refused key is `noAccess`).
    public static func error(_ error: ShellError, _ w: HostWords) -> String? {
        switch error {
        case .tooManySessions: "\(w.Your) already has \(RemoteShell.maxSessions) sessions open. End one to start another."
        case .noSuchSession: "That session is no longer open on \(w.your)."
        case .badRequest: "\(w.Your) couldn't do that. Try again."
        case .screenNotAllowed:
            w.kind == .mac
                ? "This \(w.device) isn't allowed to see your Mac's screen. Turn on Screen for it in Passthrough's Remote Shell settings on your Mac."
                : screen(.switchedOff, w)
        // Asked for only after the Mac said it can't stream its screen itself.
        case .screenUnavailable: "Your Mac can't show its screen yet. In Passthrough's Remote Shell settings on your Mac, allow Screen Recording and Accessibility, or turn on Screen Sharing."
        case .screenVideoUnavailable: "Your Mac can't stream its screen itself yet. In Passthrough's Remote Shell settings on your Mac, allow Screen Recording and Accessibility."
        case .tooManyScreens: "\(w.Your) is already showing its screen as often as it allows (\(RemoteShell.maxScreenViewsPerPhone) views per phone, \(RemoteShell.maxScreenViews) in all). Close one to open another."
        case .notAllowed:
            w.kind == .mac
                ? "Your Mac doesn't let this \(w.device) change Keep awake and the VPN. Turn on Awake & VPN for it in Passthrough's Remote Shell settings on your Mac."
                : shell(.switchedOff, w)
        case .vpnNotSetUp: "Your Mac has no VPN set up yet. Add one in Passthrough's VPN settings on the Mac."
        case .screenOnly: "\(w.That) only lets this device see its screen."
        case .passNotSaved: "Your Mac couldn't save the screen pass. Try again."
        case .signedOut: w.kind == .mac ? "Nobody is signed in there, so its shell can't start. Sign in at the computer first." : shell(.appNotOpen, w)
        case .rdpUnavailable: "That computer's screen isn't available right now."
        case .tryLater: "Too many tries just now. Wait a few minutes, then try again."
        // Sharing access with another computer (stage 7).
        case .tooManyComputers: "\(w.That) already lets in as many other computers as it allows. Remove one in its settings first."
        case .passConflict: "\(w.That) already has access to one with this name but different details. Remove it there, then try again."
        case .notAuthorized: nil
        }
    }

    // MARK: Setup

    /// One numbered step of setting up access.
    public struct SetupStep: Equatable, Sendable {
        public var title: String
        public var detail: String
        public var done: Bool
        /// A button this phone has for it.
        public var action: SetupAction?
        /// A line under the button.
        public var note: String?

        public init(title: String, detail: String, done: Bool = false, action: SetupAction? = nil, note: String? = nil) {
            self.title = title; self.detail = detail; self.done = done; self.action = action; self.note = note
        }
    }

    public enum SetupAction: Equatable, Sendable { case turnOnCableLink }

    // Each says what the user sees there: the Mac's switch has no label of its own (only the page's
    // title beside it), and the PC's sits beside its sentence.
    private static let macTurnOn = "open Passthrough and turn on the switch at the top of Settings \u{25B8} Remote Shell"
    private static let pcTurnOn = "open Passthrough and turn on Use this PC's shell from your phones in Settings \u{25B8} Remote access"

    /// How to give this device the shell. `w.kind` nil: nothing paired yet, both kinds' steps in one.
    /// `isPad`: an iPad serves the cable from the app, so there is nothing to turn on.
    /// `cableLinkOn`: the phone's service is running; `needsVPNPrompt`: iOS will ask to add a VPN configuration.
    public static func setupSteps(_ w: HostWords, paired: Bool, isPad: Bool, cableLinkOn: Bool, needsVPNPrompt: Bool) -> [SetupStep] {
        let pair = SetupStep(title: w.kind == nil || w.kind == .other ? "Pair this \(w.device) with your Mac or PC" : "Pair this \(w.device) with \(w.your)",
                             detail: paired ? "Done." : "In the \(w.device) tab, tap Pair under Paired devices, then Pair a Mac or PC.", done: paired)
        switch w.kind {
        case .mac:
            return [
                pair,
                SetupStep(title: "Turn on Remote shell on your Mac",
                          detail: "On the Mac, " + macTurnOn + "."),
                SetupStep(title: "Connect over USB once",
                          detail: isPad ? "With Passthrough open, plug this iPad into the Mac. Its shells then show up on the Mac and Shells tabs by themselves."
                                        : "With sharing on, plug this \(w.device) into the Mac. Its shells then show up on the Mac and Shells tabs by themselves."),
            ]
        case .windows:
            let plug: SetupStep
            if isPad {
                plug = SetupStep(title: "Plug this iPad in once", detail: "With Passthrough open, plug this iPad into the PC.")
            } else if cableLinkOn {
                plug = SetupStep(title: "Plug this \(w.device) in once",
                                 detail: "Plug this \(w.device) into the PC with Passthrough open here. The PC then appears with its shells.")
            } else {
                plug = SetupStep(title: "Plug this \(w.device) in once", detail: "The cable link is off.", action: .turnOnCableLink,
                                 note: needsVPNPrompt ? "iOS asks to add a VPN configuration. That is how the cable link works; no traffic is sent through it for a PC." : nil)
            }
            return [
                pair,
                SetupStep(title: "Turn on Remote access on your PC",
                          detail: "On the PC, " + pcTurnOn + ". Windows asks for an administrator once."),
                plug,
            ]
        case .other, nil:
            return [
                pair,
                SetupStep(title: "Turn on Remote shell (Mac) or Remote access (PC) there",
                          detail: "On a Mac, " + macTurnOn + ". On a PC, " + pcTurnOn + "."),
                SetupStep(title: "Plug in once",
                          detail: isPad ? "With Passthrough open, plug this iPad into the computer. Its shells then show up by themselves."
                                        : "With the cable link on, plug this \(w.device) into the computer. Its shells then show up by themselves."),
            ]
        }
    }
}
