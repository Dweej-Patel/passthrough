#if os(macOS)
import Foundation
import IrohTransport
import PassthroughCore
import PhoneTransport

/// The Mac's remote-shell door over iroh: accepts phones' connections on the
/// shell ALPN from anywhere (iroh carries them direct or via a relay), and
/// admits only those that say `hello` and then prove a phone's shell key,
/// with the same handshake and connections as `ShellListener` (`ShellGate`).
/// Sessions are the manager's, so a phone can take one over from either path.
///
/// Before the QUIC handshake each attempt needs a pre-auth slot: at most 16
/// at once, 2 per remote IP (or network, `HandshakeLimiter.bucket`) on
/// direct paths, 8 arriving via relays; a slot lasts until the proof or the
/// 10 s timeout, whichever is first. Only attempts whose address QUIC has
/// validated get one (the rest are sent a retry first), so packets with
/// forged source addresses cannot hold slots.
public final class IrohShellListener: @unchecked Sendable {
    /// What relayed (and path-unknown) attempts are counted under, and their cap.
    static let relayBucket = "relay"
    static let maxRelayHandshakes = 8

    private let host: IrohEndpointHost
    let gate: ShellGate
    var queue: DispatchQueue { gate.queue }
    /// The accept loop; on the queue.
    private var loop: Task<Void, Never>?
    private let failureHandler = Locked<(@Sendable (Error) -> Void)?>(nil)

    /// Log-ready lines such as "Jane's iPhone opened a session": the phone's
    /// label and what it did, never anything typed or shown. On the listener's queue.
    public var onSessionEvent: (@Sendable (String) -> Void)? {
        get { gate.eventHandler.get() }
        set { gate.eventHandler.set(newValue) }
    }

    /// As `ShellListener.screenAllowed`.
    public var screenAllowed: (@Sendable (String) -> Bool)? {
        get { gate.screenAccess.get() }
        set { gate.screenAccess.set(newValue) }
    }

    /// As `ShellListener.screenSharingVerified`.
    public var screenSharingVerified: (@Sendable () async -> Bool)? {
        get { gate.screenSharingCheck.get() }
        set { gate.screenSharingCheck.set(newValue) }
    }

    /// As `ShellListener.screenVideo`.
    public var screenVideo: (@Sendable (_ phoneID: String) -> (any ScreenVideoSource)?)? {
        get { gate.screenVideoFactory.get() }
        set { gate.screenVideoFactory.set(newValue) }
    }

    /// As `ShellListener.screenViews`: give both listeners the same one.
    public var screenViews: ScreenViewLimit {
        get { gate.screenViews.get() }
        set { gate.screenViews.set(newValue) }
    }

    /// As `ShellListener.onScreenViewer`.
    public var onScreenViewer: (@Sendable (_ phoneID: String, _ label: String, _ viewing: Bool) -> Void)? {
        get { gate.screenHandler.get() }
        set { gate.screenHandler.set(newValue) }
    }

    /// As `ShellListener.macState`.
    public var macState: (@Sendable (_ phoneID: String) -> MacState?)? {
        get { gate.macStateProvider.get() }
        set { gate.macStateProvider.set(newValue) }
    }

    /// As `ShellListener.onMacControl`.
    public var onMacControl: (@Sendable (_ phoneID: String, _ label: String, _ change: MacControl) -> ShellError?)? {
        get { gate.macControl.get() }
        set { gate.macControl.set(newValue) }
    }

    /// As `ShellListener.macEvents`.
    public var macEvents: (@Sendable (_ phoneID: String, _ since: Double) -> (events: [MacEvent], battery: [BatterySample]))? {
        get { gate.eventsProvider.get() }
        set { gate.eventsProvider.set(newValue) }
    }

    /// As `ShellListener.pushMacState()`.
    public func pushMacState() { gate.pushMacState() }

    /// As `ShellListener.pushSessions()`.
    public func pushSessions() { gate.pushSessions() }

    /// The endpoint stopped accepting (it was shut down underneath the
    /// listener); it will not accept again. On the listener's queue.
    public var onFailure: (@Sendable (Error) -> Void)? {
        get { failureHandler.get() }
        set { failureHandler.set(newValue) }
    }

    /// The closures are `ShellListener`'s. `macInfo` is sent right after
    /// `ready`; its provider includes the relay token whenever one is
    /// configured. `host`'s lifetime stays the caller's: shut it down after
    /// `stop` to end the pending accept.
    public convenience init(host: IrohEndpointHost, manager: ShellSessionManager, transcripts: TranscriptStore,
                            shellKeys: @escaping @Sendable (String) -> [Data],
                            keyConfirmed: @escaping @Sendable (_ phoneID: String, _ key: Data) -> Void = { _, _ in },
                            phoneLabel: @escaping @Sendable (String) -> String,
                            macInfo: @escaping @Sendable () -> ShellEnvelope? = { nil }) {
        self.init(host: host, manager: manager, transcripts: transcripts, shellKeys: shellKeys, keyConfirmed: keyConfirmed,
                  phoneLabel: phoneLabel, macInfo: macInfo, handshakeTimeout: WirelessLink.handshakeTimeout)
    }

