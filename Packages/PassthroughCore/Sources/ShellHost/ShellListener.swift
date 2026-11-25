#if os(macOS)
import Foundation
import Network
import CryptoKit
import PassthroughCore
import PhoneTransport

/// A phone's `computerGrant`, as the app is asked to decide it.
public struct ComputerGrantRequest: Sendable, Equatable {
    /// What this Mac lists the computer as.
    public var name: String
    /// The computer's own host id as the phone knows it: granting it again replaces it.
    public var viewer: String
    /// `HostInfo.kindMac`, `kindWindows`, or nil.
    public var kind: String?
    /// The computer's identity public key (a 65-byte point).
    public var identityKey: Data
    /// What it may do, as `Computers.validScopes` keeps them.
    public var scopes: [String]

    public init(name: String, viewer: String, kind: String?, identityKey: Data, scopes: [String]) {
        self.name = name; self.viewer = viewer; self.kind = kind; self.identityKey = identityKey; self.scopes = scopes
    }
}

/// The Mac's remote-shell door (protocol/README.md, "Remote shell"): a TLS 1.3
/// listener that admits only peers on private networks, and only connections
/// that prove a phone's shell key, to the sessions in `manager`. The
/// handshake after the stream is open, and the connections it admits, are
/// `ShellGate`'s, shared with `IrohShellListener`.
public final class ShellListener: @unchecked Sendable {
    /// The proof line is read before the peer has proved anything; it needs
    /// a couple of hundred bytes.
    static let proofLineLimit = ShellGate.proofLineLimit

    private let identity: MacIdentity
    private let requestedPort: UInt16
    private let advertise: Bool
    private let peerAllowed: @Sendable (String) -> Bool
    private let arrivalAllowed: @Sendable (_ peer: String, _ local: String?) -> Bool
    /// The Mac's address a connection arrived on, as its path tells (tests
    /// make it unknown). Set before `start`.
    var localAddress: @Sendable (NWPath?) -> String? = { $0?.localEndpoint.map(PeerAddress.host(of:)) }
    let gate: ShellGate
    /// Everything below, and every connection's state, lives on this queue.
    var queue: DispatchQueue { gate.queue }
    private var listener: NWListener?
    /// The NWListener has failed or been cancelled: its port is free.
    private var finished = false
    /// Called once the cancelled NWListener has let go of its port.
    private var onCancelled: [() -> Void] = []
    private let failureHandler = Locked<(@Sendable (Error) -> Void)?>(nil)
    private let boundPort = Locked<UInt16?>(nil)

    /// The TCP port once listening.
    public private(set) var port: UInt16? {
        get { boundPort.get() }
        set { boundPort.set(newValue) }
    }

    /// Log-ready lines such as "Jane's iPhone opened a session": the phone's
    /// label and what it did, never anything typed or shown. On the listener's queue.
    public var onSessionEvent: (@Sendable (String) -> Void)? {
        get { gate.eventHandler.get() }
        set { gate.eventHandler.set(newValue) }
    }

    /// Whether a phone may also see the screen (a `screen` request). Asked on
    /// the listener's queue for every request, so it must not block. Until
    /// it is set no phone may.
    public var screenAllowed: (@Sendable (String) -> Bool)? {
        get { gate.screenAccess.get() }
        set { gate.screenAccess.set(newValue) }
    }

    /// Whether what listens on Screen Sharing's port is macOS's own Screen
    /// Sharing, asked before every `screen` relay (off the queue, so it may
    /// take a while). The phone sends the Mac account's password down the
    /// relay, and any process of the user's can listen on that port while
    /// Screen Sharing is off. False, or unset: the phone is told
    /// `screen_unavailable` and nothing is dialled.
    public var screenSharingVerified: (@Sendable () async -> Bool)? {
        get { gate.screenSharingCheck.get() }
        set { gate.screenSharingCheck.set(newValue) }
    }

    /// Makes the Mac's own screen stream for a phone's `screenVideo` request
    /// (protocol/README.md, "Screen video"), or nil when it can't: then the
    /// phone is told `screen_video_unavailable`. Asked on the listener's
    /// queue after `screenAllowed`, so it must not block. Unset: never.
    public var screenVideo: (@Sendable (_ phoneID: String, _ label: String) -> (any ScreenVideoSource)?)? {
        get { gate.screenVideoFactory.get() }
        set { gate.screenVideoFactory.set(newValue) }
    }

    /// Makes clipboard sync for a screen pass's or a computer's `clipSync`
    /// request, or says why not (`no_screen_view`, `clip_sync_off`,
    /// `clip_sync_unavailable`). Phones are refused before it's asked. Asked
    /// on the listener's queue, so it must not block. Unset: unavailable.
    public var clipSync: (@Sendable (_ id: String, _ label: String) -> Result<any ClipSyncSource, ShellError>)? {
        get { gate.clipSyncFactory.get() }
        set { gate.clipSyncFactory.set(newValue) }
    }

    /// A phone started (`viewing`) or stopped seeing the screen. On the listener's queue.
    public var onScreenViewer: (@Sendable (_ phoneID: String, _ label: String, _ viewing: Bool) -> Void)? {
        get { gate.screenHandler.get() }
        set { gate.screenHandler.set(newValue) }
    }

    /// How many views of the screen may be open at once. Give both
    /// listeners the same one so the caps hold across them; set before `start`.
    public var screenViews: ScreenViewLimit {
        get { gate.screenViews.get() }
        set { gate.screenViews.set(newValue) }
    }

    /// What a phone is told about the Mac (`macState`): after `ready`, and
    /// to every shell connection on `pushMacState()`. Nil sends nothing.
    /// Asked on the listener's queue, so it must not block. Unset: never sent.
    public var macState: (@Sendable (_ phoneID: String) -> MacState?)? {
        get { gate.macStateProvider.get() }
        set { gate.macStateProvider.set(newValue) }
    }

    /// A phone asked to change Keep awake or the VPN: nil accepts it (the
    /// new state follows through `pushMacState()`, and that phone gets a
    /// `macState` a second later either way), an error refuses it.
    /// Asked on the listener's queue, so it must not block. Unset: refused
    /// as `bad_request`, as a Mac that doesn't know the request would.
    public var onMacControl: (@Sendable (_ phoneID: String, _ label: String, _ change: MacControl) -> ShellError?)? {
        get { gate.macControl.get() }
        set { gate.macControl.set(newValue) }
    }

    /// A phone asking for notices (`registration`) or to stop them (nil).
    /// Returns whether this Mac will send it any (it has a push key). Asked
    /// on the listener's queue, so it must not block. Unset: answered false.
    public var onPushRegistration: (@Sendable (_ phoneID: String, _ registration: PushRegistration?) -> Bool)? {
        get { gate.pushRegistration.get() }
        set { gate.pushRegistration.set(newValue) }
    }

    /// What happened on the Mac since a time, and its battery meanwhile, for
    /// a phone's `events` request (oldest first). Asked on the listener's
    /// queue, so it must not block. Unset: answered `bad_request`.
    public var macEvents: (@Sendable (_ phoneID: String, _ since: Double) -> (events: [MacEvent], battery: [BatterySample]))? {
        get { gate.eventsProvider.get() }
        set { gate.eventsProvider.set(newValue) }
    }

    /// Whether a phone ID is a screen-only pass (`ScreenPass`): it may ask for
    /// the screen and nothing else. Asked on the listener's queue once per
    /// connection, so it must not block. Unset: none is.
    public var screenOnly: (@Sendable (String) -> Bool)? {
        get { gate.screenOnlyCheck.get() }
        set { gate.screenOnlyCheck.set(newValue) }
    }

    /// What the host says about itself to a phone, by phone ID (`host`, after
    /// `macInfo`; never to a screen-only pass). Asked on the listener's queue
    /// once per connection, so it must not block. Unset: no `host` is sent.
    public var hostInfo: (@Sendable (String) -> HostInfo?)? {
        get { gate.hostInfoProvider.get() }
        set { gate.hostInfoProvider.set(newValue) }
    }

    /// A phone asking for a screen-only pass for another device it calls
    /// `name` and knows as `viewer`: the new pass's id and key, or why not.
    /// Run off the listener's queue (it writes the Keychain). Unset: `bad_request`.
    public var onScreenGrant: (@Sendable (_ phoneID: String, _ label: String, _ name: String, _ viewer: String) -> Result<(id: String, key: Data), ShellError>)? {
        get { gate.screenGrant.get() }
        set { gate.screenGrant.set(newValue) }
    }

    /// A phone handing this Mac a pass to view another Mac's screen: whether
    /// it was kept. Run off the listener's queue. Unset: `bad_request`.
    public var onScreenPass: (@Sendable (_ phoneID: String, _ label: String, _ pass: ShellCredential) -> Bool)? {
        get { gate.screenPass.get() }
        set { gate.screenPass.set(newValue) }
    }

    /// A phone taking back a screen pass it was granted (`viewerID`) and
    /// couldn't hand over: whether it was removed. Run off the listener's queue.
    public var onScreenRevoke: (@Sendable (_ phoneID: String, _ viewerID: String) -> Bool)? {
        get { gate.screenRevoke.get() }
        set { gate.screenRevoke.set(newValue) }
    }

    /// A screen pass proved its key and connected (so its viewer has it).
    /// Called off the listener's queue.
    public var onScreenPassUsed: (@Sendable (_ viewerID: String) -> Void)? {
        get { gate.screenPassUsed.get() }
        set { gate.screenPassUsed.set(newValue) }
    }

