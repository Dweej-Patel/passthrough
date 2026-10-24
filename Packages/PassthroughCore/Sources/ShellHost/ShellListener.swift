#if os(macOS)
import Foundation
import Network
import PassthroughCore
import PhoneTransport

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
    public var screenVideo: (@Sendable (_ phoneID: String) -> (any ScreenVideoSource)?)? {
        get { gate.screenVideoFactory.get() }
        set { gate.screenVideoFactory.set(newValue) }
    }

    /// A phone started (`viewing`) or stopped seeing the screen. On the listener's queue.
    public var onScreenViewer: (@Sendable (_ phoneID: String, _ label: String, _ viewing: Bool) -> Void)? {
        get { gate.screenHandler.get() }
        set { gate.screenHandler.set(newValue) }
    }

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
    /// `advertise` is false in tests.
    public init(identity: MacIdentity, port: UInt16 = RemoteShell.defaultPort, advertise: Bool = true,
                manager: ShellSessionManager, transcripts: TranscriptStore,
                shellKeys: @escaping @Sendable (String) -> [Data],
                keyConfirmed: @escaping @Sendable (_ phoneID: String, _ key: Data) -> Void = { _, _ in },
                phoneLabel: @escaping @Sendable (String) -> String,
                peerAllowed: @escaping @Sendable (String) -> Bool = ShellListener.defaultPeerAllowed,
                macInfo: @escaping @Sendable () -> ShellEnvelope? = { nil }) {
        self.identity = identity
        self.requestedPort = port
        self.advertise = advertise
        self.peerAllowed = peerAllowed
        gate = ShellGate(label: "shell-listener", manager: manager, transcripts: transcripts, shellKeys: shellKeys,
                         keyConfirmed: keyConfirmed, phoneLabel: phoneLabel, macInfo: macInfo)
    }

    /// The address policy, with global IPv6 peers checked against the Mac's
    /// own /64s as they are now (interfaces come and go).
    public static func defaultPeerAllowed(_ host: String) -> Bool {
        ShellAddressPolicy.isAllowed(host)
            || ShellAddressPolicy.isAllowed(host, onLinkPrefixes: LocalAddresses.onLinkPrefixes())
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

    /// Drops every connection of this phone at once (it was revoked). Its
    /// sessions keep running: they belong to the Mac. Call after its keys are
    /// gone from `shellKeys`, so it cannot prove itself again.
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
        // Before TLS: a peer outside the private ranges gets nothing at all.
        guard !gate.stopped, peerAllowed(host) else {
            ptLog(.warning, "shell: refused a connection from outside the allowed networks")
            connection.cancel(); return
        }
        guard let admission = gate.admit(host: host, abandon: { connection.cancel() }) else {
            connection.cancel(); return
        }
        gate.runHandshake(admission, stream: ConnectionStream(connection, queue: queue), expectHello: false)
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
    let screenVideoFactory = Locked<(@Sendable (String) -> (any ScreenVideoSource)?)?>(nil)
    /// `ShellListener.screenSharingVerified`.
    let screenSharingCheck = Locked<(@Sendable () async -> Bool)?>(nil)
    /// Where `screen` requests are relayed; another port in tests.
    let screenPort = Locked(RemoteShell.screenSharingPort)
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
        /// Drops the attempt while it has no stream yet.
        private let abandon: () -> Void
        fileprivate var stream: (any ByteStream)?

        fileprivate init(slot: HandshakeLimiter.Slot, abandon: @escaping () -> Void) {
            self.slot = slot
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
         handshakeTimeout: TimeInterval = WirelessLink.handshakeTimeout) {
        queue = DispatchQueue(label: "\(PassthroughProtocol.identifier).\(label)")
        work = DispatchQueue(label: "\(PassthroughProtocol.identifier).\(label)-work")
        limiter = HandshakeLimiter(queue: queue, timeout: handshakeTimeout, onLinkPrefixes: LocalAddresses.onLinkPrefixes)
        self.manager = manager
        self.transcripts = transcripts
        self.shellKeys = shellKeys
        self.keyConfirmed = keyConfirmed
        self.phoneLabel = phoneLabel
        self.macInfo = macInfo
    }

    /// Handshakes holding a slot now. On the queue.
    var pendingHandshakes: Int { limiter.count }

    /// On the queue: a handshake slot for an attempt from `host` (at most
    /// `maxForHost` at once from it, else the per-host cap), or nil when it
    /// must be refused. At the timeout the slot is freed and the attempt
    /// dropped: its stream cancelled, or `abandon` run if it has none yet.
    func admit(host: String, maxForHost: Int? = nil, abandon: @escaping () -> Void) -> Admission? {
        guard !stopped else { return nil }
        var admitted: Admission?
        guard let slot = limiter.acquire(host: host, maxForHost: maxForHost, onTimeout: { [weak self] in
            guard let admission = admitted else { return }
            self?.handshakes[ObjectIdentifier(admission)] = nil
            admission.cancel()
        }) else { return nil }
        let admission = Admission(slot: slot, abandon: abandon)
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
        guard let matched else { return nil }
        if matched == 0 && keys.count > 1, let proven = keys[0] {
            // Dropping the previous key writes to the Keychain: not on this queue.
            let keyConfirmed = self.keyConfirmed
            DispatchQueue.global(qos: .utility).async { keyConfirmed(phoneID, proven) }
        }
        return phoneID
    }

    private func authorized(_ stream: any ByteStream, phoneID: String, rest: Data) {
        let label = phoneLabel(phoneID)
        let connection = ShellConnection(gate: self, stream: stream, phoneID: phoneID, label: label)
        let key = ObjectIdentifier(connection)
        connections[key] = connection
        connection.onClose = { [weak self] in self?.connections[key] = nil }
        ptLog(.info, "shell: a phone connected")
        connection.start(initialBytes: rest, macInfo: macInfo())
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
    private var lines = LineBuffer(limit: RemoteShell.lineLimit)
    private var attached: String?
    /// What the manager returned for the attach to `attached`.
    private(set) var generation: UInt64 = 0
    private var backlog = 0
    private var closed = false
    /// `!closed`, for work running off the queue.
    private let isOpen = Locked(true)
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
    var onClose: (() -> Void)?

    init(gate: ShellGate, stream: any ByteStream, phoneID: String, label: String) {
        self.phoneID = phoneID
        self.gate = gate
        self.manager = gate.manager
        self.transcripts = gate.transcripts
        self.stream = stream
        self.queue = gate.queue
        self.label = label
    }

    /// Sends `ready`, then `macInfo` if the Mac has one, then the session list.
    func start(initialBytes: Data, macInfo: ShellEnvelope? = nil) {
        stream.onTerminated = { [weak self] _ in self?.queue.async { self?.close() } }
        send(ShellEnvelope(t: ShellEnvelope.ready))
        if let macInfo { send(macInfo) }
        var list = ShellEnvelope(t: ShellEnvelope.sessions)
        list.sessions = manager.sessions
        send(list)
        received(initialBytes)
        if busy { readPaused = true } else { receive() }
    }

    /// Asked for the screen: being relayed to Screen Sharing, or about to be.
    var isScreen: Bool { screenChecking || screenDial != nil || screenRelay != nil || screenVideo != nil }

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
        switch message.t {
        case ShellEnvelope.list:
            var reply = ShellEnvelope(t: ShellEnvelope.sessions)
            reply.sessions = manager.sessions
            send(reply)
        case ShellEnvelope.open:
            guard let cols = message.cols, let rows = message.rows else { return fail(.badRequest) }
            open(cols: cols, rows: rows)
        case ShellEnvelope.attach:
            guard let id = message.session, let cols = message.cols, let rows = message.rows else { return fail(.badRequest) }
            if attach(id, cols: cols, rows: rows) { gate?.event("\(label) attached to a session") }
        case ShellEnvelope.input:
            guard let id = message.session, id == attached,
                  let data = message.data.flatMap({ Data(base64Encoded: $0) }) else { return fail(.badRequest, session: message.session) }
            manager.input(id, data)
        case ShellEnvelope.resize:
            guard let id = message.session, id == attached, let cols = message.cols, let rows = message.rows else {
                return fail(.badRequest, session: message.session)
            }
            manager.resize(id, cols: cols, rows: rows)
        case ShellEnvelope.close:
            guard let id = message.session else { return fail(.badRequest) }
            guard manager.sessions.contains(where: { $0.id == id && $0.running }) else { return fail(.noSuchSession, session: id) }
            manager.close(id)
            gate?.event("\(label) closed a session")
        case ShellEnvelope.history:
            sendHistory()
        case ShellEnvelope.transcript:
            guard let id = message.session else { return fail(.badRequest) }
            sendTranscript(id)
        case ShellEnvelope.screen:
            guard gate?.screenAllowed(phoneID) == true else { return fail(.screenNotAllowed) }
            screen()
        case ShellEnvelope.screenVideo:
            guard gate?.screenAllowed(phoneID) == true else { return fail(.screenNotAllowed) }
            guard let source = gate?.screenVideoFactory.get()?(phoneID) else { return fail(.screenVideoUnavailable) }
            streamScreen(source)
        case ShellEnvelope.ping:
            send(ShellEnvelope(t: ShellEnvelope.pong))
        case ShellEnvelope.pong:
            break
        default:
            fail(.badRequest)
        }
    }

    /// Starts a shell on the listener's work queue (spawning one must not hold
    /// up every other phone), then replies and attaches. This connection's
    /// later requests wait until then.
    private func open(cols: Int, rows: Int) {
        guard let gate else { return }
        busy = true
        let manager = self.manager, label = self.label, isOpen = self.isOpen, accepting = gate.accepting, queue = self.queue
        gate.work.async { [weak self] in
            // Not for a phone already gone (revoked, say) or a listener stopping.
            let result = isOpen.get() && accepting.get()
                ? Result { try manager.open(phoneLabel: label, cols: cols, rows: rows) }
                : .failure(ShellError.badRequest)
            queue.async { self?.opened(result, cols: cols, rows: rows) }
        }
    }

    private func opened(_ result: Result<String, Error>, cols: Int, rows: Int) {
        guard !closed else { return }
        switch result {
        case .success(let id):
            gate?.event("\(label) opened a session")
            var reply = ShellEnvelope(t: ShellEnvelope.opened)
            reply.session = id; reply.cols = cols; reply.rows = rows
            send(reply)
            attach(id, cols: cols, rows: rows)
        case .failure(let error):
            fail(error)
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

    /// Reads the transcript's end (at most `TranscriptStore.readLimit`, with
    /// the terminal's sizes) off the queue, then sends it a line at a time,
    /// each after the previous one was taken by the network.
    private func sendTranscript(_ id: String) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let lines = (try? self.transcripts.replay(of: id, maxBytes: TranscriptStore.readLimit))
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

    /// Manager errors keep their reason; anything else (a shell that could not
    /// start) is reported as a bad request.
    private func fail(_ error: Error, session: String? = nil) {
        fail(error as? ShellError ?? .badRequest, session: session)
    }

    private func fail(_ reason: ShellError, session: String? = nil) {
        var reply = ShellEnvelope(t: ShellEnvelope.error)
        reply.reason = reason.rawValue
        reply.session = session
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
