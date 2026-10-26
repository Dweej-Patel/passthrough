import Foundation
import Network

/// What a phone keeps for each Mac that granted it the remote shell (over the
/// cable, in `shellGrant`).
public struct ShellCredential: Codable, Equatable, Sendable {
    public var macID: String
    public var macName: String
    /// SHA-256 of the Mac's certificate: the only one this phone accepts.
    public var certSHA256: String
    public var shellKey: Data
    public var phoneID: String
    public var port: UInt16
    /// Where to dial the Mac, in order (`ShellAddressPolicy.advertisable`).
    public var addresses: [String]
    /// The Mac's iroh endpoint id and home relay, for dialing it from anywhere.
    public var irohID: String?
    public var irohRelay: String?
    /// The relay's token, when the Mac's relay needs one. Never logged.
    public var relayToken: String?

    public init(macID: String, macName: String, certSHA256: String, shellKey: Data, phoneID: String, port: UInt16, addresses: [String],
                irohID: String? = nil, irohRelay: String? = nil, relayToken: String? = nil) {
        self.macID = macID; self.macName = macName; self.certSHA256 = certSHA256; self.shellKey = shellKey
        self.phoneID = phoneID; self.port = port; self.addresses = addresses
        self.irohID = irohID; self.irohRelay = irohRelay; self.relayToken = relayToken
    }
}

/// Printing a credential never shows its secrets: the shell key is left out
/// and the relay token only said to be there.
extension ShellCredential: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String {
        "ShellCredential(macID: \(macID), macName: \(macName), phoneID: \(phoneID), port: \(port), addresses: \(addresses), "
            + "irohID: \(irohID ?? "none"), irohRelay: \(irohRelay ?? "none"), relayToken: \(relayToken == nil ? "none" : "<redacted>"))"
    }

    public var debugDescription: String { description }
}

extension ShellCredential: CustomReflectable {
    /// `dump` and debuggers see the same redacted fields.
    public var customMirror: Mirror {
        Mirror(self, children: ["macID": macID, "macName": macName, "phoneID": phoneID, "port": port, "addresses": addresses,
                                "irohID": irohID as Any, "irohRelay": irohRelay as Any,
                                "relayToken": relayToken == nil ? "none" : "<redacted>"], displayStyle: .struct)
    }
}

/// Which ways a phone may dial its Mac's shell (a per-device setting).
public enum ShellConnectMode: String, CaseIterable, Sendable {
    /// Local network and Tailscale addresses, then iroh (from anywhere).
    case automatic
    /// Local network and Tailscale addresses only.
    case localOnly
}

/// How the connection that reached `ready` is carried.
public enum ShellPath: String, Sendable {
    /// TLS over TCP: the local network, Tailscale or a typed address.
    case local
    /// iroh, straight to the Mac (LAN or a hole-punched path).
    case direct
    /// iroh, through a relay.
    case relay
    /// iroh, path not known yet.
    case unknown
}

/// Dials the Mac over iroh for `ShellClient`, keeping PassthroughCore free of
/// iroh itself (the app injects IrohTransport's `IrohShellDialer`).
public protocol ShellIrohDialing: AnyObject, Sendable {
    /// Connects to the Mac's endpoint `irohID` (through `relayURL`, a custom
    /// relay that may need `relayToken`, or the default relays when nil;
    /// `addresses` are known direct "ip:port" sockets) and opens the shell's
    /// stream. Nothing is written yet.
    func connect(irohID: String, relayURL: String?, relayToken: String?, addresses: [String]) async throws -> any ByteStream
    /// How a stream `connect` returned is carried right now.
    func path(of stream: any ByteStream) -> ShellPath
    /// Ends every dial in progress and closes the endpoint and its streams.
    /// A later `connect` starts afresh.
    func shutdown()
}

/// The phone's side of the remote shell (protocol/README.md, "Remote shell"):
/// dials the Mac over TLS pinned to its certificate and, from anywhere, over
/// iroh to its endpoint id; proves the shell key, then talks to one attached
/// session at a time.
public final class ShellClient: @unchecked Sendable {
    /// One way to dial the Mac.
    public enum Candidate: Equatable, Sendable {
        /// TLS to a Bonjour result or address.
        case tcp(NWEndpoint)
        /// iroh to the Mac's endpoint id.
        case iroh
    }