    /// A computer's identity public key, by its id (`Computers`): its proof must also be signed with
    /// it, bound to this listener. Asked on the listener's queue for every handshake by a computer id,
    /// so it must not block. Unset (or nil): no computer gets in.
    public var computerKey: (@Sendable (String) -> Data?)? {
        get { gate.computerKeyLookup.get() }
        set { gate.computerKeyLookup.set(newValue) }
    }

    /// What a computer may do now (`Computers.scopeShell`, `scopeScreen`). Asked on the listener's
    /// queue for every request it makes, so it must not block. Unset: nothing.
    public var computerScopes: (@Sendable (String) -> Set<String>)? {
        get { gate.computerScopesLookup.get() }
        set { gate.computerScopesLookup.set(newValue) }
    }

    /// The computers a phone gave access here (`computerList`), oldest first; `computerPresence` says which are connected.
    public var computerList: (@Sendable (String) -> [ComputerAccess])? {
        get { gate.computerListProvider.get() }
        set { gate.computerListProvider.set(newValue) }
    }

    /// Which computers are connected, for phones' lists: give both listeners the same one, so a
    /// computer on either shows as connected on both, and both push the lists when one comes or
    /// goes. Set before `start`. Unset: this listener's own.
    public var computerPresence: ComputerPresence {
        get { gate.computerPresence }
        set { gate.useComputerPresence(newValue) }
    }

    /// A computer proved its key and connected (so it has that grant). Called off the listener's queue.
    public var onComputerUsed: (@Sendable (_ computerID: String) -> Void)? {
        get { gate.computerUsed.get() }
        set { gate.computerUsed.set(newValue) }
    }

    /// Sends the computer list again to every phone that asked for it on its connection (a grant changed).
    public func pushComputerLists() { gate.pushComputerLists() }

    /// A phone asking this Mac to give another computer access: the new id and key and the scopes
    /// granted, or why not. Run off the listener's queue (it writes the Keychain). Unset: `bad_request`.
    public var onComputerGrant: (@Sendable (_ phoneID: String, _ label: String, _ request: ComputerGrantRequest) -> Result<(id: String, key: Data, scopes: [String]), ShellError>)? {
        get { gate.computerGrant.get() }
        set { gate.computerGrant.set(newValue) }
    }

    /// A phone handing this Mac access to another computer: nil when kept, else why not
    /// (`pass_conflict`, `pass_not_saved`). Run off the listener's queue. Unset: `bad_request`.
    public var onComputerPass: (@Sendable (_ phoneID: String, _ label: String, _ pass: ShellCredential, _ scopes: [String], _ pending: [String]) -> ShellError?)? {
        get { gate.computerPass.get() }
        set { gate.computerPass.set(newValue) }
    }

    /// A phone taking back a computer's access it got (`computerID`) and couldn't hand over: whether
    /// it was removed. Run off the listener's queue. Unset: `bad_request`.
    public var onComputerRevoke: (@Sendable (_ phoneID: String, _ computerID: String) -> Bool)? {
        get { gate.computerRevoke.get() }
        set { gate.computerRevoke.set(newValue) }
    }

    /// Sends every connected phone the Mac's state again (it changed).
    public func pushMacState() { gate.pushMacState() }

    /// Sends every connected phone the session list (it changed: a session
    /// opened, ended, or started or stopped waiting on a question).
    public func pushSessions() { gate.pushSessions() }

    /// The listener stopped for good (the port is taken, say); it will not
    /// accept again, so make a new one. On the listener's queue.
    public var onFailure: (@Sendable (Error) -> Void)? {
        get { failureHandler.get() }
        set { failureHandler.set(newValue) }
    }

    /// `shellKeys` returns the keys a proof from the phone of that ID may use,
    /// its current key first (then the previous one while still accepted;
    /// none for an unknown phone); `keyConfirmed` is told, off the listener's
    /// queue, when a phone proved its current key, and which key that was.
    /// `phoneLabel` names it for logs and history. `macInfo` is sent right
    /// after `ready` when it returns an envelope (see `ShellGate`). The
    /// closures run on the listener's queue for every handshake, so they must
    /// not block (no Keychain reads: `ShellAccessStore` answers from memory).
    /// `advertise` is false in tests. `peerAllowed` decides on the peer's
    /// address; `arrivalAllowed` on the peer's and the Mac's address it
    /// arrived on (nil while unknown: false makes the listener wait until the
    /// connection knows it, and refuse it if it never does). Both run before
    /// TLS. `provenAddresses` keeps the addresses that proved themselves
    /// across launches (`HandshakeLimiter`).
    public init(identity: MacIdentity, port: UInt16 = RemoteShell.defaultPort, advertise: Bool = true,
                manager: ShellSessionManager, transcripts: TranscriptStore,
                shellKeys: @escaping @Sendable (String) -> [Data],
                keyConfirmed: @escaping @Sendable (_ phoneID: String, _ key: Data) -> Void = { _, _ in },
                phoneLabel: @escaping @Sendable (String) -> String,
                peerAllowed: @escaping @Sendable (String) -> Bool = ShellListener.defaultPeerAllowed,
                arrivalAllowed: @escaping @Sendable (_ peer: String, _ local: String?) -> Bool = ShellListener.defaultArrivalAllowed,
                provenAddresses: ProvenAddressStore = MemoryProvenAddressStore(),
                macInfo: @escaping @Sendable () -> ShellEnvelope? = { nil }) {
        self.identity = identity
        self.requestedPort = port
        self.advertise = advertise
        self.peerAllowed = peerAllowed
        self.arrivalAllowed = arrivalAllowed
        // A computer's signature is bound to the certificate this listener presents.
        gate = ShellGate(label: "shell-listener", manager: manager, transcripts: transcripts, shellKeys: shellKeys,
                         keyConfirmed: keyConfirmed, phoneLabel: phoneLabel, macInfo: macInfo,
                         provenAddresses: provenAddresses,
                         binding: ShellGate.Binding(path: .tls, hostBinding: Data(SHA256.hash(data: identity.certificate))))
    }

    /// The address policy, with global IPv6 peers checked against the Mac's
    /// own /64s, and overlay (Tailscale-range) peers against the Mac's own
    /// overlay tunnel addresses, as they are now (interfaces come and go).
    public static func defaultPeerAllowed(_ host: String) -> Bool {
        ShellAddressPolicy.isAllowedPeer(host, localAddresses: LocalAddresses.withInterfaces(),
                                         onLinkPrefixes: LocalAddresses.onLinkPrefixes())
    }

    /// `ShellAddressPolicy.arrivedOnItsNetwork` against the Mac's addresses as they are now.
    public static func defaultArrivalAllowed(_ peer: String, _ local: String?) -> Bool {
        ShellAddressPolicy.arrivedOnItsNetwork(peer: peer, local: local, localAddresses: LocalAddresses.withInterfaces())
    }

    public func start(onReady: (@Sendable (UInt16) -> Void)? = nil) throws {
        let params = try identity.tlsListenerParameters()
        // Turning the shell off and on binds the same port again at once.
        params.allowLocalEndpointReuse = true
        let listener: NWListener
        if requestedPort == 0 {
            listener = try NWListener(using: params)
        } else {
            guard let port = NWEndpoint.Port(rawValue: requestedPort) else { throw ShellError.badRequest }
            listener = try NWListener(using: params, on: port)
        }
        if advertise { listener.service = NWListener.Service(type: RemoteShell.serviceType) }
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            switch state {
            case .ready:
                let port = listener?.port?.rawValue
                self?.port = port
                if let port { onReady?(port) }
                ptLog(.info, "shell: listening on port \(port ?? 0)")
            case .waiting(let error):
                ptLog(.warning, "shell: listener waiting (\(error))")
            case .failed(let error):
                ptLog(.error, "shell: listener failed: \(error)")
                self?.finish()
                self?.failureHandler.get()?(error)
            case .cancelled:
                self?.finish()
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.start(queue: queue)
        self.listener = listener
    }

    /// Stops listening and drops every connection; sessions keep running.
    /// `completion` runs (on the listener's queue) once the port is free, so a
    /// new listener can bind it; no connection can open a session after that.
    public func stop(completion: (@Sendable () -> Void)? = nil) {
        gate.accepting.set(false)
        queue.async { [self] in
            gate.stop()
            port = nil
            if let completion {
                // Also after any session being opened on `work` is open, so the caller can end it.
                let done = { [gate] in gate.afterWork(completion) }
                if finished || listener == nil { done() } else { onCancelled.append(done) }
            }
            listener?.cancel(); listener = nil
        }
    }

    /// On the queue: the NWListener is done with its port.
    private func finish() {
        finished = true
        let waiting = onCancelled
        onCancelled = []
        waiting.forEach { $0() }
    }

    /// Drops every connection of this phone at once (it was revoked) and ends
    /// the sessions it opened, including one being opened right now. Sessions
    /// other phones opened keep running. Call after its keys are gone from
    /// `shellKeys`, so it cannot prove itself again.
    public func disconnect(phoneID: String) {
        gate.disconnect(phoneID: phoneID)
    }

    /// Ends this phone's views of the screen; its shell connections stay.
    public func disconnectScreen(phoneID: String) {
        gate.disconnectScreen(phoneID: phoneID)
    }

    /// On `queue`: policy and a handshake slot before TLS, then the shared handshake.
    private func accept(_ connection: NWConnection) {
        let host = PeerAddress.host(of: connection)
        // Known before the connection starts, for an accepted one (`AcceptedPathTests`).
        let local = localAddress(connection.currentPath)
        // Before TLS: a peer outside the private ranges gets nothing at all.
        // One the policy refuses only for want of `local` waits for it (`awaitArrival`).
        let arrived = arrivalAllowed(host, local)
        guard !gate.stopped, peerAllowed(host), arrived || local == nil else {
            ptLog(.warning, "shell: refused a connection from outside the allowed networks")
            connection.cancel(); return
        }
        guard let admission = gate.admit(host: host, abandon: { connection.cancel() }) else {
            connection.cancel(); return
        }
        guard arrived else { return awaitArrival(connection, host: host, admission: admission) }
        gate.runHandshake(admission, stream: ConnectionStream(connection, queue: queue), expectHello: false)
    }

    /// On `queue`: a connection whose arrival must be known to be let in, and
    /// isn't yet. Started, it learns its path (before TLS completes, as a
    /// rule): then it goes on or is dropped. One still without a local
    /// address once TLS is up is dropped before anything is read from it.
    /// Its slot is held meanwhile, so the timeout bounds the wait.
    private func awaitArrival(_ connection: NWConnection, host: String, admission: ShellGate.Admission) {
        let decided = Locked(false), localAddress = self.localAddress
        let decide: @Sendable (String?, Bool) -> Void = { [weak self] local, final in
            guard let self, !decided.get(), local != nil || final else { return }
            decided.set(true)
            connection.pathUpdateHandler = nil
            connection.stateUpdateHandler = nil
            guard self.arrivalAllowed(host, local) else {
                ptLog(.warning, "shell: refused a connection that did not arrive on its network")
                self.gate.abandon(admission); connection.cancel(); return
            }
            self.gate.runHandshake(admission, stream: ConnectionStream(connection, queue: self.queue), expectHello: false)
        }
        connection.pathUpdateHandler = { path in decide(localAddress(path), false) }
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                decide(localAddress(connection.currentPath), true)
            case .failed, .cancelled:
                guard !decided.get() else { return }
                decided.set(true)
                self?.gate.abandon(admission)
            default:
                break
            }
        }
        connection.start(queue: queue)
    }
}

