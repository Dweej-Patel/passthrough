import Foundation

/// When the Mac app may re-register a privileged helper that launchd still
/// lists as enabled but that no longer answers (e.g. it was booted out): once
/// per series of connect attempts, so retries never loop re-registrations,
/// and never while something routes through the helper.
public struct HelperRecoveryPolicy: Equatable, Sendable {
    public private(set) var attempted = false

    public init() {}

    /// True (and the attempt is used up) when a registered helper did not
    /// respond, nothing uses it (`inUse`: a tunnel or the VPN layer), and this
    /// series has not re-registered it yet.
    public mutating func shouldReregister(registered: Bool, responded: Bool, inUse: Bool) -> Bool {
        guard registered, !responded, !inUse, !attempted else { return false }
        attempted = true
        return true
    }

    /// A new series: a phone attached over USB, or the user asked to connect.
    public mutating func reset() { attempted = false }
}

/// Which attached phones already hold a shell key with the current grant
/// contents over this cable connection, so tunnel retries don't hand out a
/// fresh key each time while a change in what grants carry (certificate,
/// port, iroh endpoint, relay) still reaches the phone. One grant per device
/// is in flight at a time; each confirmation names the grant it answers.
/// A phone that never answers is re-granted with backoff, then slowly.
public struct ShellGrantLedger: Equatable, Sendable {
    public struct InFlight: Equatable, Sendable {
        public var contents: String
        public var grantID: String
    }
    /// Consecutive unanswered grants of the same contents to one device.
    private struct Backoff: Equatable, Sendable {
        var contents: String
        var timeouts: Int
        var notBefore: Date
    }
    private var granted: [String: String] = [:]
    private var inFlight: [String: InFlight] = [:]
    private var backoff: [String: Backoff] = [:]
    /// Devices whose access was just revoked: no grant until a new control
    /// channel opens to them, or they pair anew.
    private var held: Set<String> = []

    public init() {}

    /// A fingerprint of what a grant tells the phone, besides the key itself.
    /// Addresses are left out: they change with the network and phones learn
    /// them from `macInfo`.
    public static func contents(certificateSHA256: String, port: UInt16, macName: String,
                                irohID: String?, irohRelay: String?, relayToken: String?) -> String {
        [certificateSHA256, String(port), macName, irohID ?? "-", irohRelay ?? "-", relayToken ?? "-"]
            .map { "\($0.utf8.count):\($0)" }.joined()
    }

    /// Whether to send a grant with these contents to this device now: not
    /// while one is in flight (re-check once it is answered), not while held,
    /// not when the phone already holds these contents, and not while backing
    /// off after unanswered grants of these same contents (other contents
    /// start afresh).
    public func shouldGrant(deviceID: String, contents: String, now: Date = Date()) -> Bool {
        guard !held.contains(deviceID), inFlight[deviceID] == nil, granted[deviceID] != contents else { return false }
        if let b = backoff[deviceID], b.contents == contents, now < b.notBefore { return false }
        return true
    }

    /// Whether the phone's answer, echoing `echoedGrantID`, is for grant
    /// `inFlightGrantID`. Phones that predate grant IDs echo none; their
    /// answer is taken for the grant in flight (one per device), which can
    /// misattribute an answer that arrives after its grant expired.
    public static func answerMatches(echoedGrantID: String?, inFlightGrantID: String) -> Bool {
        echoedGrantID.map { $0 == inFlightGrantID } ?? true
    }

    public func isHeld(deviceID: String) -> Bool { held.contains(deviceID) }

    /// A grant went out and awaits the phone's answer.
    public mutating func sent(deviceID: String, contents: String, grantID: String) {
        inFlight[deviceID] = InFlight(contents: contents, grantID: grantID)
        if let b = backoff[deviceID], b.contents != contents { backoff[deviceID] = nil }
    }

    /// The phone stored the key of grant `grantID`. False (nothing recorded)
    /// when that grant is no longer the one in flight, e.g. it was revoked.
    @discardableResult
    public mutating func confirmed(deviceID: String, grantID: String) -> Bool {
        guard let pending = inFlight[deviceID], pending.grantID == grantID else { return false }
        inFlight[deviceID] = nil
        granted[deviceID] = pending.contents
        backoff[deviceID] = nil
        return true
    }