    public enum Event: Sendable {
        /// Authorized; commands are accepted. `path`: how, as known now.
        case ready(path: ShellPath)
        /// The Mac's current iroh details and addresses (sent after `ready`),
        /// for the phone to keep with its grant.
        case macInfo(ShellEnvelope)
        /// How the Mac is doing (after `ready`, and whenever it changes).
        case macState(MacState)
        /// The answer to `requestEvents`: what happened since then, oldest first, and the battery meanwhile.
        case events(since: Double, [MacEvent], battery: [BatterySample])
        case sessions([ShellSessionInfo])
        /// A session this client opened; it is attached to it.
        case opened(String)
        /// A session this client opened after all, though an `attach` made
        /// before the Mac answered took its place: it runs detached.
        case openedDetached(String)
        /// The Mac refused an `open` this client made: no `opened` comes for it.
        case openFailed(ShellError)
        case output(session: String, Data)
        /// The replay after an `attach` is complete; later output is live.
        case attached(session: String)
        case ended(session: String, exitStatus: Int32)
        /// Another connection took the session over.
        case detached(session: String)
        case history([ShellHistoryEntry])
        case transcript(session: String, Data, done: Bool)
        /// The recorded terminal took this size here: the `transcript` data that
        /// follows was drawn for it. Comes first, then wherever the size changed.
        case transcriptResize(session: String, cols: Int, rows: Int)
        /// The Mac refused something; after `.notAuthorized` the connection closes.
        /// `session` is the one the refused request named, if it named one.
        case failed(ShellError, session: String?)
        /// The connection is gone (nil: `disconnect()` was called). Sent once per `connect`.
        case disconnected(Error?)
        /// The Mac answered `requestScreen`: the stream is now Screen
        /// Sharing's (or with `video`, `ScreenVideoWire`'s), starting with
        /// `initialBytes`. The client lets go of it
        /// and sends nothing more (not even `disconnected`); over iroh the
        /// stream lasts until the dialer passed to `init` is shut down.
        case screen(any ByteStream, initialBytes: Data)
    }

    public enum ConnectError: Error, Sendable {
        case noAddress
        case timedOut
        case protocolViolation
        /// A ready connection went silent: nothing from the Mac within `Liveness`'s limits.
        case stoppedAnswering
    }

    /// How a ready connection that died without closing (the cable pulled
    /// while the shell used its network, Wi-Fi gone, the Mac asleep) is
    /// told from a quiet one. The phone pings the Mac whenever it has heard
    /// nothing for `interval`, and gives the connection up once it has heard
    /// nothing for `silence`. When the system says the connection's path
    /// failed (its interface went away), anything from the Mac must arrive
    /// within `probe` of a ping instead.
    public struct Liveness: Sendable {
        public var interval: TimeInterval
        public var silence: TimeInterval
        public var probe: TimeInterval

        public init(interval: TimeInterval = 5, silence: TimeInterval = 15, probe: TimeInterval = 2) {
            self.interval = interval; self.silence = silence; self.probe = probe
        }
    }

    /// How long one address gets to answer and authorize before it is given up.
    static let attemptTimeout: TimeInterval = 4
    /// The same for iroh, which may first have to reach a relay and punch a hole.
    static let irohAttemptTimeout: TimeInterval = 10
    /// Each further address is dialled this long after the previous one (or
    /// at once if that one failed), so an address that never answers does
    /// not hold up one that does: the first to authorize wins.
    static let stagger: TimeInterval = 0.25
    /// iroh starts this long after the first address, so a local or Tailscale
    /// path that answers quickly is preferred; at once when there are none.
    static let irohDelay: TimeInterval = 0.75