/// Views of the screen open at once, per phone and in all: each one captures
/// and encodes (or relays) the whole screen, so a phone, even an authorized
/// one, cannot open them without end. Shared by both listeners.
public final class ScreenViewLimit: @unchecked Sendable {
    public static let maxPerPhone = RemoteShell.maxScreenViewsPerPhone
    public static let maxTotal = RemoteShell.maxScreenViews

    private let lock = NSLock()
    private var open: [String: Int] = [:]
    private let maxPerPhone: Int
    private let maxTotal: Int

    public init(maxPerPhone: Int = ScreenViewLimit.maxPerPhone, maxTotal: Int = ScreenViewLimit.maxTotal) {
        self.maxPerPhone = maxPerPhone
        self.maxTotal = maxTotal
    }

    /// A view for `phoneID`, or false when it has its share or all are taken.
    func take(_ phoneID: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard open.values.reduce(0, +) < maxTotal, open[phoneID, default: 0] < maxPerPhone else { return false }
        open[phoneID, default: 0] += 1
        return true
    }

    func release(_ phoneID: String) {
        lock.lock(); defer { lock.unlock() }
        let left = (open[phoneID] ?? 1) - 1
        open[phoneID] = left > 0 ? left : nil
    }

    /// Views open now (tests).
    var count: Int { lock.lock(); defer { lock.unlock() }; return open.values.reduce(0, +) }
}

/// The computers with a connection open, counted across the listeners that share it, so a phone's
/// `computerList` says connected whichever path the computer came in on. When one comes or goes,
/// every listener sharing it sends its phones the list again.
public final class ComputerPresence: @unchecked Sendable {
    private struct Watcher {
        weak var gate: ShellGate?
    }

    private let lock = NSLock()
    private var open: [String: Int] = [:]
    private var watchers: [Watcher] = []

    public init() {}

    /// Whether the computer has a connection open on any listener sharing this.
    public func isConnected(_ id: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return open[id] != nil
    }

    func watch(_ gate: ShellGate) {
        lock.lock(); defer { lock.unlock() }
        watchers.removeAll { $0.gate == nil || $0.gate === gate }
        watchers.append(Watcher(gate: gate))
    }

    func unwatch(_ gate: ShellGate) {
        lock.lock(); defer { lock.unlock() }
        watchers.removeAll { $0.gate == nil || $0.gate === gate }
    }

    func opened(_ id: String) {
        lock.lock()
        open[id, default: 0] += 1
        let first = open[id] == 1
        lock.unlock()
        if first { changed() }
    }

    func closed(_ id: String) {
        lock.lock()
        let left = (open[id] ?? 1) - 1
        open[id] = left > 0 ? left : nil
        let last = left <= 0
        lock.unlock()
        if last { changed() }
    }

    /// Never under the lock: each gate hops onto its own queue.
    private func changed() {
        lock.lock(); let gates = watchers.compactMap(\.gate); lock.unlock()
        gates.forEach { $0.pushComputerLists() }
    }
}

/// What both shell listeners share once a stream is open: pre-auth slots,
/// the handshake (an optional `hello` line, challenge, proof, `ready`,
/// `macInfo`), and the authorized connections it admits to the sessions in
/// `manager`. All its state, and every connection's, lives on `queue`.
final class ShellGate: @unchecked Sendable {
    /// The first line and the proof line are read before the peer has proved
    /// anything; a proof needs a couple of hundred bytes.
    static let proofLineLimit = 4096

    let queue: DispatchQueue
    /// Where a connection's slow requests run (starting a shell), so the
    /// queue above never waits on them. Serial on purpose: requests run in the
    /// order they arrived, and `stop` drains it with one barrier.
    let work: DispatchQueue
    /// False once `stop` has begun: work still queued must not open a session.
    let accepting = Locked(true)
    let manager: ShellSessionManager
    let transcripts: TranscriptStore
    let eventHandler = Locked<(@Sendable (String) -> Void)?>(nil)
    let screenAccess = Locked<(@Sendable (String) -> Bool)?>(nil)
    let screenHandler = Locked<(@Sendable (_ phoneID: String, _ label: String, _ viewing: Bool) -> Void)?>(nil)
    let screenVideoFactory = Locked<(@Sendable (String, String) -> (any ScreenVideoSource)?)?>(nil)
    let screenViews = Locked(ScreenViewLimit())
    let clipSyncFactory = Locked<(@Sendable (String, String) -> Result<any ClipSyncSource, ShellError>)?>(nil)
    /// `ShellListener.screenSharingVerified`.
    let screenSharingCheck = Locked<(@Sendable () async -> Bool)?>(nil)
    /// Where `screen` requests are relayed; another port in tests.
    let screenPort = Locked(RemoteShell.screenSharingPort)
    let macStateProvider = Locked<(@Sendable (String) -> MacState?)?>(nil)
    let macControl = Locked<(@Sendable (_ phoneID: String, _ label: String, _ change: MacControl) -> ShellError?)?>(nil)
    let pushRegistration = Locked<(@Sendable (_ phoneID: String, _ registration: PushRegistration?) -> Bool)?>(nil)
    let eventsProvider = Locked<(@Sendable (_ phoneID: String, _ since: Double) -> (events: [MacEvent], battery: [BatterySample]))?>(nil)
    let screenOnlyCheck = Locked<(@Sendable (String) -> Bool)?>(nil)
    /// What the host says about itself to a phone (`host`), after `macInfo`; unset: no `host` is sent.
    let hostInfoProvider = Locked<(@Sendable (String) -> HostInfo?)?>(nil)
    let screenGrant = Locked<(@Sendable (_ phoneID: String, _ label: String, _ name: String, _ viewer: String) -> Result<(id: String, key: Data), ShellError>)?>(nil)
    let screenPass = Locked<(@Sendable (_ phoneID: String, _ label: String, _ pass: ShellCredential) -> Bool)?>(nil)
    let screenRevoke = Locked<(@Sendable (_ phoneID: String, _ viewerID: String) -> Bool)?>(nil)
    let screenPassUsed = Locked<(@Sendable (_ viewerID: String) -> Void)?>(nil)
    let computerKeyLookup = Locked<(@Sendable (String) -> Data?)?>(nil)
    let computerScopesLookup = Locked<(@Sendable (String) -> Set<String>)?>(nil)
    let computerListProvider = Locked<(@Sendable (String) -> [ComputerAccess])?>(nil)
    let computerGrant = Locked<(@Sendable (_ phoneID: String, _ label: String, _ request: ComputerGrantRequest) -> Result<(id: String, key: Data, scopes: [String]), ShellError>)?>(nil)
    let computerPass = Locked<(@Sendable (_ phoneID: String, _ label: String, _ pass: ShellCredential, _ scopes: [String], _ pending: [String]) -> ShellError?)?>(nil)
    let computerRevoke = Locked<(@Sendable (_ phoneID: String, _ computerID: String) -> Bool)?>(nil)
    let computerUsed = Locked<(@Sendable (_ computerID: String) -> Void)?>(nil)
    /// `ShellListener.computerPresence`: its own until the app gives both listeners one.
    private let presence = Locked(ComputerPresence())
    var computerPresence: ComputerPresence { presence.get() }

    func useComputerPresence(_ shared: ComputerPresence) {
        presence.get().unwatch(self)
        presence.set(shared)
        shared.watch(self)
    }

    /// Which listener this gate serves, and what a computer's signature must be bound to there:
    /// the SHA-256 of the certificate on TLS, the endpoint id on iroh (32 raw bytes).
    struct Binding: Sendable {
        let path: ComputerProof.Path
        let hostBinding: Data
    }