    /// How long a grant may wait for the phone's answer. A phone that
    /// can't store the key may never answer; past this the grant counts as
    /// lost so later grants (changed contents included) aren't blocked.
    public static let answerTimeout: TimeInterval = 15

    /// How long to wait before re-granting after the 1st, 2nd, ... consecutive
    /// unanswered grant (counted from the end of `answerTimeout`); after
    /// that, `slowRetryDelay` each time, until a new channel, a new pairing,
    /// a change in contents or an answer starts afresh.
    public static let retryDelays: [TimeInterval] = [15, 30, 60, 120]
    /// The wait once `retryDelays` are used up, so a phone that was briefly
    /// unable to store a key (e.g. locked) still gets one without a re-plug.
    public static let slowRetryDelay: TimeInterval = 600

    public enum Expiry: Equatable, Sendable {
        /// The grant was answered, replaced or dropped meanwhile: nothing to do.
        case stale
        /// Grant again after `delay`; `firstTimeout` starts a new streak.
        case retry(after: TimeInterval, firstTimeout: Bool)
    }

    /// The answer to grant `grantID` did not come in time. Unless that grant
    /// was answered, replaced or dropped meanwhile, the device may be granted
    /// again after a growing delay (`retryDelays`, then `slowRetryDelay`),
    /// reset by `channelOpened`, `paired`, a change in contents or a
    /// confirmation.
    @discardableResult
    public mutating func expired(deviceID: String, grantID: String, now: Date = Date()) -> Expiry {
        guard let pending = inFlight[deviceID], pending.grantID == grantID else { return .stale }
        inFlight[deviceID] = nil
        let previous = backoff[deviceID].flatMap { $0.contents == pending.contents ? $0.timeouts : nil } ?? 0
        let timeouts = previous + 1
        let delay = timeouts <= Self.retryDelays.count ? Self.retryDelays[timeouts - 1] : Self.slowRetryDelay
        backoff[deviceID] = Backoff(contents: pending.contents, timeouts: timeouts, notBefore: now.addingTimeInterval(delay))
        return .retry(after: delay, firstTimeout: timeouts == 1)
    }

    /// The control channel closed before the phone answered: try again on the next one.
    public mutating func channelClosed(deviceID: String) { inFlight[deviceID] = nil }

    /// A new control channel to this device opened: a fresh start.
    public mutating func channelOpened(deviceID: String) {
        held.remove(deviceID)
        backoff[deviceID] = nil
    }

    /// This device paired anew: it gets a grant even after a revoke.
    public mutating func paired(deviceID: String) {
        held.remove(deviceID)
        backoff[deviceID] = nil
    }

    /// The cable was unplugged: the next connection grants again.
    public mutating func detached(deviceID: String) {
        inFlight[deviceID] = nil
        granted[deviceID] = nil
        backoff[deviceID] = nil
        held.remove(deviceID)
    }

    /// This device's shell access was revoked: forget its grants (an answer
    /// to one in flight is ignored) and send none until `channelOpened` or
    /// `paired`. Other devices are untouched.
    public mutating func revoked(deviceID: String) {
        inFlight[deviceID] = nil
        granted[deviceID] = nil
        backoff[deviceID] = nil
        held.insert(deviceID)
    }

    /// Remote shell was turned on again, or a pairing was forgotten.
    public mutating func reset() { self = ShellGrantLedger() }
}

/// Reopening a control channel kept only for the shell when the phone keeps
/// refusing it (its app not running): 10 s, doubling to at most 120 s, and
/// one log line per streak of failures.
public struct ShellChannelBackoff: Equatable, Sendable {
    public private(set) var failures = 0

    public init() {}

    /// Records a failure; returns how long to wait and whether to log it.
    public mutating func failed() -> (delay: TimeInterval, log: Bool) {
        failures += 1
        let delay = min(120, 10 * pow(2, Double(min(failures - 1, 4))))
        return (delay, failures == 1)
    }

    /// The phone answered; the next failure starts a new streak.
    public mutating func succeeded() { failures = 0 }
}