    /// One candidate being dialled, or the connection that won.
    private final class Attempt {
        let isIroh: Bool
        /// Nil while an iroh dial is still connecting.
        var stream: (any ByteStream)?
        var dial: Task<Void, Never>?
        var lines = LineBuffer(limit: RemoteShell.lineLimit)
        var challenged = false
        init(isIroh: Bool, stream: (any ByteStream)?) { self.isIroh = isIroh; self.stream = stream }
    }

    private let credential: ShellCredential
    private let iroh: (any ShellIrohDialing)?
    private let mode: ShellConnectMode
    private let liveness: Liveness
    private let callbackQueue: DispatchQueue
    private let onEvent: (Event) -> Void
    /// All state below lives on this queue.
    private let work = DispatchQueue(label: "\(PassthroughProtocol.identifier).shell-client")
    /// Attempts still dialling, and once `ready` only the one that won.
    private var attempts: [Int: Attempt] = [:]
    private var winner: Int?
    /// Candidates not dialled yet, with their place in the schedule.
    private var candidates: [(candidate: Candidate, delay: TimeInterval)] = []
    /// Bumped by every dial, retiring the timer that would have started the next one.
    private var dialToken = 0
    private var nextAttempt = 0
    /// Bumped by every `connect` and `teardown`, retiring scheduled dials.
    private var generation = 0
    /// Why the last failed attempt failed: reported if none succeeds.
    private var lastError: Error = ConnectError.noAddress
    private var ready = false
    private var active = false
    /// Commands made before `ready`, sent once it arrives.
    private var queued: [ShellEnvelope] = []
    /// The session `input` goes to.
    private var current: String?
    #if DEBUG
    /// For tests: called on `work` with each line's `t` once it's handled.
    let lineHandled = Locked<(@Sendable (String) -> Void)?>(nil)
    #endif
    /// Sessions that ended or were taken over while an `open` was unanswered:
    /// if one is that open's, its `opened` leaves nothing `current` (the Mac
    /// attached it, then lost it).
    private var goneSessions: Set<String> = []
    /// Numbers `open`s (the Mac echoes the number in the answer). An `attach`
    /// overtakes every open numbered up to `overtakenThrough`: the Mac
    /// attaches it after the sessions they make. `answeredThrough` is the
    /// last whose answer the app has been given. Set by the app's own calls
    /// and as answers are delivered, so under `opensLock`, not on `work`.
    private let opensLock = NSLock()
    private var lastOpenRef = 0
    private var overtakenThrough = 0
    private var answeredThrough = 0
    /// `requestScreen` was called: lines are read only up to `screenReady`.
    private var screenRequested = false
    /// When the winner last delivered anything.
    private var lastHeard = DispatchTime.now()
    /// A ping is out because the winner's path failed; cleared by anything heard.
    private var probing = false
    /// Bumped per probe, so an answered probe's timer can't end a later one early.
    private var probeToken = 0

    /// `iroh` dials the Mac from anywhere (nil: TLS only); `mode` is the
    /// phone's "Connect using" setting.
    public init(credential: ShellCredential, queue: DispatchQueue = .main, iroh: (any ShellIrohDialing)? = nil,
                mode: ShellConnectMode = .automatic, liveness: Liveness = Liveness(), onEvent: @escaping (Event) -> Void) {
        self.credential = credential
        self.iroh = iroh
        self.mode = mode
        self.liveness = liveness
        self.callbackQueue = queue
        self.onEvent = onEvent
    }

    /// Where to dial: the Bonjour result first, then each granted address.
    public static func candidates(for credential: ShellCredential, discovered: NWEndpoint?) -> [NWEndpoint] {
        let addresses: [NWEndpoint] = NWEndpoint.Port(rawValue: credential.port).map { port in
            credential.addresses.map { .hostPort(host: NWEndpoint.Host($0), port: port) }
        } ?? []
        return (discovered.map { [$0] } ?? []) + addresses
    }

