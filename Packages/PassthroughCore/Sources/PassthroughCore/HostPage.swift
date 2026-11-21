import Foundation

/// How far the phone got with the selected computer's shell connection
/// (the app's `ShellModel.Reach`, as the page needs it).
public enum HostReach: Equatable, Sendable {
    case noAccess, locked, needsPasscode, keyUnavailable
    case connecting(redialing: Bool)
    case unreachable
    case ready(ShellPath?)
}

/// Whether the computer's relay answered when it couldn't be reached from anywhere.
public enum RelayHealth: Sendable, Equatable { case unknown, answering, silent }

/// Everything the page for one computer is decided from.
public struct HostPageInput: Sendable, Equatable {
    public var kind: HostKind
    public var reach: HostReach
    /// `not_authorized` arrived while this phone held a credential for it.
    public var accessRefused: Bool
    /// What it said about itself: live, else the last kept.
    public var host: HostInfo?
    public var farewell: HostFarewell?
    public var connectingSince: Date?
    /// This connect also dialled it over iroh (from anywhere).
    public var triedFromAnywhere: Bool
    public var relay: RelayHealth
    /// How the last `open` was refused, if it was: `signed_out` or `not_allowed`.
    public var shellRefusal: ShellError?
    /// The screen backends this app can show for its kind (`ScreenBackends.supported(for:)`).
    public var viewerScreens: Set<String>
    public var now: Date

    public init(kind: HostKind, reach: HostReach, accessRefused: Bool = false, host: HostInfo? = nil, farewell: HostFarewell? = nil,
                connectingSince: Date? = nil, triedFromAnywhere: Bool = false, relay: RelayHealth = .unknown,
                shellRefusal: ShellError? = nil, viewerScreens: Set<String>? = nil, now: Date = Date()) {
        self.kind = kind; self.reach = reach; self.accessRefused = accessRefused; self.host = host; self.farewell = farewell
        self.connectingSince = connectingSince; self.triedFromAnywhere = triedFromAnywhere; self.relay = relay
        self.shellRefusal = shellRefusal; self.viewerScreens = viewerScreens ?? ScreenBackends.supported(for: kind); self.now = now
    }
}

/// What the page says about the connection.
public enum HostPageState: Equatable, Sendable {
    case connected(ShellPath?)
    case connecting, reconnecting
    /// Can't be reached, cause unknown.
    case unreachable
    case wentToSleep(at: Date), turnedOff(at: Date), shutDown(at: Date)
    /// Tried from anywhere and its relay didn't answer.
    case noRelay
    /// It used to let this phone in and now refuses the key.
    case revoked
    case pairedNoAccess
    /// The phone's own reasons, worded as before.
    case locked, needsPasscode, keyUnavailable
}

/// Whether a shell can start there (meaningful while connected).
public enum HostShellState: Equatable, Sendable {
    case available, nobodySignedIn, someoneElseSignedIn, appNotOpen, switchedOff
}

/// What the Screen row is.
public enum HostScreenState: Equatable, Sendable {
    /// A Mac (or, once this app has its viewer, a PC).
    case available
    /// The host offers only screens this app has no viewer for.
    case notInThisVersion
    case switchedOff, remoteDesktopOff, windowsHome, noPassword, remoteDesktopProblem
    /// Nothing offered and no reason given: no row.
    case noRow
}

/// The page for one computer, from one pure function, so every state has a test.
public struct HostPage: Equatable, Sendable {
    public var state: HostPageState
    public var shell: HostShellState
    public var screen: HostScreenState
    /// Try again is offered (unreachable, or connecting for a while).
    public var canRetry: Bool

    public init(state: HostPageState, shell: HostShellState, screen: HostScreenState, canRetry: Bool) {
        self.state = state; self.shell = shell; self.screen = screen; self.canRetry = canRetry
    }

    /// How long a connect runs before Try again is offered beside it.
    public static let retryAfter: TimeInterval = 30

    public static func make(_ input: HostPageInput) -> HostPage {
        var canRetry = false
        let state: HostPageState
        switch input.reach {
        case .locked: state = .locked
        case .needsPasscode: state = .needsPasscode
        case .keyUnavailable: state = .keyUnavailable
        case .noAccess: state = input.accessRefused ? .revoked : .pairedNoAccess
        case let .ready(path): state = .connected(path)
        case let .connecting(redialing):
            state = redialing ? .reconnecting : .connecting
            canRetry = input.connectingSince.map { input.now.timeIntervalSince($0) >= retryAfter } ?? false
        case .unreachable:
            canRetry = true
            // What the host said as it left beats what the phone can guess.
            if let farewell = input.farewell, let reason = GoingAwayReason(rawValue: farewell.reason) {
                switch reason {
                case .sleeping: state = .wentToSleep(at: farewell.at)
                case .turnedOff: state = .turnedOff(at: farewell.at)
                case .shuttingDown: state = .shutDown(at: farewell.at)
                }
            } else {
                state = input.triedFromAnywhere && input.relay == .silent ? .noRelay : .unreachable
            }
        }
        return HostPage(state: state, shell: shellState(input), screen: screenState(input), canRetry: canRetry)
    }

    static func shellState(_ input: HostPageInput) -> HostShellState {
        let host = input.host
        if host?.access?.shell == false || input.shellRefusal == .notAllowed { return .switchedOff }
        if host?.signedIn == false { return host?.console == "otherUser" ? .someoneElseSignedIn : .nobodySignedIn }
        if host?.console == "otherUser", input.shellRefusal == .signedOut { return .someoneElseSignedIn }
        if host?.app == false || input.shellRefusal == .signedOut { return .appNotOpen }
        return .available
    }

    static func screenState(_ input: HostPageInput) -> HostScreenState {
        switch input.kind {
        // A Mac's own refusals stay where they are (the screen view says them).
        case .mac: return .available
        case .other: return .noRow
        case .windows: break
        }
        guard let host = input.host else { return input.viewerScreens.isEmpty ? .notInThisVersion : .noRow }
        let offered = Set(host.screens ?? [])
        if !offered.isDisjoint(with: input.viewerScreens) { return .available }
        if input.viewerScreens.isEmpty, !offered.isEmpty { return .notInThisVersion }
        switch host.rdp {
        case "edition": return .windowsHome
        case "off": return .remoteDesktopOff
        case "account": return .noPassword
        case "service", "exposed", "policy": return .remoteDesktopProblem
        default: break
        }
        return host.access?.screen == false ? .switchedOff : .noRow
    }
}