    /// `handshakeTimeout` is shorter in tests.
    init(host: IrohEndpointHost, manager: ShellSessionManager, transcripts: TranscriptStore,
         shellKeys: @escaping @Sendable (String) -> [Data],
         keyConfirmed: @escaping @Sendable (_ phoneID: String, _ key: Data) -> Void = { _, _ in },
         phoneLabel: @escaping @Sendable (String) -> String,
         macInfo: @escaping @Sendable () -> ShellEnvelope? = { nil },
         handshakeTimeout: TimeInterval) {
        self.host = host
        gate = ShellGate(label: "iroh-shell-listener", manager: manager, transcripts: transcripts, shellKeys: shellKeys,
                         keyConfirmed: keyConfirmed, phoneLabel: phoneLabel, macInfo: macInfo,
                         handshakeTimeout: handshakeTimeout)
    }

    /// Starts accepting. Run one listener per endpoint.
    public func start() {
        queue.async { [self] in
            guard loop == nil, !gate.stopped else { return }
            let host = self.host, gate = self.gate
            loop = Task.detached { [weak self] in
                while true {
                    let incoming: IrohIncoming
                    do {
                        incoming = try await host.accept(alpn: IrohShell.alpn)
                    } catch {
                        gate.queue.async {
                            guard !gate.stopped else { return }
                            ptLog(.error, "iroh: shell listener stopped accepting: \(error)")
                            self?.failureHandler.get()?(error)
                        }
                        return
                    }
                    guard gate.accepting.get(), let self else {
                        await incoming.refuse()
                        return
                    }
                    Task {
                        // A stateless round trip that proves the peer receives at its address.
                        guard await incoming.isAddressValidated() else {
                            if await !incoming.retry() { await incoming.refuse() }
                            return
                        }
                        let origin = await incoming.origin()
                        gate.queue.async { self.admit(incoming, path: origin.path, ip: origin.ip) }
                    }
                }
            }
            ptLog(.info, "iroh: shell listener started")
        }
    }

    /// Stops accepting and drops every connection; sessions keep running.
    /// `completion` runs on the listener's queue once no connection can open
    /// a session. An accept already waiting on the endpoint turns its attempt
    /// away; shut the endpoint down to end it.
    public func stop(completion: (@Sendable () -> Void)? = nil) {
        gate.accepting.set(false)
        queue.async { [self] in
            gate.stop()
            loop?.cancel(); loop = nil
            if let completion { gate.afterWork(completion) }
        }
    }

    /// Drops every iroh connection of this phone at once (it was revoked) and
    /// ends the sessions it opened (`ShellListener.disconnect`). Call after
    /// its keys are gone from `shellKeys`.
    public func disconnect(phoneID: String) {
        gate.disconnect(phoneID: phoneID)
    }

    /// Ends this phone's views of the screen; its shell connections stay.
    public func disconnectScreen(phoneID: String) {
        gate.disconnectScreen(phoneID: phoneID)
    }

    /// How each connected phone is carried right now, for status: direct if
    /// any of its connections is, else via a relay if any is. `completion`
    /// runs on the listener's queue.
    public func connectionPaths(completion: @escaping @Sendable ([String: IrohPath]) -> Void) {
        queue.async { [gate] in
            var paths: [String: IrohPath] = [:]
            for (phoneID, stream) in gate.openStreams {
                guard let stream = stream as? IrohByteStream else { continue }
                paths[phoneID] = Self.preferred(paths[phoneID] ?? .unknown, stream.pathKind)
            }
            completion(paths)
        }
    }

    static func preferred(_ a: IrohPath, _ b: IrohPath) -> IrohPath {
        if a == .direct || b == .direct { return .direct }
        if a == .relay || b == .relay { return .relay }
        return .unknown
    }

    /// Handshakes holding a slot now (tests).
    var pendingHandshakes: Int { queue.sync { gate.pendingHandshakes } }

    /// The limiter bucket for an attempt: its IP on a direct path (with the
    /// per-host cap), else the shared relay bucket.
    static func bucket(path: IrohPath, ip: String?) -> (key: String, max: Int?) {
        if path == .direct, let ip { return (ip, nil) }
        return (relayBucket, maxRelayHandshakes)
    }

    /// On the queue: a slot or a refusal, before the QUIC handshake; then the
    /// handshake and the stream, then the shared shell handshake.
    private func admit(_ incoming: IrohIncoming, path: IrohPath, ip: String?) {
        let (key, max) = Self.bucket(path: path, ip: ip)
        // At the timeout an attempt still without a stream is cancelled, so a
        // late-completing accept fails (or is closed by `runHandshake`).
        guard let admission = gate.admit(host: key, maxForHost: max, abandon: { incoming.cancel() }) else {
            ptLog(.warning, "iroh: refused a connection: too many unproven handshakes")
            Task { await incoming.refuse() }
            return
        }
        let gate = self.gate
        Task {
            do {
                let stream = try await incoming.acceptStream()
                gate.queue.async { gate.runHandshake(admission, stream: stream, expectHello: true) }
            } catch {
                gate.queue.async { gate.abandon(admission) }
            }
        }
    }
}
#endif