    /// When to dial each candidate, in seconds after the first: the TLS
    /// candidates `stagger` apart, and iroh (in `.automatic` mode, for a Mac
    /// that gave its endpoint id) `irohDelay` after the first of them, or at
    /// once when there are none. Sorted; TLS first on a tie.
    public static func schedule(for credential: ShellCredential, discovered: NWEndpoint?,
                                mode: ShellConnectMode) -> [(candidate: Candidate, delay: TimeInterval)] {
        var plan = candidates(for: credential, discovered: discovered).enumerated().map { i, endpoint in
            (candidate: Candidate.tcp(endpoint), delay: Double(i) * stagger)
        }
        guard mode == .automatic, let id = credential.irohID, IrohInfo.isValidID(id) else { return plan }
        let delay = plan.isEmpty ? 0 : irohDelay
        let at = plan.firstIndex { $0.delay > delay } ?? plan.endIndex
        plan.insert((.iroh, delay), at: at)
        return plan
    }

    /// Dials the candidates on their schedule until one authorizes; the
    /// others are then dropped. A new call replaces any connection in progress.
    public func connect(discovered: NWEndpoint? = nil) {
        work.async { [self] in
            teardown()
            active = true
            candidates = Self.schedule(for: credential, discovered: discovered, mode: mode)
                .filter { $0.candidate != .iroh || iroh != nil }
            lastError = ConnectError.noAddress
            dialNext(generation)
        }
    }

    public func disconnect() {
        work.async { [self] in
            guard active else { return }
            teardown()
            emit(.disconnected(nil))
        }
    }

    public func list() { command(ShellEnvelope(t: ShellEnvelope.list)) }

    public func open(cols: Int, rows: Int) {
        var m = ShellEnvelope(t: ShellEnvelope.open)
        m.cols = cols; m.rows = rows
        opensLock.lock()
        lastOpenRef += 1
        let ref = lastOpenRef
        opensLock.unlock()
        m.ref = ref
        work.async { [self] in
            // Never sent, so never answered.
            guard active else { return answered(ref) }
            enqueue(m)
        }
    }

    /// An `open` is unanswered, and no `attach` has overtaken it: the session
    /// it makes will be the attached one. As of the events delivered so far.
    public var openPending: Bool {
        opensLock.lock(); defer { opensLock.unlock() }
        return lastOpenRef > max(answeredThrough, overtakenThrough)
    }

    public func attach(_ session: String, cols: Int, rows: Int) {
        var m = ShellEnvelope(t: ShellEnvelope.attach)
        m.session = session; m.cols = cols; m.rows = rows
        opensLock.lock()
        overtakenThrough = lastOpenRef
        opensLock.unlock()
        work.async { [self] in
            current = session
            enqueue(m)
        }
    }

    /// Keystrokes for the attached session, split into protocol-sized pieces.
    /// Dropped while an `open` is pending: the Mac reads them after attaching
    /// the new session, and would refuse them for the old one.
    public func input(_ data: Data) {
        guard !openPending else { return }
        work.async { [self] in
            guard let session = current else { return }
            var offset = 0
            while offset < data.count {
                let end = min(offset + RemoteShell.outputChunk, data.count)
                var m = ShellEnvelope(t: ShellEnvelope.input)
                m.session = session
                m.data = data.subdata(in: (data.startIndex + offset)..<(data.startIndex + end)).base64EncodedString()
                enqueue(m)
                offset = end
            }
        }
    }

    /// The terminal's size, for whatever session the Mac has attached when
    /// it reads this, so also one an unanswered `open` is about to attach.
    /// It names `current` only for Macs before that, which required it.
    /// Not sent before `ready`: nothing is attached then, and `attach` carries the size.
    public func resize(cols: Int, rows: Int) {
        work.async { [self] in
            guard ready else { return }
            var m = ShellEnvelope(t: ShellEnvelope.resize)
            m.session = current; m.cols = cols; m.rows = rows
            enqueue(m)
        }
    }

    public func close(_ session: String) {
        var m = ShellEnvelope(t: ShellEnvelope.close)
        m.session = session
        command(m)
    }

    public func requestHistory() { command(ShellEnvelope(t: ShellEnvelope.history)) }