    /// Nil: no computer can prove itself here.
    private let binding: Binding?
    private let shellKeys: @Sendable (String) -> [Data]
    private let keyConfirmed: @Sendable (_ phoneID: String, _ key: Data) -> Void
    private let phoneLabel: @Sendable (String) -> String
    /// Sent right after `ready` on every path when it returns an envelope.
    /// Its provider includes the relay token whenever one is configured, so
    /// phones keep it current.
    private let macInfo: @Sendable () -> ShellEnvelope?
    /// Unproven connections, few at once and from one address (as the wireless listener).
    private let limiter: HandshakeLimiter
    private(set) var stopped = false
    /// Attempts still proving themselves, so `stop` can drop them too.
    private var handshakes: [ObjectIdentifier: Admission] = [:]
    private var connections: [ObjectIdentifier: ShellConnection] = [:]

    /// One attempt's hold on a handshake slot, from before its stream exists
    /// until it has proved itself, failed, or timed out. Confined to the
    /// gate's queue (it only crosses into closures that hop back onto it).
    final class Admission: @unchecked Sendable {
        fileprivate let slot: HandshakeLimiter.Slot
        /// What the slot was taken for: remembered as proven once the proof checks out.
        fileprivate let host: String
        /// Drops the attempt while it has no stream yet.
        private let abandon: () -> Void
        fileprivate var stream: (any ByteStream)?

        fileprivate init(slot: HandshakeLimiter.Slot, host: String, abandon: @escaping () -> Void) {
            self.slot = slot
            self.host = host
            self.abandon = abandon
        }

        /// The slot is gone: the attempt finished, timed out or was stopped.
        var isOver: Bool { slot.isReleased }

        fileprivate func cancel() {
            if let stream { stream.cancel() } else { abandon() }
        }
    }

    init(label: String, manager: ShellSessionManager, transcripts: TranscriptStore,
         shellKeys: @escaping @Sendable (String) -> [Data],
         keyConfirmed: @escaping @Sendable (_ phoneID: String, _ key: Data) -> Void,
         phoneLabel: @escaping @Sendable (String) -> String,
         macInfo: @escaping @Sendable () -> ShellEnvelope?,
         handshakeTimeout: TimeInterval = WirelessLink.handshakeTimeout,
         provenAddresses: ProvenAddressStore = MemoryProvenAddressStore(),
         binding: Binding? = nil) {
        self.binding = binding
        queue = DispatchQueue(label: "\(PassthroughProtocol.identifier).\(label)")
        work = DispatchQueue(label: "\(PassthroughProtocol.identifier).\(label)-work")
        limiter = HandshakeLimiter(queue: queue, timeout: handshakeTimeout, store: provenAddresses)
        self.manager = manager
        self.transcripts = transcripts
        self.shellKeys = shellKeys
        self.keyConfirmed = keyConfirmed
        self.phoneLabel = phoneLabel
        self.macInfo = macInfo
        presence.get().watch(self)
    }

    /// Handshakes holding a slot now. On the queue.
    var pendingHandshakes: Int { limiter.count }

    /// On the queue: a handshake slot for an attempt from `host` (at most
    /// `maxForHost` at once from it, else the per-host cap), or nil when it
    /// must be refused. Once its proof checks out, `host` is remembered as
    /// proven, so it can still get in while strangers hold the shared slots. At the timeout the slot is freed and the attempt
    /// dropped: its stream cancelled, or `abandon` run if it has none yet.
    func admit(host: String, maxForHost: Int? = nil, abandon: @escaping () -> Void) -> Admission? {
        guard !stopped else { return nil }
        var admitted: Admission?
        guard let slot = limiter.acquire(host: host, maxForHost: maxForHost, onTimeout: { [weak self] in
            guard let admission = admitted else { return }
            self?.handshakes[ObjectIdentifier(admission)] = nil
            admission.cancel()
        }) else { return nil }
        let admission = Admission(slot: slot, host: host, abandon: abandon)
        admitted = admission
        handshakes[ObjectIdentifier(admission)] = admission
        return admission
    }

    /// On the queue: the attempt ended before it had a stream; frees its slot.
    func abandon(_ admission: Admission) {
        _ = release(admission)
    }

    /// On the queue: runs the handshake on `stream` (its first line must be
    /// `hello` when `expectHello`), all within the admission's timeout.
    /// An admission already over (timed out, stopped) has its stream closed.
    func runHandshake(_ admission: Admission, stream: any ByteStream, expectHello: Bool) {
        guard !admission.isOver, !stopped else { _ = release(admission); stream.cancel(); return }
        admission.stream = stream
        guard expectHello else { return challenge(admission, stream: stream, buffered: Data()) }
        WirelessLink.readLine(stream, limit: Self.proofLineLimit) { [weak self] result in
            guard let self else { stream.cancel(); return }
            self.queue.async {
                guard !admission.isOver else { return }   // timed out meanwhile
                guard !self.stopped, case .success(let (line, rest)) = result, line.count <= Self.proofLineLimit,
                      (try? ShellEnvelope.decode(line))?.t == ShellEnvelope.hello else {
                    ptLog(.warning, "shell: refused a connection that did not say hello")
                    _ = self.release(admission); stream.cancel(); return
                }
                self.challenge(admission, stream: stream, buffered: rest)
            }
        }
    }

    private func challenge(_ admission: Admission, stream: any ByteStream, buffered: Data) {
        let nonce = WirelessLink.randomBytes(32)
        var challenge = ShellEnvelope(t: ShellEnvelope.challenge)
        challenge.nonce = nonce.base64EncodedString()
        Self.send(challenge, on: stream)
        WirelessLink.readLine(stream, limit: Self.proofLineLimit, buffered: buffered) { [weak self] result in
            guard let self else { stream.cancel(); return }
            self.queue.async {
                guard !admission.isOver else { return }   // timed out meanwhile
                guard !self.stopped else { _ = self.release(admission); stream.cancel(); return }
                // readLine's limit is soft (one read can overshoot it); this one is hard.
                guard case .success(let (line, rest)) = result, line.count <= Self.proofLineLimit else {
                    _ = self.release(admission); stream.cancel(); return
                }
                guard let phoneID = self.verify(line, nonce: nonce) else {
                    ptLog(.warning, "shell: refused a connection that could not prove a shell key")
                    _ = self.release(admission)
                    var error = ShellEnvelope(t: ShellEnvelope.error)
                    error.reason = ShellError.notAuthorized.rawValue
                    Self.send(error, on: stream) { stream.cancel() }
                    // Its slot is free again, so it must not linger whatever the peer does.
                    self.queue.asyncAfter(deadline: .now() + 1) { stream.cancel() }
                    return
                }
                _ = self.release(admission)
                self.limiter.proven(admission.host)
                self.authorized(stream, phoneID: phoneID, rest: rest)
            }
        }
    }

    /// Frees the admission's slot, once; false if it was already freed.
    private func release(_ admission: Admission) -> Bool {
        guard admission.slot.release() else { return false }
        handshakes[ObjectIdentifier(admission)] = nil
        return true
    }

    /// The phone ID if `line` is a valid proof for `nonce`. Every proof is
    /// checked against two keys whatever the phone: missing ones (an unknown
    /// phone, no previous key) and malformed ones are throwaway keys, so they
    /// cost the same as a wrong key.
    ///
    /// A computer's id (`Computers`) must also sign the challenge with its
    /// identity key, bound to this listener (`ComputerProof`). One ECDSA
    /// verification always runs for such an id, whatever the HMAC found:
    /// against the decoy key (and, without a `sig`, a decoy signature) when
    /// there is no record, so a missing one costs what a wrong one does. It
    /// counts only with the real key and a real signature. A phone's `sig`
    /// is ignored.
    private func verify(_ line: Data, nonce: Data) -> String? {
        guard let message = try? ShellEnvelope.decode(line), message.t == ShellEnvelope.proof,
              let phoneID = message.phoneID, let mac = message.mac.flatMap({ Data(base64Encoded: $0) }) else { return nil }
        let keys = shellKeys(phoneID).prefix(2).map { $0.count >= 32 ? $0 : nil }
        var matched: Int?
        for index in 0..<2 {
            let key = index < keys.count ? keys[index] : nil
            let valid = RemoteShell.proofIsValid(mac, shellKey: key ?? WirelessLink.randomBytes(32), nonce: nonce)
            if valid, key != nil, matched == nil { matched = index }
        }
        var signed = true
        if Computers.isComputerID(phoneID) {
            let sig = message.sig.flatMap { Data(base64Encoded: $0) }.flatMap { $0.count == 64 ? $0 : nil }
            let identityKey = computerKeyLookup.get()?(phoneID).flatMap { ComputerProof.isPoint($0) ? $0 : nil }
            let signedMessage = ComputerProof.message(nonce: nonce, path: binding?.path ?? .tls,
                                                      hostBinding: binding?.hostBinding ?? Data(count: 32), computerID: phoneID)
            let valid = ComputerProof.isValid(sig ?? ComputerProof.decoySignature, publicKey: identityKey ?? ComputerProof.decoyKey,
                                              message: signedMessage)
            signed = valid && sig != nil && identityKey != nil && binding != nil
        }
        guard let matched, signed else { return nil }
        if matched == 0 && keys.count > 1, let proven = keys[0] {
            // Dropping the previous key writes to the Keychain: not on this queue.
            let keyConfirmed = self.keyConfirmed
            DispatchQueue.global(qos: .utility).async { keyConfirmed(phoneID, proven) }
        }
        return phoneID
    }