    /// Asks the Mac to turn Keep awake on or off. The new state comes back as
    /// `.macState`, or `.failed` says why not.
    public func setAwake(_ on: Bool) {
        var m = ShellEnvelope(t: ShellEnvelope.setAwake)
        m.on = on
        command(m)
    }

    /// Asks what happened on the Mac since `since`: `.events` follows, or `.failed(.badRequest)` from an older Mac.
    public func requestEvents(since: Date) {
        var m = ShellEnvelope(t: ShellEnvelope.events)
        m.since = since.timeIntervalSince1970.rounded(.down)
        command(m)
    }

    /// As `setAwake`, for the Mac's VPN.
    public func setVPN(_ on: Bool) {
        var m = ShellEnvelope(t: ShellEnvelope.setVPN)
        m.on = on
        command(m)
    }

    /// Asks to see the screen (protocol/README.md, "Screen"): `.screen` when
    /// the Mac hands the connection over, or `.failed` with the reason it
    /// won't. `video` asks for the Mac's own stream instead of Screen
    /// Sharing; a Mac that can't (or is too old to know it) fails the request
    /// and the connection stays usable, so the other can be asked for next.
    /// Use a client of its own for the screen, never one with a session.
    public func requestScreen(video: Bool = false) {
        work.async { [self] in
            guard active else { return }
            screenRequested = true
            enqueue(ShellEnvelope(t: video ? ShellEnvelope.screenVideo : ShellEnvelope.screen))
        }
    }

    public func requestTranscript(_ session: String) {
        var m = ShellEnvelope(t: ShellEnvelope.transcript)
        m.session = session
        command(m)
    }

    // MARK: Connection (on `work`)

    private func command(_ message: ShellEnvelope) {
        work.async { [self] in enqueue(message) }
    }

    private func enqueue(_ message: ShellEnvelope) {
        guard active else { return }
        if ready { send(message) } else { queued.append(message) }
    }

    /// Starts the next candidate, and schedules the one after it.
    private func dialNext(_ gen: Int) {
        guard active, gen == generation, !ready else { return }
        guard !candidates.isEmpty else {
            if attempts.isEmpty { finish(lastError) }
            return
        }
        let (candidate, delay) = candidates.removeFirst()
        dialToken += 1
        nextAttempt += 1
        let id = nextAttempt
        switch candidate {
        case .tcp(let endpoint): dialTCP(id, endpoint)
        case .iroh: dialIroh(id)
        }
        if let next = candidates.first {
            let token = dialToken
            work.asyncAfter(deadline: .now() + max(0, next.delay - delay)) { [weak self] in
                guard let self, self.dialToken == token else { return }
                self.dialNext(gen)
            }
        }
    }

    private func dialTCP(_ id: Int, _ endpoint: NWEndpoint) {
        let connection = NWConnection(to: endpoint, using: WirelessLink.pinnedClientParameters(pin: credential.certSHA256, peerToPeer: false))
        // TCP alone notices a vanished interface only after minutes of retries.
        // Both run on `work`, where the stream starts the connection.
        connection.viabilityUpdateHandler = { [weak self] viable in if !viable { self?.pathFailed(id) } }
        connection.pathUpdateHandler = { [weak self] path in if path.status == .unsatisfied { self?.pathFailed(id) } }
        let stream = ConnectionStream(connection, queue: work)
        attempts[id] = Attempt(isIroh: false, stream: stream)
        watch(id, stream)
        startTimeout(id, Self.attemptTimeout)
        receive(id, stream)
    }

    /// Dials iroh; once the stream is open, says `hello` (the Mac waits for the
    /// phone's first line on iroh) and then answers the challenge as on TLS.
    private func dialIroh(_ id: Int) {
        guard let iroh, let irohID = credential.irohID else { return }
        let attempt = Attempt(isIroh: true, stream: nil)
        attempts[id] = attempt
        startTimeout(id, Self.irohAttemptTimeout)
        let relayURL = credential.irohRelay, relayToken = credential.relayToken
        // The granted addresses are the TLS listener's hosts, without iroh's
        // port: iroh finds direct paths through the relay instead.
        attempt.dial = Task { [weak self] in
            do {
                let stream = try await iroh.connect(irohID: irohID, relayURL: relayURL, relayToken: relayToken, addresses: [])
                guard let self else { return stream.cancel() }
                self.work.async { self.irohOpened(id, stream) }
            } catch {
                self?.work.async { self?.attemptEnded(id, error) }
            }
        }
    }