    private func authorized(_ stream: any ByteStream, phoneID: String, rest: Data) {
        let label = phoneLabel(phoneID)
        // By the id first, failing closed: a pass's id is screen-only whatever the hook says (or if it
        // is unset), and a computer's id is a computer's.
        let role: ShellConnection.Role = Computers.isComputerID(phoneID) ? .computer
            : ScreenPass.isViewerID(phoneID) || (screenOnlyCheck.get()?(phoneID) ?? false) ? .pass : .phone
        let screenOnly = role == .pass
        let connection = ShellConnection(gate: self, stream: stream, phoneID: phoneID, label: label, role: role)
        let key = ObjectIdentifier(connection)
        connections[key] = connection
        // Whether it is connected is in its phone's list, on every listener sharing the presence
        // (which pushes the lists). The one it opened with is the one it leaves.
        let presence = role == .computer ? computerPresence : nil
        connection.onClose = { [weak self] in
            self?.connections[key] = nil
            presence?.closed(phoneID)
        }
        presence?.opened(phoneID)
        ptLog(.info, screenOnly ? "shell: a screen pass connected" : role == .computer ? "shell: a computer connected" : "shell: a phone connected")
        // Told off this queue: it may write the Keychain.
        if screenOnly, let used = screenPassUsed.get() { DispatchQueue.global(qos: .utility).async { used(phoneID) } }
        if role == .computer, let used = computerUsed.get() { DispatchQueue.global(qos: .utility).async { used(phoneID) } }
        connection.start(initialBytes: rest, macInfo: macInfo(), host: screenOnly ? nil : hostInfoProvider.get()?(phoneID))
    }

    /// On the queue: drops every attempt and connection; refuses new ones.
    func stop() {
        stopped = true
        let pending = handshakes.values
        handshakes.removeAll()
        pending.forEach { $0.slot.release(); $0.cancel() }
        connections.values.forEach { $0.close() }
        connections.removeAll()
    }

    /// Runs `completion` on the queue once any session being opened on `work` is open.
    func afterWork(_ completion: @escaping @Sendable () -> Void) {
        work.async { [queue] in queue.async { completion() } }
    }

    /// On the queue: each authorized connection's phone and stream.
    var openStreams: [(phoneID: String, stream: any ByteStream)] {
        connections.values.map { ($0.phoneID, $0.stream) }
    }

    func disconnect(phoneID: String) {
        queue.async { [self] in
            connections.values.filter { $0.phoneID == phoneID }.forEach { $0.close() }
            // After a session one of them is opening on `work` is open (later
            // ones see the connection closed and open nothing).
            afterWork { [manager] in manager.closeSessions(openedBy: phoneID) }
        }
    }

    func disconnectScreen(phoneID: String) {
        queue.async { [self] in
            connections.values.filter { $0.phoneID == phoneID && $0.isScreen }.forEach { $0.close() }
        }
    }

    func event(_ text: String) { eventHandler.get()?(text) }

    func screenAllowed(_ phoneID: String) -> Bool { screenAccess.get()?(phoneID) ?? false }

    func screenViewer(_ phoneID: String, _ label: String, viewing: Bool) {
        event(viewing ? "\(label) started viewing the screen" : "\(label) stopped viewing the screen")
        screenHandler.get()?(phoneID, label, viewing)
    }

    /// `macState` for this phone, or nil when there is nothing to send.
    func macStateMessage(for phoneID: String) -> ShellEnvelope? {
        guard let state = macStateProvider.get()?(phoneID) else { return nil }
        var message = ShellEnvelope(t: ShellEnvelope.macState)
        message.state = state
        return message
    }

    func pushMacState() {
        queue.async { [self] in
            connections.values.filter { !$0.isScreen }.forEach { $0.sendMacState() }
        }
    }

    /// On the queue: `phoneID`'s computers, each marked connected while it has a connection on a
    /// listener sharing this one's presence.
    func computerList(for phoneID: String) -> [ComputerAccess] {
        let presence = computerPresence
        return (computerListProvider.get()?(phoneID) ?? []).prefix(Computers.maxTotal).map {
            var entry = $0
            entry.connected = presence.isConnected(entry.phoneID)
            return entry
        }
    }

    func pushComputerLists() {
        queue.async { [self] in
            connections.values.forEach { $0.sendComputerList() }
        }
    }

    func pushSessions() {
        queue.async { [self] in
            let list = manager.sessions
            connections.values.filter { !$0.isScreen }.forEach { $0.sendSessions(list) }
        }
    }

    func control(_ phoneID: String, _ label: String, _ change: MacControl) -> ShellError? {
        guard let handler = macControl.get() else { return .badRequest }
        return handler(phoneID, label, change)
    }

    static func send(_ message: ShellEnvelope, on stream: any ByteStream, then: (@Sendable () -> Void)? = nil) {
        guard let line = try? message.encodedLine() else { return }
        stream.send(line, isComplete: false) { _ in then?() }
    }
}

/// One authorized phone connection. It is the `ShellAttachment` for the one
/// session it is attached to; all its state lives on the listener's queue.
final class ShellConnection: ShellAttachment, @unchecked Sendable {
    /// Sent but not yet taken by the network: a phone that stops reading is
    /// dropped instead of the Mac buffering output for it without end. It can
    /// attach again and is replayed the scrollback.
    static let sendBacklogLimit = 8 << 20

    private weak var gate: ShellGate?
    private let manager: ShellSessionManager
    private let transcripts: TranscriptStore
    fileprivate let stream: any ByteStream
    private let queue: DispatchQueue
    let phoneID: String
    private let label: String
    /// Who is on the other end, decided once, at `authorized`, by the id first.
    enum Role: Sendable {
        case phone
        /// A screen pass (`ScreenPass`): only the screen, and nothing about the Mac before it.
        case pass
        /// A computer a phone gave access (`Computers`): only what its scopes allow, asked each time.
        case computer
    }

    private let role: Role
    private var screenOnly: Bool { role == .pass }
    private var isComputer: Bool { role == .computer }
    private var lines = LineBuffer(limit: RemoteShell.lineLimit)
    private var attached: String?
    /// What the manager returned for the attach to `attached`.
    private(set) var generation: UInt64 = 0
    private var backlog = 0
    private var closed = false
    /// `!closed`, for work running off the queue.
    private let isOpen = Locked(true)
    /// The phone says its terminal is on screen (`ShellEnvelope.viewing`).
    private let looking = Locked(false)
    var isLooking: Bool { looking.get() }
    /// Lines received but not yet handled: they wait while a request is
    /// handled off the queue (`busy`), so replies keep the requests' order.
    private var inbox: [Data] = []
    private var busy = false
    /// Reading stopped while `busy`, so a phone cannot pile up requests meanwhile.
    private var readPaused = false
    /// A `screen` request waits for `screenSharingVerified`.
    private var screenChecking = false
    /// Screen Sharing being dialled for a `screen` request.
    private var screenDial: NWConnection?
    /// The connection is now a byte relay to Screen Sharing; no more lines.
    private var screenRelay: Splice?
    /// The connection now carries the Mac's own screen stream; no more lines.
    private var screenVideo: (any ScreenVideoSource)?
    /// The `ScreenViewLimit` it holds a view from, while asking for or showing the screen.
    private var screenView: ScreenViewLimit?
    /// The connection now carries clipboard sync; no more lines.
    private var clipSync: (any ClipSyncSource)?
    var onClose: (() -> Void)?

    init(gate: ShellGate, stream: any ByteStream, phoneID: String, label: String, role: Role = .phone) {
        self.phoneID = phoneID
        self.role = role
        self.gate = gate
        self.manager = gate.manager
        self.transcripts = gate.transcripts
        self.stream = stream
        self.queue = gate.queue
        self.label = label
    }

    /// Sends `ready`, then `macInfo` if the Mac has one, then `host`, then its state, then the session list.
    func start(initialBytes: Data, macInfo: ShellEnvelope? = nil, host: HostInfo? = nil) {
        stream.onTerminated = { [weak self] _ in self?.queue.async { self?.close() } }
        send(ShellEnvelope(t: ShellEnvelope.ready))
        if !screenOnly {
            if let macInfo { send(macInfo) }
            if var host {
                // A computer without the shell scope isn't told the shells.
                if !shellScope { host.shells = nil }
                var message = ShellEnvelope(t: ShellEnvelope.host)
                message.host = host
                send(message)
            }
            // Nor the Mac's state or its sessions.
            if shellScope {
                sendMacState()
                var list = ShellEnvelope(t: ShellEnvelope.sessions)
                list.sessions = manager.sessions
                send(list)
            }
        }
        received(initialBytes)
        if busy { readPaused = true } else { receive() }
    }

    /// The newest events and samples that fit in one line, oldest first.
    private func sendEvents(_ found: (events: [MacEvent], battery: [BatterySample]), since: Double) {
        var reply = ShellEnvelope(t: ShellEnvelope.eventList)
        reply.since = since
        reply.events = Array(found.events.suffix(MacEvent.maxPerList))
        reply.battery = Array(found.battery.suffix(BatterySample.maxPerList))
        // Long details could still overflow a line: drop the oldest until it fits.
        while let line = try? reply.encodedLine(), line.count > RemoteShell.lineLimit, !(reply.events ?? []).isEmpty {
            reply.events = Array((reply.events ?? []).dropFirst(max(1, (reply.events?.count ?? 0) / 10)))
        }
        send(reply)
    }

    /// Asked for `computerList` on this connection: it is sent again whenever it changes.
    private var listsComputers = false

    /// On the queue: this phone's computers, if it asked for them on this connection.
    func sendComputerList() {
        guard !closed, listsComputers, role == .phone, let gate else { return }
        var message = ShellEnvelope(t: ShellEnvelope.computerList)
        message.computers = gate.computerList(for: phoneID)
        send(message)
    }

    /// On the queue: the session list, unasked.
    func sendSessions(_ list: [ShellSessionInfo]) {
        guard !closed, !isScreen, !screenOnly, shellScope else { return }
        var message = ShellEnvelope(t: ShellEnvelope.sessions)
        message.sessions = list
        send(message)
    }