    private func irohOpened(_ id: Int, _ stream: any ByteStream) {
        guard active, let attempt = attempts[id] else { return stream.cancel() }
        attempt.stream = stream
        watch(id, stream)
        send(ShellEnvelope(t: ShellEnvelope.hello), on: stream)
        receive(id, stream)
    }

    private func watch(_ id: Int, _ stream: any ByteStream) {
        stream.onTerminated = { [weak self] error in
            self?.work.async { self?.attemptEnded(id, error ?? MuxError.linkClosed) }
        }
    }

    private func startTimeout(_ id: Int, _ timeout: TimeInterval) {
        work.asyncAfter(deadline: .now() + timeout) { [weak self] in
            guard let self, self.attempts[id] != nil, self.winner != id else { return }
            self.attemptEnded(id, ConnectError.timedOut)
        }
    }

    private func receive(_ id: Int, _ stream: any ByteStream) {
        stream.receive(maximumLength: 65536) { [weak self] data, complete, error in
            guard let self else { return }
            self.work.async {
                guard self.active, let attempt = self.attempts[id] else { return }
                if let data, !data.isEmpty {
                    if id == self.winner { self.heard() }
                    do {
                        // Past `screenReady` the bytes are Screen Sharing's, not lines.
                        let lines = self.screenRequested
                            ? try attempt.lines.append(data) { Self.isScreenReady($0) }
                            : try attempt.lines.append(data)
                        for line in lines {
                            self.handle(line, from: id)
                            guard self.active, self.attempts[id] != nil else { return }
                        }
                    } catch {
                        return self.attemptEnded(id, ConnectError.protocolViolation)
                    }
                }
                if complete || error != nil { return self.attemptEnded(id, error ?? MuxError.linkClosed) }
                self.receive(id, stream)
            }
        }
    }

    /// An attempt failed: before `ready` the others carry on (and the next
    /// address is dialled at once); once none is left, nor the one that won,
    /// the connection is over.
    private func attemptEnded(_ id: Int, _ error: Error) {
        guard active, let attempt = attempts.removeValue(forKey: id) else { return }
        drop(attempt)
        if id == winner { return finish(error) }
        lastError = error
        if candidates.isEmpty {
            if attempts.isEmpty { finish(error) }
        } else {
            dialNext(generation)
        }
    }

    /// The attempt authorized: it carries the connection, the rest are dropped.
    private func won(_ id: Int) {
        ready = true
        winner = id
        candidates = []
        for (other, attempt) in attempts where other != id {
            drop(attempt)
            attempts[other] = nil
        }
        heard()
        heartbeat(generation)
    }

    // MARK: Liveness (on `work`)

    private func heard() {
        lastHeard = .now()
        probing = false
    }

    private var secondsSinceHeard: TimeInterval {
        Double(DispatchTime.now().uptimeNanoseconds - lastHeard.uptimeNanoseconds) / 1e9
    }

    /// While ready: pings a quiet Mac and gives up on a silent one. The
    /// Mac answers every `ping` with `pong`, and anything it sends counts.
    private func heartbeat(_ gen: Int) {
        let wait = min(liveness.interval, max(0.05, liveness.silence - secondsSinceHeard))
        work.asyncAfter(deadline: .now() + wait) { [weak self] in
            guard let self, self.active, self.ready, gen == self.generation else { return }
            let quiet = self.secondsSinceHeard
            if quiet >= self.liveness.silence { return self.finish(ConnectError.stoppedAnswering) }
            if quiet >= self.liveness.interval { self.send(ShellEnvelope(t: ShellEnvelope.ping)) }
            self.heartbeat(gen)
        }
    }

    /// The system says the winner's path failed: its interface went away
    /// (the cable unplugged, Wi-Fi lost). It may come back, so rather than
    /// drop the connection at once, ping: one the Mac answers within
    /// `liveness.probe` carries on, one it doesn't is given up, and the
    /// caller dials again over whatever path is left.
    private func pathFailed(_ id: Int) {
        guard active, ready, id == winner, !probing else { return }
        probing = true
        probeToken += 1
        let gen = generation, token = probeToken
        send(ShellEnvelope(t: ShellEnvelope.ping))
        work.asyncAfter(deadline: .now() + liveness.probe) { [weak self] in
            guard let self, self.active, gen == self.generation, self.probing, token == self.probeToken else { return }
            self.finish(ConnectError.stoppedAnswering)
        }
    }

    /// Closes an attempt that lost or failed; for iroh also its endpoint.
    private func drop(_ attempt: Attempt) {
        attempt.stream?.onTerminated = nil
        attempt.stream?.cancel()
        attempt.dial?.cancel()
        if attempt.isIroh { iroh?.shutdown() }
    }

    private func handle(_ line: Data, from id: Int) {
        guard let message = try? ShellEnvelope.decode(line), let attempt = attempts[id] else { return }
        if !ready {
            switch message.t {
            case ShellEnvelope.challenge where !attempt.challenged:
                guard let nonce = message.nonce.flatMap({ Data(base64Encoded: $0) }), nonce.count == 32 else {
                    return attemptEnded(id, ConnectError.protocolViolation)
                }
                attempt.challenged = true
                var proof = ShellEnvelope(t: ShellEnvelope.proof)
                proof.phoneID = credential.phoneID
                proof.mac = RemoteShell.proof(shellKey: credential.shellKey, nonce: nonce).base64EncodedString()
                guard let stream = attempt.stream else { return }
                send(proof, on: stream)
            case ShellEnvelope.ready where attempt.challenged:
                won(id)
                let path = attempt.isIroh ? (attempt.stream.flatMap { iroh?.path(of: $0) } ?? .unknown) : .local
                emit(.ready(path: path))
                let pending = queued
                queued = []
                pending.forEach(send)
            case ShellEnvelope.error:
                // Refused by the Mac itself (inside the pinned tunnel, or iroh
                // authenticated by endpoint id): every other path would get
                // the same answer.
                let reason = ShellError(rawValue: message.reason ?? "") ?? .notAuthorized
                emit(.failed(reason, session: message.session))
                finish(reason)
            default:
                attemptEnded(id, ConnectError.protocolViolation)
            }
            return
        }
        guard id == winner else { return }
        #if DEBUG
        defer { lineHandled.get()?(message.t) }
        #endif
        switch message.t {
        case ShellEnvelope.macInfo:
            emit(.macInfo(message))
        case ShellEnvelope.macState:
            guard let state = message.state else { return }
            emit(.macState(state))
        case ShellEnvelope.eventList:
            emit(.events(since: message.since ?? 0, message.events ?? [], battery: message.battery ?? []))
        case ShellEnvelope.sessions:
            emit(.sessions(message.sessions ?? []))
        case ShellEnvelope.opened:
            guard let id = message.session else { return }
            // Judged as it's delivered, in order with the app's own `attach`
            // calls: one made before then overtook the open, though `work`
            // may not have seen it yet.
            let ref = message.ref, onEvent = self.onEvent
            callbackQueue.async { [self] in
                if takesOver(ref) {
                    work.async { [self] in current = goneSessions.remove(id) == nil ? id : nil }
                    onEvent(.opened(id))
                } else {
                    work.async { [self] in goneSessions.remove(id) }
                    onEvent(.openedDetached(id))
                }
            }
        case ShellEnvelope.output:
            guard let id = message.session, let data = message.data.flatMap({ Data(base64Encoded: $0) }) else { return }
            emit(.output(session: id, data))
        case ShellEnvelope.attached:
            guard let id = message.session else { return }
            emit(.attached(session: id))
        case ShellEnvelope.ended:
            guard let id = message.session else { return }
            if current == id { current = nil }
            if openUnanswered { goneSessions.insert(id) }
            emit(.ended(session: id, exitStatus: message.exitStatus ?? -1))
        case ShellEnvelope.detached:
            guard let id = message.session else { return }
            if current == id { current = nil }
            if openUnanswered { goneSessions.insert(id) }
            emit(.detached(session: id))
        case ShellEnvelope.historyList:
            emit(.history(message.history ?? []))
        case ShellEnvelope.transcriptData:
            guard let id = message.session, let data = message.data.flatMap({ Data(base64Encoded: $0) }) else { return }
            if let cols = message.cols, let rows = message.rows, ShellReplay.isValid(cols: cols, rows: rows) {
                emit(.transcriptResize(session: id, cols: cols, rows: rows))
            }
            emit(.transcript(session: id, data, done: message.done ?? false))
        case ShellEnvelope.error:
            let reason = ShellError(rawValue: message.reason ?? "") ?? .badRequest
            // The Mac did not attach the session `attach` named: stop sending it input it would refuse.
            if reason == .noSuchSession, let id = message.session, current == id { current = nil }
            if let ref = message.ref {
                let onEvent = self.onEvent
                callbackQueue.async { [self] in
                    answered(ref)
                    onEvent(.openFailed(reason))
                }
            } else {
                emit(.failed(reason, session: message.session))
            }
        case ShellEnvelope.ping:
            send(ShellEnvelope(t: ShellEnvelope.pong))
        case ShellEnvelope.screenReady where screenRequested, ShellEnvelope.screenVideoReady where screenRequested:
            handOver(id)
        default:
            break
        }
    }