    /// On the queue: the Mac's state as this phone may see it, if there is any.
    func sendMacState() {
        guard !closed, !isScreen, !screenOnly, shellScope, var message = gate?.macStateMessage(for: phoneID) else { return }
        // A computer never changes Keep awake or the VPN, whatever the provider says.
        if isComputer { message.state?.control = false }
        send(message)
    }

    // MARK: A computer's scopes (stage 7 a.3)

    /// What this computer may do now, asked from memory each time (empty for a phone or a pass).
    private var computerScopes: Set<String> {
        guard isComputer else { return [] }
        return gate?.computerScopesLookup.get()?(phoneID) ?? []
    }

    /// It may use the shells: a phone always, a computer with its shell scope, a pass never (checked elsewhere).
    private var shellScope: Bool { !isComputer || computerScopes.contains(Computers.scopeShell) }

    /// What a computer may not ask, and why; nil for anything else (and for a phone or a pass).
    private func computerRefusal(_ t: String) -> ShellError? {
        guard isComputer else { return nil }
        // Revoked since it connected (or its phone was): nothing more, and the connection goes.
        guard gate?.computerKeyLookup.get()?(phoneID) != nil else { return .notAuthorized }
        let scopes = computerScopes
        switch t {
        case ShellEnvelope.ping, ShellEnvelope.pong:
            return nil
        case ShellEnvelope.list, ShellEnvelope.open, ShellEnvelope.attach, ShellEnvelope.input, ShellEnvelope.resize,
             ShellEnvelope.close, ShellEnvelope.viewing:
            return scopes.contains(Computers.scopeShell) ? nil : .notAllowed
        case ShellEnvelope.screenVideo, ShellEnvelope.clipSync:
            return scopes.contains(Computers.scopeScreen) ? nil : .screenNotAllowed
        // Never the relay to Screen Sharing: its login would let a computer try the Mac's password.
        case ShellEnvelope.screen:
            return .screenNotAllowed
        // No history, transcripts, events, push, lock, Keep awake or VPN, and no onward grant.
        default:
            return .notAllowed
        }
    }

    /// How long after an accepted `setAwake`/`setVPN` its `macState` answer goes out.
    static let controlAnswerDelay: TimeInterval = 1

    /// Asked for the screen: being relayed to Screen Sharing, or about to be.
    var isScreen: Bool { screenChecking || screenDial != nil || screenRelay != nil || screenVideo != nil || clipSync != nil }

    /// Ends the connection and stops the manager sending to it. Idempotent.
    func close() {
        guard !closed else { return }
        closed = true
        isOpen.set(false)
        inbox.removeAll()
        manager.detach(client: self)
        attached = nil
        screenChecking = false
        screenDial?.cancel()
        screenDial = nil
        if let screenRelay {
            screenRelay.close()
            gate?.screenViewer(phoneID, label, viewing: false)
        }
        screenRelay = nil
        if let screenVideo {
            screenVideo.stop()
            gate?.screenViewer(phoneID, label, viewing: false)
        }
        screenVideo = nil
        clipSync?.stop()
        clipSync = nil
        releaseScreenView()
        stream.onTerminated = nil
        stream.cancel()
        let onClose = self.onClose
        self.onClose = nil
        onClose?()
        ptLog(.info, "shell: a phone disconnected")
    }

    private func receive() {
        stream.receive(maximumLength: 65536) { [weak self] data, complete, error in
            guard let self else { return }
            self.queue.async {
                guard !self.closed else { return }
                if let data, !data.isEmpty { self.received(data) }
                if complete || error != nil {
                    self.close()
                } else if !self.closed {
                    if self.busy { self.readPaused = true } else { self.receive() }
                }
            }
        }
    }

    private func received(_ data: Data) {
        guard !closed, !data.isEmpty else { return }
        do {
            inbox += try lines.append(data)
        } catch {
            ptLog(.warning, "shell: a phone sent an overlong line; disconnected")
            return close()
        }
        drain()
    }

    /// Handles waiting lines until one has to wait for work off the queue.
    private func drain() {
        while !busy, !closed, !inbox.isEmpty {
            handle(inbox.removeFirst())
        }
    }

    /// The request handled off the queue is done: carry on with the next ones.
    private func resume() {
        // Screen Sharing didn't answer: the connection stays a shell one, and its view is free again.
        if !isScreen { releaseScreenView() }
        busy = false
        drain()
        if !busy, readPaused, !closed {
            readPaused = false
            receive()
        }
    }

    // MARK: Requests

    private func handle(_ line: Data) {
        guard let message = try? ShellEnvelope.decode(line) else { return fail(.badRequest) }
        // Only the Mac's own stream: not the tunnel to macOS Screen Sharing,
        // whose login would let a pass try the Mac's account password.
        if screenOnly, ![ShellEnvelope.screenVideo, ShellEnvelope.clipSync, ShellEnvelope.ping, ShellEnvelope.pong].contains(message.t) {
            return fail(.screenOnly, session: message.session, ref: message.ref)
        }
        if let refused = computerRefusal(message.t) {
            fail(refused, session: message.session, ref: message.ref)
            if refused == .notAuthorized { close() }
            return
        }
        switch message.t {
        case ShellEnvelope.events:
            guard let since = message.since, since.isFinite, let provider = gate?.eventsProvider.get() else { return fail(.badRequest) }
            sendEvents(provider(phoneID, since), since: since)
        case ShellEnvelope.setAwake, ShellEnvelope.setVPN:
            guard let on = message.on, let gate else { return fail(.badRequest) }
            let change: MacControl = message.t == ShellEnvelope.setAwake ? .awake(on) : .vpn(on)
            if let refused = gate.control(phoneID, label, change) { return fail(refused) }
            // The Mac may hold its state (a limit refusing Keep awake, a VPN
            // already on): answer anyway, once the change has had its moment,
            // so the phone always hears back.
            queue.asyncAfter(deadline: .now() + Self.controlAnswerDelay) { [weak self] in self?.sendMacState() }
        case ShellEnvelope.pushRegister:
            let registration = message.on == false ? nil : message.push
            if message.on != false, !(registration?.isValid ?? false) { return fail(.badRequest) }
            let sends = gate?.pushRegistration.get()?(phoneID, registration) ?? false
            var reply = ShellEnvelope(t: ShellEnvelope.pushState)
            reply.on = sends && registration != nil
            send(reply)
        case ShellEnvelope.viewing:
            guard let on = message.on else { return fail(.badRequest) }
            looking.set(on)
            if on { manager.lookedAt(client: self) }
        case ShellEnvelope.lock:
            guard let gate else { return fail(.badRequest) }
            if let refused = gate.control(phoneID, label, .lock) { return fail(refused) }
            queue.asyncAfter(deadline: .now() + Self.controlAnswerDelay) { [weak self] in self?.sendMacState() }
        case ShellEnvelope.list:
            var reply = ShellEnvelope(t: ShellEnvelope.sessions)
            reply.sessions = manager.sessions
            send(reply)
        case ShellEnvelope.open:
            guard let cols = message.cols, let rows = message.rows else { return fail(.badRequest, ref: message.ref) }
            open(cols: cols, rows: rows, ref: message.ref)
        case ShellEnvelope.attach:
            guard let id = message.session, let cols = message.cols, let rows = message.rows else { return fail(.badRequest) }
            if attach(id, cols: cols, rows: rows) { gate?.event("\(label) attached to a session") }
        case ShellEnvelope.input:
            guard let id = message.session, id == attached,
                  let data = message.data.flatMap({ Data(base64Encoded: $0) }) else { return fail(.badRequest, session: message.session) }
            manager.input(id, data, from: self)
        case ShellEnvelope.resize:
            // The phone's terminal size, for whatever this connection has
            // attached when the line is read: lines wait behind an `open`, so a
            // resize sent before `opened` (the keyboard coming up) reaches the
            // new session. The `session` named is ignored (Macs before this
            // required it): it may be the one an `open` or `attach` ahead just left.
            guard let cols = message.cols, let rows = message.rows else { return fail(.badRequest, session: message.session) }
            guard let id = attached else { return }
            manager.resize(id, cols: cols, rows: rows, from: self)
        case ShellEnvelope.close:
            guard let id = message.session else { return fail(.badRequest) }
            guard manager.sessions.contains(where: { $0.id == id && $0.running }) else { return fail(.noSuchSession, session: id) }
            manager.close(id)
            gate?.event("\(label) closed a session")
        case ShellEnvelope.history:
            sendHistory()
        case ShellEnvelope.transcript:
            guard let id = message.session else { return fail(.badRequest) }
            sendTranscript(id, maxBytes: message.tail.map { min(max($0, 1), TranscriptStore.readLimit) } ?? TranscriptStore.readLimit)
        case ShellEnvelope.screen:
            guard gate?.screenAllowed(phoneID) == true else { return fail(.screenNotAllowed) }
            guard takeScreenView() else { return fail(.tooManyScreens) }
            screen()
        case ShellEnvelope.screenVideo:
            guard gate?.screenAllowed(phoneID) == true else { return fail(.screenNotAllowed) }
            guard takeScreenView() else { return fail(.tooManyScreens) }
            guard let source = gate?.screenVideoFactory.get()?(phoneID, label) else {
                releaseScreenView()
                return fail(.screenVideoUnavailable)
            }
            streamScreen(source)
        case ShellEnvelope.clipSync:
            // Between computers only: a phone keeps its Copy and Paste.
            guard role != .phone else { return fail(.notAllowed) }
            guard gate?.screenAllowed(phoneID) == true else { return fail(.screenNotAllowed) }
            guard let factory = gate?.clipSyncFactory.get() else { return fail(.clipSyncUnavailable) }
            switch factory(phoneID, label) {
            case let .success(source): syncClipboard(source)
            case let .failure(reason): fail(reason)
            }
        case ShellEnvelope.screenGrant:
            guard let name = message.name, let viewer = message.viewer else { return fail(.badRequest) }
            grantScreen(name: name, viewer: viewer)
        case ShellEnvelope.screenPass:
            guard let pass = message.pass, ScreenPass.isUsable(pass) else { return fail(.badRequest) }
            keepScreenPass(pass)
        case ShellEnvelope.screenRevoke:
            guard let viewer = message.phoneID, ScreenPass.isViewerID(viewer) else { return fail(.badRequest) }
            revokeScreenPass(viewer)
        case ShellEnvelope.computerGrant:
            guard let name = message.name, let viewer = message.viewer,
                  let idKey = message.idKey.flatMap({ Data(base64Encoded: $0) }), ComputerProof.isPoint(idKey),
                  let scopes = Computers.validScopes(message.scopes) else { return fail(.badRequest) }
            grantComputer(ComputerGrantRequest(name: name, viewer: viewer, kind: message.kind, identityKey: idKey, scopes: scopes))
        case ShellEnvelope.computerPass:
            let pending = message.pending ?? []
            guard let pass = message.pass, Computers.isUsable(pass), let scopes = message.scopes,
                  !(scopes + pending).isEmpty, (scopes + pending).allSatisfy(Computers.allScopes.contains) else { return fail(.badRequest) }
            keepComputerPass(pass, scopes: scopes, pending: pending)
        case ShellEnvelope.computerRevoke:
            guard let computerID = message.phoneID, Computers.isComputerID(computerID) else { return fail(.badRequest) }
            revokeComputer(computerID)
        case ShellEnvelope.listComputers:
            // Computers are refused it above (`computerRefusal`), passes before that.
            guard role == .phone else { return fail(.notAllowed) }
            listsComputers = true
            sendComputerList()
        case ShellEnvelope.ping:
            send(ShellEnvelope(t: ShellEnvelope.pong))
        case ShellEnvelope.pong:
            break
        default:
            fail(.badRequest)
        }
    }
    /// Issues a screen pass on the work queue (it writes the Keychain), then answers.
    private func grantScreen(name: String, viewer: String) {
        guard let gate, let handler = gate.screenGrant.get() else { return fail(.badRequest) }
        busy = true
        let phoneID = self.phoneID, label = self.label, queue = self.queue
        let revoke = gate.screenRevoke.get(), work = gate.work
        gate.work.async { [weak self] in
            let result = handler(phoneID, label, name, viewer)
            queue.async {
                // The phone left before it could hear of the pass: nobody can hand it over, so take it back.
                guard let self, !self.closed else {
                    if case let .success(granted) = result, let revoke { work.async { _ = revoke(phoneID, granted.id) } }
                    return
                }
                switch result {
                case let .success(granted):
                    var reply = ShellEnvelope(t: ShellEnvelope.screenGranted)
                    reply.phoneID = granted.id
                    reply.key = granted.key.base64EncodedString()
                    self.send(reply)
                    self.gate?.event("\(label) let \(name) see the screen")
                case let .failure(error):
                    self.fail(error)
                }
                self.resume()
            }
        }
    }

    /// Takes back a pass this phone granted, on the work queue, then answers.
    private func revokeScreenPass(_ viewer: String) {
        guard let gate, let handler = gate.screenRevoke.get() else { return fail(.badRequest) }
        busy = true
        let phoneID = self.phoneID, queue = self.queue
        gate.work.async { [weak self] in
            let removed = handler(phoneID, viewer)
            queue.async {
                guard let self else { return }
                if removed { self.send(ShellEnvelope(t: ShellEnvelope.screenRevoked)) } else { self.fail(.badRequest) }
                self.resume()
            }
        }
    }

    /// Keeps a pass to another Mac's screen on the work queue, then answers.
    private func keepScreenPass(_ pass: ShellCredential) {
        guard let gate, let handler = gate.screenPass.get() else { return fail(.badRequest) }
        busy = true
        let phoneID = self.phoneID, label = self.label, queue = self.queue
        gate.work.async { [weak self] in
            let kept = handler(phoneID, label, pass)
            queue.async {
                guard let self else { return }
                if kept { self.send(ShellEnvelope(t: ShellEnvelope.screenPassSaved)) } else { self.fail(.passNotSaved) }
                self.resume()
            }
        }
    }

    /// Gives another computer access on the work queue (it writes the Keychain), then answers
    /// `computerGranted`. A phone gone before it hears the answer can't hand it over: it is taken back.
    private func grantComputer(_ request: ComputerGrantRequest) {
        guard let gate, let handler = gate.computerGrant.get() else { return fail(.badRequest) }
        busy = true
        let phoneID = self.phoneID, label = self.label, queue = self.queue
        let revoke = gate.computerRevoke.get(), work = gate.work
        gate.work.async { [weak self] in
            let result = handler(phoneID, label, request)
            queue.async {
                guard let self, !self.closed else {
                    if case let .success(granted) = result, let revoke { work.async { _ = revoke(phoneID, granted.id) } }
                    return
                }
                switch result {
                case let .success(granted):
                    var reply = ShellEnvelope(t: ShellEnvelope.computerGranted)
                    reply.phoneID = granted.id
                    reply.key = granted.key.base64EncodedString()
                    reply.scopes = granted.scopes
                    self.send(reply)
                    self.gate?.event("\(label) gave \(request.name) access")
                case let .failure(error):
                    self.fail(error)
                }
                self.resume()
            }
        }
    }

    /// Keeps access to another computer on the work queue, then answers.
    private func keepComputerPass(_ pass: ShellCredential, scopes: [String], pending: [String]) {
        guard let gate, let handler = gate.computerPass.get() else { return fail(.badRequest) }
        busy = true
        let phoneID = self.phoneID, label = self.label, queue = self.queue
        gate.work.async { [weak self] in
            let refused = handler(phoneID, label, pass, scopes, pending)
            queue.async {
                guard let self else { return }
                if let refused { self.fail(refused) } else { self.send(ShellEnvelope(t: ShellEnvelope.computerPassSaved)) }
                self.resume()
            }
        }
    }

    /// Takes back a computer's access this phone got, on the work queue, then answers.
    private func revokeComputer(_ computerID: String) {
        guard let gate, let handler = gate.computerRevoke.get() else { return fail(.badRequest) }
        busy = true
        let phoneID = self.phoneID, queue = self.queue
        gate.work.async { [weak self] in
            let removed = handler(phoneID, computerID)
            queue.async {
                guard let self else { return }
                if removed { self.send(ShellEnvelope(t: ShellEnvelope.computerRevoked)) } else { self.fail(.badRequest) }
                self.resume()
            }
        }
    }

    /// Starts a shell on the listener's work queue (spawning one must not hold
    /// up every other phone), then replies and attaches. This connection's
    /// later requests wait until then. The answer, `opened` or an error,
    /// carries the phone's `ref` for the open.
    private func open(cols: Int, rows: Int, ref: Int?) {
        guard let gate else { return fail(.badRequest, ref: ref) }
        busy = true
        let manager = self.manager, label = self.label, phoneID = self.phoneID, isOpen = self.isOpen, accepting = gate.accepting
        let queue = self.queue
        gate.work.async { [weak self] in
            // Not for a phone already gone (revoked, say) or a listener stopping.
            let result = isOpen.get() && accepting.get()
                ? Result { try manager.open(phoneLabel: label, phoneID: phoneID, cols: cols, rows: rows) }
                : .failure(ShellError.badRequest)
            queue.async { self?.opened(result, cols: cols, rows: rows, ref: ref) }
        }
    }

    private func opened(_ result: Result<String, Error>, cols: Int, rows: Int, ref: Int?) {
        guard !closed else { return }
        switch result {
        case .success(let id):
            gate?.event("\(label) opened a session")
            var reply = ShellEnvelope(t: ShellEnvelope.opened)
            reply.session = id; reply.cols = cols; reply.rows = rows; reply.ref = ref
            send(reply)
            attach(id, cols: cols, rows: rows)
        case .failure(let error):
            fail(error, ref: ref)
        }
        resume()
    }

    /// Attaches to `id`, leaving any other session first. False if there is no such session.
    @discardableResult
    private func attach(_ id: String, cols: Int, rows: Int) -> Bool {
        if attached != id { manager.detach(client: self) }
        attached = id
        do {
            generation = try manager.attach(id, client: self, cols: cols, rows: rows)
            return true
        } catch {
            attached = nil
            fail(error, session: id)
            return false
        }
    }