    private static func isScreenReady(_ line: Data) -> Bool {
        let type = (try? ShellEnvelope.decode(line))?.t
        return type == ShellEnvelope.screenReady || type == ShellEnvelope.screenVideoReady
    }

    /// Gives the winning stream to the screen viewer and steps aside: no
    /// more reads, sends or events, and no `disconnected`.
    private func handOver(_ id: Int) {
        guard let attempt = attempts.removeValue(forKey: id), let stream = attempt.stream else { return }
        stream.onTerminated = nil
        let rest = attempt.lines.takePending()
        active = false
        generation += 1
        winner = nil
        ready = false
        queued = []
        emit(.screen(stream, initialBytes: rest))
    }

    private func send(_ message: ShellEnvelope) {
        guard let winner, let stream = attempts[winner]?.stream else { return }
        send(message, on: stream)
    }

    private func send(_ message: ShellEnvelope, on stream: any ByteStream) {
        guard let line = try? message.encodedLine() else { return }
        stream.send(line, isComplete: false) { _ in }
    }

    /// Ends this `connect` for good and says so once.
    private func finish(_ error: Error?) {
        guard active else { return }
        teardown()
        emit(.disconnected(error))
    }

    /// Whether the session `open` `ref` made is the one the Mac has attached
    /// (no `attach` since overtook it).
    private func takesOver(_ ref: Int?) -> Bool {
        opensLock.lock(); defer { opensLock.unlock() }
        // A Mac that doesn't echo `ref` answers in order: count it as the
        // latest (none made yet: no attach can have overtaken it).
        let ref = ref ?? lastOpenRef
        answeredThrough = max(answeredThrough, ref)
        return ref == 0 || ref > overtakenThrough
    }

    /// Some `open` has no answer delivered yet, overtaken or not.
    private var openUnanswered: Bool {
        opensLock.lock(); defer { opensLock.unlock() }
        return lastOpenRef > answeredThrough
    }

    private func answered(_ ref: Int) {
        opensLock.lock(); defer { opensLock.unlock() }
        answeredThrough = max(answeredThrough, ref)
    }

    private func teardown() {
        active = false
        generation += 1
        for attempt in attempts.values { drop(attempt) }
        attempts = [:]
        winner = nil
        candidates = []
        queued = []
        ready = false
        current = nil
        goneSessions = []
        probing = false
    }

    private func emit(_ event: Event) {
        let onEvent = self.onEvent
        callbackQueue.async { onEvent(event) }
    }
}