    /// Lists the history off the queue (it reads the transcript folder, and
    /// the queue carries every phone's traffic), then replies. This
    /// connection's later requests wait until then, so replies keep order.
    private func sendHistory() {
        busy = true
        let transcripts = self.transcripts, isOpen = self.isOpen, queue = self.queue
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let reply = isOpen.get() ? Self.historyReply(transcripts.entries()) : nil
            queue.async {
                guard let self else { return }
                if let reply { self.send(reply) }
                self.resume()
            }
        }
    }

    /// Most entries one `historyList` carries: the newest.
    static let historyLimit = 500

    /// A `historyList` for `entries` (newest first): the newest
    /// `historyLimit`, fewer if the line would still be longer than a phone
    /// accepts (the oldest are dropped until it fits).
    static func historyReply(_ entries: [ShellHistoryEntry]) -> ShellEnvelope {
        func reply(_ count: Int) -> ShellEnvelope {
            var reply = ShellEnvelope(t: ShellEnvelope.historyList)
            reply.history = Array(entries.prefix(count))
            return reply
        }
        func fits(_ count: Int) -> Bool {
            ((try? reply(count).encodedLine())?.count ?? Int.max) <= RemoteShell.lineLimit
        }
        var count = min(entries.count, historyLimit)
        if !fits(count) {
            // The most that fit: `low` fits (none always does), `high` doesn't.
            var low = 0, high = count
            while high - low > 1 {
                let mid = (low + high) / 2
                if fits(mid) { low = mid } else { high = mid }
            }
            count = low
        }
        return reply(count)
    }

    /// Reads the transcript's end (at most `maxBytes`, with the terminal's
    /// sizes) off the queue, then sends it a line at a time, each after the
    /// previous one was taken by the network.
    private func sendTranscript(_ id: String, maxBytes: Int) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let lines = (try? self.transcripts.replay(of: id, maxBytes: maxBytes))
                .map { ShellReplay.transcriptLines(session: id, $0) }
            self.queue.async {
                guard let lines else { return self.fail(.noSuchSession, session: id) }
                self.sendTranscript(lines[...])
            }
        }
    }

    private func sendTranscript(_ lines: ArraySlice<ShellEnvelope>) {
        guard !closed, let line = lines.first else { return }
        send(line) { [weak self] in self?.sendTranscript(lines.dropFirst()) }
    }

    /// Dials Screen Sharing on loopback, then replies `screenReady` and from
    /// there on relays raw bytes both ways until either side closes. The
    /// connection leaves its session first, and handles no more lines: the
    /// phone sends nothing after `screen` until `screenReady` (Screen Sharing
    /// speaks first), so anything already waiting is a protocol error.
    ///
    /// Before dialling, `screenSharingVerified` must say the port is macOS's
    /// own Screen Sharing: the phone will send the Mac account's password to
    /// whatever answers there.
    private func screen() {
        guard let gate, let port = NWEndpoint.Port(rawValue: gate.screenPort.get()) else { return fail(.screenUnavailable) }
        busy = true
        manager.detach(client: self)
        attached = nil
        screenChecking = true
        let check = gate.screenSharingCheck.get()
        var settled = false
        let settle: (Bool) -> Void = { [weak self] genuine in
            guard let self, !settled else { return }
            settled = true
            guard self.screenChecking, !self.closed else { return }
            self.screenChecking = false
            guard genuine else {
                ptLog(.warning, check == nil
                      ? "shell: a phone asked for the screen; nothing can check what listens on Screen Sharing's port, so it is not relayed"
                      : "shell: a phone asked for the screen; what listens on Screen Sharing's port is not Screen Sharing (or could not be checked), so it is not relayed")
                self.fail(.screenUnavailable)
                return self.resume()
            }
            self.dialScreen(port)
        }
        guard let check else { return settle(false) }
        let queue = self.queue
        Task {
            let genuine = await check()
            queue.async { settle(genuine) }
        }
        queue.asyncAfter(deadline: .now() + Self.screenDialTimeout) { settle(false) }
    }

    /// `screen`, once the port is known to be Screen Sharing's.
    private func dialScreen(_ port: NWEndpoint.Port) {
        let dial = NWConnection(host: .ipv4(.loopback), port: port, using: .tcp)
        screenDial = dial
        var settled = false
        let settle: (Bool) -> Void = { [weak self] ready in
            guard let self, !settled, !self.closed, self.screenDial === dial else { return }
            settled = true
            self.screenDial = nil
            if ready { return self.relayScreen(dial) }
            dial.cancel()
            ptLog(.info, "shell: Screen Sharing is not answering; a phone asked for the screen")
            self.fail(.screenUnavailable)
            self.resume()
        }
        dial.stateUpdateHandler = { state in
            switch state {
            case .ready: settle(true)
            // Refused (nothing listening) shows up as waiting, not failed.
            case .waiting, .failed: settle(false)
            default: break
            }
        }
        dial.start(queue: queue)
        queue.asyncAfter(deadline: .now() + Self.screenDialTimeout) { settle(false) }
    }

    /// How long Screen Sharing has to accept on loopback.
    static let screenDialTimeout: TimeInterval = 5

    private func relayScreen(_ dial: NWConnection) {
        guard inbox.isEmpty else {
            ptLog(.warning, "shell: a phone sent more after asking for the screen; disconnected")
            dial.cancel()
            return close()
        }
        let local = ConnectionStream(dial, queue: queue)
        let relay = Splice(stream, local, queue: queue, endTogether: true) { [weak self] in self?.close() }
        screenRelay = relay
        gate?.screenViewer(phoneID, label, viewing: true)
        send(ShellEnvelope(t: ShellEnvelope.screenReady)) { [weak self] in
            guard let self, !self.closed, self.screenRelay === relay else { return }
            relay.start()
        }
    }

    /// Hands the connection to the Mac's own screen stream after
    /// `screenVideoReady`, as `relayScreen` does to Screen Sharing: the phone
    /// sends nothing after `screenVideo` until then, so a line already
    /// waiting is a protocol error. `busy` stops the line reader for good.
    private func streamScreen(_ source: any ScreenVideoSource) {
        busy = true
        manager.detach(client: self)
        attached = nil
        guard inbox.isEmpty else {
            ptLog(.warning, "shell: a phone sent more after asking for the screen; disconnected")
            return close()
        }
        screenVideo = source
        gate?.screenViewer(phoneID, label, viewing: true)
        send(ShellEnvelope(t: ShellEnvelope.screenVideoReady)) { [weak self] in
            guard let self, !self.closed, self.screenVideo === source else { return }
            let rest = self.lines.takePending()
            source.start(stream: self.stream, initialBytes: rest) { [weak self] in
                self?.queue.async { self?.close() }
            }
        }
    }

    /// Hands the connection to clipboard sync after `clipSyncReady`, as `streamScreen` does.
    private func syncClipboard(_ source: any ClipSyncSource) {
        busy = true
        manager.detach(client: self)
        attached = nil
        guard inbox.isEmpty else {
            ptLog(.warning, "shell: a computer sent more after asking for clipboard sync; disconnected")
            source.stop()
            return close()
        }
        clipSync = source
        send(ShellEnvelope(t: ShellEnvelope.clipSyncReady)) { [weak self] in
            guard let self, !self.closed, self.clipSync === source else { return }
            let rest = self.lines.takePending()
            source.start(stream: self.stream, initialBytes: rest) { [weak self] in
                self?.queue.async { self?.close() }
            }
        }
    }

    /// One of the screen views the gate allows, held until the connection
    /// closes or stops asking for the screen. A connection holds one at most.
    private func takeScreenView() -> Bool {
        if screenView != nil { return true }
        guard let views = gate?.screenViews.get(), views.take(phoneID) else {
            ptLog(.warning, "shell: refused a screen view: too many open")
            return false
        }
        screenView = views
        return true
    }

    private func releaseScreenView() {
        screenView?.release(phoneID)
        screenView = nil
    }

    /// Manager errors keep their reason; anything else (a shell that could not
    /// start) is reported as a bad request.
    private func fail(_ error: Error, session: String? = nil, ref: Int? = nil) {
        fail(error as? ShellError ?? .badRequest, session: session, ref: ref)
    }

    private func fail(_ reason: ShellError, session: String? = nil, ref: Int? = nil) {
        var reply = ShellEnvelope(t: ShellEnvelope.error)
        reply.reason = reason.rawValue
        reply.session = session
        reply.ref = ref
        send(reply)
    }

    /// Queues a line; `then` runs on the queue once the network has taken it.
    private func send(_ message: ShellEnvelope, then: (() -> Void)? = nil) {
        guard !closed, let line = try? message.encodedLine() else { return }
        backlog += line.count
        guard backlog <= Self.sendBacklogLimit else {
            ptLog(.warning, "shell: a phone is not reading its output; disconnected")
            return close()
        }
        let count = line.count
        stream.send(line, isComplete: false) { [weak self] _ in
            self?.queue.async {
                guard let self else { return }
                self.backlog -= count
                then?()
            }
        }
    }

    // MARK: ShellAttachment (on the manager's callouts queue: hand off, never block)

    func shellOutput(_ data: Data, session: String) {
        queue.async { [self] in
            guard session == attached else { return }
            var offset = 0
            while offset < data.count {
                let end = min(offset + RemoteShell.outputChunk, data.count)
                var message = ShellEnvelope(t: ShellEnvelope.output)
                message.session = session
                message.data = data.subdata(in: (data.startIndex + offset)..<(data.startIndex + end)).base64EncodedString()
                send(message)
                offset = end
            }
        }
    }

    func shellEnded(session: String, exitStatus: Int32) {
        queue.async { [self] in
            guard session == attached else { return }
            attached = nil
            var message = ShellEnvelope(t: ShellEnvelope.ended)
            message.session = session
            message.exitStatus = exitStatus
            send(message)
        }
    }

    func shellReplaying(session: String) {
        queue.async { [self] in
            guard session == attached else { return }
            var message = ShellEnvelope(t: ShellEnvelope.replaying)
            message.session = session
            send(message)
        }
    }

    func shellReplayed(session: String) {
        queue.async { [self] in
            guard session == attached else { return }
            var message = ShellEnvelope(t: ShellEnvelope.attached)
            message.session = session
            send(message)
        }
    }

    func shellDetached(session: String, generation: UInt64) {
        queue.async { [self] in
            // A takeover of an earlier attach, queued before this one: not ours to act on.
            guard session == attached, generation == self.generation else { return }
            attached = nil
            var message = ShellEnvelope(t: ShellEnvelope.detached)
            message.session = session
            send(message)
        }
    }
}
#endif
