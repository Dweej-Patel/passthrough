import Foundation
import Network

/// SOCKS5 wire helpers shared by the server and tests.
public enum SOCKS5 {
    public static let version: UInt8 = 5
    public enum Method { public static let none: UInt8 = 0, password: UInt8 = 2, unacceptable: UInt8 = 0xFF }
    public enum Command { public static let connect: UInt8 = 1, bind: UInt8 = 2, udpAssociate: UInt8 = 3, forwardUDP: UInt8 = 5 }
    public enum AddressType { public static let ipv4: UInt8 = 1, domain: UInt8 = 3, ipv6: UInt8 = 4 }
    public enum Reply {
        public static let succeeded: UInt8 = 0, generalFailure: UInt8 = 1, notAllowed: UInt8 = 2, networkUnreachable: UInt8 = 3
        public static let hostUnreachable: UInt8 = 4, connectionRefused: UInt8 = 5, ttlExpired: UInt8 = 6
        public static let commandNotSupported: UInt8 = 7, addressTypeNotSupported: UInt8 = 8
    }

    /// A parsed SOCKS5 address (ATYP + ADDR + PORT) keeping its raw bytes so it can be echoed verbatim.
    public struct Address: Hashable, Sendable, CustomStringConvertible {
        public let host: NWEndpoint.Host
        public let port: NWEndpoint.Port
        public let raw: Data

        /// Private, loopback, link-local or multicast: never reachable through
        /// the phone's uplink, so refuse up front instead of waiting on the radio.
        public var isLocalOnly: Bool {
            switch host {
            case .ipv4(let a):
                return Self.isLocalV4([UInt8](a.rawValue))
            case .ipv6(let a):
                let b = [UInt8](a.rawValue)
                guard b.count == 16 else { return false }
                if b[0] == 0xfe, (b[1] & 0xc0) == 0x80 { return true }      // fe80::/10
                if (b[0] & 0xfe) == 0xfc { return true }                    // fc00::/7
                if b[0] == 0xff { return true }                             // multicast
                if b.allSatisfy({ $0 == 0 }) { return true }                // ::
                if b.dropLast().allSatisfy({ $0 == 0 }) && b.last == 1 { return true }   // ::1
                // IPv4-mapped (::ffff:a.b.c.d), IPv4-compatible and NAT64 (64:ff9b::/96): classify the embedded v4.
                let mapped = b[0..<10].allSatisfy { $0 == 0 } && b[10] == 0xff && b[11] == 0xff
                let compat = b[0..<12].allSatisfy { $0 == 0 }
                let nat64 = b[0] == 0x00 && b[1] == 0x64 && b[2] == 0xff && b[3] == 0x9b && b[4..<12].allSatisfy { $0 == 0 }
                if mapped || compat || nat64 { return Self.isLocalV4(Array(b[12..<16])) }
                if b[0] == 0x20, b[1] == 0x02 { return true }               // 2002::/16 (6to4, wraps v4)
                return false
            case .name(let host, _):
                let h = host.lowercased()
                return h == "localhost" || h.hasSuffix(".localhost") || h.hasSuffix(".local") || h.hasSuffix(".home.arpa") || h.hasSuffix(".internal")
            default:
                return false
            }
        }

        static func isLocalV4(_ b: [UInt8]) -> Bool {
            guard b.count == 4 else { return false }
            if b[0] == 10 || b[0] == 127 || b[0] == 0 { return true }
            if b[0] == 172, (16...31).contains(b[1]) { return true }
            if b[0] == 192, b[1] == 168 { return true }
            if b[0] == 169, b[1] == 254 { return true }
            if b[0] == 100, (64...127).contains(b[1]) { return true }   // CGNAT space
            return b[0] >= 224
        }

        public init?(raw: Data) {
            guard let first = raw.first else { return nil }
            let body = raw.dropFirst()
            switch first {
            case AddressType.ipv4:
                guard body.count == 6, let addr = IPv4Address(Data(body.prefix(4))) else { return nil }
                host = .ipv4(addr)
            case AddressType.ipv6:
                guard body.count == 18, let addr = IPv6Address(Data(body.prefix(16))) else { return nil }
                host = .ipv6(addr)
            case AddressType.domain:
                guard let len = body.first, body.count == Int(len) + 3 else { return nil }
                let nameData = body.dropFirst().prefix(Int(len))
                guard let name = String(data: Data(nameData), encoding: .utf8), !name.isEmpty else { return nil }
                host = .name(name, nil)
            default:
                return nil
            }
            let portBytes = raw.suffix(2)
            let p = UInt16(portBytes[portBytes.startIndex]) << 8 | UInt16(portBytes[portBytes.startIndex + 1])
            guard let port = NWEndpoint.Port(rawValue: p) else { return nil }
            self.port = port
            self.raw = raw
        }

        /// Expected total length of an address once the ATYP (and domain length) byte is known.
        public static func expectedLength(atyp: UInt8, domainLength: UInt8 = 0) -> Int? {
            switch atyp {
            case AddressType.ipv4: return 1 + 4 + 2
            case AddressType.ipv6: return 1 + 16 + 2
            case AddressType.domain: return 1 + 1 + Int(domainLength) + 2
            default: return nil
            }
        }

        public static func ipv4(_ bytes: [UInt8], port: UInt16) -> Data {
            Data([AddressType.ipv4] + bytes + [UInt8(port >> 8), UInt8(port & 0xFF)])
        }

        public var description: String { "\(host):\(port)" }
    }

    public static func reply(_ code: UInt8) -> Data {
        Data([version, code, 0, AddressType.ipv4, 0, 0, 0, 0, 0, 0])
    }

    /// Frames a datagram for the "UDP in TCP" extension: [len:2 BE][hdrlen:1][address][payload].
    public static func frameDatagram(address: Data, payload: Data) -> Data {
        var out = Data(capacity: 3 + address.count + payload.count)
        out.append(UInt8(payload.count >> 8)); out.append(UInt8(payload.count & 0xFF))
        out.append(UInt8(3 + address.count))
        out.append(address)
        out.append(payload)
        return out
    }
}

/// The network new outbound connections leave on under "cellular only".
public enum Egress: String, Sendable {
    /// Cellular, required.
    case cellular
    /// The phone is on Wi-Fi, so use it. iOS lets cellular data sleep while
    /// Wi-Fi is up, and UDP (DNS, QUIC, calls, VPNs) can't wake it: forcing
    /// cellular then breaks everything but plain web pages.
    case wifi
    /// Cellular has been unusable for longer than the grace period: any network.
    case fallback
}

/// A SOCKS5 server that turns Mac-originated streams and datagrams into
/// connections opened by the iPhone's own network stack.
public final class SOCKS5Server: @unchecked Sendable {
    public struct Configuration: Sendable {
        public var port: UInt16 = PassthroughProtocol.defaultSOCKSPort
        /// Bind to loopback only; the Mac reaches us through usbmuxd, never the radio.
        public var loopbackOnly = true
        /// Use cellular, unless the phone is on Wi-Fi (see `Egress.wifi`).
        public var cellularOnly = false
        public var allowUDP = true
        public var udpIdleTimeout: TimeInterval = 60
        public var maxUDPPeersPerSession = 512
        /// How long a new connection may sit "waiting" for a viable path (tower
        /// handoff, radio waking) before it is failed. Generous on purpose: apps
        /// have their own timeouts, and a stall that recovers beats a hard error.
        public var connectTimeout: Int = 30
        /// A client that never finishes the SOCKS handshake is dropped after this.
        public var handshakeTimeout: TimeInterval = 20
        /// Hard cap on concurrent sessions (the extension has a tight memory budget).
        public var maxSessions = 4096
        /// Refuse private/link-local/multicast destinations (never reachable via the uplink).
        public var refuseLocalDestinations = true
        public init() {}
    }

    public typealias Authenticator = @Sendable (_ user: String, _ password: String) -> Bool

    public let configuration: Configuration
    public let counter = ByteCounter()
    public var onAuthenticated: (@Sendable (String) -> Void)?
    private let authenticator: Authenticator?
    let queue = DispatchQueue(label: "dev.dpatel.passthrough.socks", qos: .userInitiated, attributes: .concurrent)
    private let stateQueue = DispatchQueue(label: "dev.dpatel.passthrough.socks.state")
    private var listeners: [NWListener] = []
    private var sessions: [ObjectIdentifier: Session] = [:]
    public private(set) var isRunning = false
    /// With "cellular only", tracks whether cellular is actually usable and
    /// whether the phone is on Wi-Fi. A moment where the radio's data path is
    /// down would otherwise fail every connection with "network is down";
    /// instead we fall back to whatever path the phone has until cellular is
    /// viable again.
    private var monitors: [NWPathMonitor] = []
    private let egressLock = NSLock()
    private var cellularUsable = true
    private var onWiFi = false
    private var cellularGraceTimer: DispatchSourceTimer?
    /// How long cellular must be unusable before we fall back to another network.
    public var cellularFallbackGrace: TimeInterval = 10
    /// Called (on an internal queue) when the network for new connections changes.
    public var onEgressChange: (@Sendable (Egress) -> Void)?
    public var egress: Egress { egressLock.lock(); defer { egressLock.unlock() }; return currentEgress }
    /// Call with `egressLock` held.
    private var currentEgress: Egress { onWiFi ? .wifi : (cellularUsable ? .cellular : .fallback) }

    public init(configuration: Configuration = Configuration(), authenticator: Authenticator?) {
        self.configuration = configuration
        self.authenticator = authenticator
    }

    public func start() throws {
        try stateQueue.sync {
            guard !isRunning else { return }
            listeners = []
            var lastError: Error?
            let hosts: [NWEndpoint.Host?] = configuration.loopbackOnly ? [.ipv4(.loopback), .ipv6(.loopback)] : [nil]
            for host in hosts {
                do {
                    let listener = try makeListener(host: host)
                    listeners.append(listener)
                } catch {
                    lastError = error
                    ptLog(.warning, "SOCKS listener on \(host.map { "\($0)" } ?? "*") failed: \(error)")
                }
            }
            if listeners.isEmpty, let lastError { throw lastError }
            isRunning = true
            ptLog(.info, "SOCKS5 listening on port \(configuration.port) (\(listeners.count) listener(s))")
            if configuration.cellularOnly { startEgressMonitors() }
        }
    }

    private func makeListener(host: NWEndpoint.Host?) throws -> NWListener {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let params = NWParameters(tls: nil, tcp: tcp)
        params.allowLocalEndpointReuse = true
        params.acceptLocalOnly = configuration.loopbackOnly
        let port = NWEndpoint.Port(rawValue: configuration.port)!
        if let host {
            params.requiredLocalEndpoint = .hostPort(host: host, port: port)
        }
        let listener = host == nil ? try NWListener(using: params, on: port) : try NWListener(using: params)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            if self.activeSessions >= self.configuration.maxSessions {
                ptLog(.warning, "SOCKS session cap reached (\(self.configuration.maxSessions)); refusing")
                connection.cancel(); return
            }
            let session = Session(server: self, client: connection)
            self.stateQueue.async { self.sessions[ObjectIdentifier(session)] = session }
            session.start()
        }
        listener.stateUpdateHandler = { state in
            switch state {
            case .failed(let error): ptLog(.error, "SOCKS listener failed: \(error)")
            case .cancelled: ptLog(.debug, "SOCKS listener cancelled")
            default: break
            }
        }
        listener.start(queue: queue)
        return listener
    }

    private func startEgressMonitors() {
        let cellular = NWPathMonitor(requiredInterfaceType: .cellular)
        cellular.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            self.cellularGraceTimer?.cancel(); self.cellularGraceTimer = nil
            if path.status == .satisfied {
                self.updateEgress { $0.cellularUsable = true }
            } else {
                // Brief blips (handoffs) must not push traffic onto another network;
                // only a sustained outage does, and it is announced.
                let timer = DispatchSource.makeTimerSource(queue: self.stateQueue)
                timer.schedule(deadline: .now() + self.cellularFallbackGrace)
                timer.setEventHandler { [weak self] in self?.updateEgress { $0.cellularUsable = false } }
                timer.resume()
                self.cellularGraceTimer = timer
            }
        }
        let wifi = NWPathMonitor(requiredInterfaceType: .wifi)
        wifi.pathUpdateHandler = { [weak self] path in
            self?.updateEgress { $0.onWiFi = path.status == .satisfied }
        }
        for monitor in [cellular, wifi] { monitor.start(queue: stateQueue) }
        monitors = [cellular, wifi]
    }

    private func updateEgress(_ change: (SOCKS5Server) -> Void) {
        egressLock.lock()
        let before = currentEgress
        change(self)
        let after = currentEgress
        egressLock.unlock()
        guard after != before else { return }
        switch after {
        case .cellular: ptLog(.info, "New connections use cellular")
        case .wifi: ptLog(.info, "This phone is on Wi-Fi; new connections use Wi-Fi until it leaves")
        case .fallback: ptLog(.warning, "Cellular data has been unusable for \(Int(cellularFallbackGrace))s; new connections use any available network until it is back")
        }
        onEgressChange?(after)
    }

    public func stop() {
        stateQueue.sync {
            guard isRunning else { return }
            isRunning = false
            cellularGraceTimer?.cancel(); cellularGraceTimer = nil
            monitors.forEach { $0.cancel() }; monitors = []
            listeners.forEach { $0.cancel() }
            listeners = []
            let open = Array(sessions.values)
            sessions.removeAll()
            open.forEach { $0.close(reason: "server stopped") }
            ptLog(.info, "SOCKS5 stopped")
        }
    }

    public var activeSessions: Int { stateQueue.sync { sessions.count } }

    fileprivate func remove(_ session: Session) {
        stateQueue.async { self.sessions[ObjectIdentifier(session)] = nil }
    }

    fileprivate func authenticate(user: String, password: String) -> Bool {
        guard let authenticator else { return true }
        let ok = authenticator(user, password)
        if ok { onAuthenticated?(user) }
        return ok
    }

    fileprivate var requiresAuth: Bool { authenticator != nil }

    /// Diagnostics only: pin outbound sockets to a named interface (e.g. "en0")
    /// so a Mac-hosted dev server behaves like a separate egress device.
    private static let egressInterface: String? = ProcessInfo.processInfo.environment["PASSTHROUGH_EGRESS_IF"]
    private static let resolvedInterfaces: [String: NWInterface] = {
        var map: [String: NWInterface] = [:]
        let sem = DispatchSemaphore(value: 0)
        let mon = NWPathMonitor()
        mon.pathUpdateHandler = { path in
            for i in path.availableInterfaces { map[i.name] = i }
            sem.signal()
        }
        mon.start(queue: DispatchQueue(label: "egress.resolve"))
        _ = sem.wait(timeout: .now() + 2)
        mon.cancel()
        return map
    }()
    private static func resolveInterface(_ name: String) -> NWInterface? { resolvedInterfaces[name] }

    fileprivate func remoteParameters(tcp: Bool) -> NWParameters {
        let params: NWParameters
        if tcp {
            let options = NWProtocolTCP.Options()
            options.noDelay = true
            options.connectionTimeout = configuration.connectTimeout
            options.enableKeepalive = true
            options.keepaliveIdle = 30
            params = NWParameters(tls: nil, tcp: options)
        } else {
            params = NWParameters.udp
        }
        if configuration.cellularOnly, egress == .cellular {
            params.requiredInterfaceType = .cellular
        }
        params.preferNoProxies = true
        params.allowFastOpen = false
        if let name = Self.egressInterface, let iface = Self.resolveInterface(name) {
            params.requiredInterface = iface
        }
        return params
    }
}

// MARK: - Session

private final class Session: @unchecked Sendable {
    private let server: SOCKS5Server
    private let client: NWConnection
    private let queue: DispatchQueue
    private var remote: NWConnection?
    private var udpPeers: [SOCKS5.Address: UDPPeer] = [:]
    private var udpTimer: DispatchSourceTimer?
    private var handshakeTimer: DispatchSourceTimer?
    private var waitTimer: DispatchSourceTimer?
    private var closed = false
    private var countedOpen = false
    private var halfClosures = 0
    private var user: String = ""
    /// Last destination this session talked to, for log lines.
    private var remoteLabel = "remote"

    init(server: SOCKS5Server, client: NWConnection) {
        self.server = server
        self.client = client
        self.queue = DispatchQueue(label: "dev.dpatel.passthrough.socks.session", target: server.queue)
    }

    func start() {
        client.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.close(reason: "client closed")
            default: break
            }
        }
        client.start(queue: queue)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + server.configuration.handshakeTimeout)
        timer.setEventHandler { [weak self] in self?.close(reason: "handshake timeout") }
        timer.resume()
        handshakeTimer = timer
        readGreeting()
    }

    /// The request was answered; the handshake watchdog is no longer needed.
    private func handshakeDone() {
        handshakeTimer?.cancel(); handshakeTimer = nil
    }

    // MARK: Byte reading

    private func read(_ count: Int, _ completion: @escaping (Data) -> Void) {
        guard count > 0 else { completion(Data()); return }
        client.receive(minimumIncompleteLength: count, maximumLength: count) { [weak self] data, _, _, error in
            guard let self else { return }
            guard error == nil, let data, data.count == count else {
                self.close(reason: "short read")
                return
            }
            completion(data)
        }
    }

    private func write(_ data: Data, then: (() -> Void)? = nil) {
        client.send(content: data, completion: .contentProcessed { [weak self] error in
            if let error { self?.close(reason: "write failed: \(error)"); return }
            then?()
        })
    }

    // MARK: Handshake

    private func readGreeting() {
        read(2) { [self] head in
            guard head[0] == SOCKS5.version else { close(reason: "not socks5"); return }
            read(Int(head[1])) { [self] methods in
                if server.requiresAuth {
                    guard methods.contains(SOCKS5.Method.password) else {
                        write(Data([SOCKS5.version, SOCKS5.Method.unacceptable])) { self.close(reason: "no auth method") }
                        return
                    }
                    write(Data([SOCKS5.version, SOCKS5.Method.password])) { self.readAuth() }
                } else {
                    guard methods.contains(SOCKS5.Method.none) else {
                        write(Data([SOCKS5.version, SOCKS5.Method.unacceptable])) { self.close(reason: "no auth method") }
                        return
                    }
                    write(Data([SOCKS5.version, SOCKS5.Method.none])) { self.readRequest() }
                }
            }
        }
    }

    private func readAuth() {
        read(2) { [self] head in
            guard head[0] == 1 else { close(reason: "bad auth version"); return }
            read(Int(head[1])) { [self] userData in
                read(1) { [self] plen in
                    read(Int(plen[0])) { [self] passData in
                        let user = String(decoding: userData, as: UTF8.self)
                        let pass = String(decoding: passData, as: UTF8.self)
                        if server.authenticate(user: user, password: pass) {
                            self.user = user
                            write(Data([1, 0])) { self.readRequest() }
                        } else {
                            ptLog(.warning, "SOCKS auth rejected for client \(user.prefix(8))")
                            write(Data([1, 1])) { self.close(reason: "auth failed") }
                        }
                    }
                }
            }
        }
    }

    private func readRequest() {
        read(4) { [self] head in
            guard head[0] == SOCKS5.version, head[2] == 0 else { close(reason: "bad request"); return }
            let cmd = head[1], atyp = head[3]
            let finish: (Data) -> Void = { [self] addrBody in
                guard let address = SOCKS5.Address(raw: Data([atyp]) + addrBody) else {
                    self.write(SOCKS5.reply(SOCKS5.Reply.addressTypeNotSupported)) { self.close(reason: "bad address") }
                    return
                }
                self.dispatch(command: cmd, address: address)
            }
            switch atyp {
            case SOCKS5.AddressType.ipv4: read(6, finish)
            case SOCKS5.AddressType.ipv6: read(18, finish)
            case SOCKS5.AddressType.domain:
                read(1) { [self] len in read(Int(len[0]) + 2) { finish(len + $0) } }
            default:
                write(SOCKS5.reply(SOCKS5.Reply.addressTypeNotSupported)) { self.close(reason: "unsupported atyp") }
            }
        }
    }

    private func dispatch(command: UInt8, address: SOCKS5.Address) {
        switch command {
        case SOCKS5.Command.connect:
            if server.configuration.refuseLocalDestinations, address.isLocalOnly {
                ptLog(.debug, "refused \(address): private/local address, not reachable via the phone")
                write(SOCKS5.reply(SOCKS5.Reply.networkUnreachable)) { self.close(reason: "local-only destination") }
                return
            }
            connect(to: address)
        case SOCKS5.Command.forwardUDP where server.configuration.allowUDP:
            startUDPForwarding()
        default:
            write(SOCKS5.reply(SOCKS5.Reply.commandNotSupported)) { self.close(reason: "unsupported command \(command)") }
        }
    }

    // MARK: CONNECT

    private func connect(to address: SOCKS5.Address) {
        remoteLabel = "\(address)"
        let remote = NWConnection(host: address.host, port: address.port, using: server.remoteParameters(tcp: true))
        self.remote = remote
        var replied = false
        let fail: (NWError) -> Void = { [weak self] error in
            guard let self, !replied else { return }
            replied = true
            self.waitTimer?.cancel()
            let code: UInt8
            switch error {
            case .posix(.ECONNREFUSED): code = SOCKS5.Reply.connectionRefused
            case .posix(.EHOSTUNREACH), .posix(.EHOSTDOWN): code = SOCKS5.Reply.hostUnreachable
            case .posix(.ENETUNREACH), .posix(.ENETDOWN): code = SOCKS5.Reply.networkUnreachable
            case .dns: code = SOCKS5.Reply.hostUnreachable
            default: code = SOCKS5.Reply.generalFailure
            }
            ptLog(.debug, "connect to \(address) failed: \(Self.describe(error))")
            self.write(SOCKS5.reply(code)) { self.close(reason: "connect failed") }
        }
        remote.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                guard !replied else { return }
                replied = true
                self.waitTimer?.cancel(); self.waitTimer = nil
                self.handshakeDone()
                self.countedOpen = true
                self.server.counter.connectionOpened()
                self.write(SOCKS5.reply(SOCKS5.Reply.succeeded)) {
                    self.pump(from: self.client, to: remote, download: false)
                    self.pump(from: remote, to: self.client, download: true)
                }
            case .waiting(let error):
                // The path is not viable yet (e.g. iOS is waking the cellular radio
                // because Wi-Fi is up and we require cellular). Give it a chance.
                guard !replied, self.waitTimer == nil else { return }
                if case .posix(let code) = error, code == .ECONNREFUSED || code == .ECONNRESET {
                    fail(error)   // a definitive answer from the far end; no point waiting
                    return
                }
                let timer = DispatchSource.makeTimerSource(queue: self.queue)
                timer.schedule(deadline: .now() + .seconds(self.server.configuration.connectTimeout))
                timer.setEventHandler { fail(error) }
                timer.resume()
                self.waitTimer = timer
            case .failed(let error):
                remote.stateUpdateHandler = nil
                guard !replied else { self.close(reason: "remote failed"); return }
                fail(error)
            case .cancelled:
                remote.stateUpdateHandler = nil
                self.close(reason: "remote cancelled")
            default:
                break
            }
        }
        remote.start(queue: queue)
    }

    private func pump(from source: NWConnection, to sink: NWConnection, download: Bool) {
        source.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, isComplete, error in
            guard let self, !self.closed else { return }
            if let error {
                if case .posix(.ECANCELED) = error {} else { ptLog(.debug, "stream to \(self.remoteLabel) ended: \(Self.describe(error))") }
                self.close(reason: "stream error")
                return
            }
            if let data, !data.isEmpty {
                if download { self.server.counter.addRx(data.count) } else { self.server.counter.addTx(data.count) }
                sink.send(content: data, completion: .contentProcessed { [weak self] sendError in
                    guard let self else { return }
                    if sendError != nil { self.close(reason: "send failed"); return }
                    if isComplete { self.halfClose(sink) } else { self.pump(from: source, to: sink, download: download) }
                })
            } else if isComplete {
                self.halfClose(sink)
            } else {
                self.pump(from: source, to: sink, download: download)
            }
        }
    }

    private func halfClose(_ sink: NWConnection) {
        sink.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .idempotent)
        halfClosures += 1
        if halfClosures >= 2 { close(reason: "both sides finished") }
    }

    // MARK: UDP over the stream

    private func startUDPForwarding() {
        countedOpen = true
        server.counter.connectionOpened()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 15, repeating: 15)
        timer.setEventHandler { [weak self] in self?.pruneIdlePeers() }
        timer.resume()
        udpTimer = timer
        handshakeDone()
        write(SOCKS5.reply(SOCKS5.Reply.succeeded)) { self.readDatagramFrame() }
    }

    private func readDatagramFrame() {
        read(3) { [self] head in
            let payloadLength = Int(head[0]) << 8 | Int(head[1])
            let headerLength = Int(head[2])
            guard headerLength >= 3 + 1 + 2 else { close(reason: "bad udp frame"); return }
            read(headerLength - 3) { [self] addrBytes in
                guard let address = SOCKS5.Address(raw: addrBytes) else { close(reason: "bad udp address"); return }
                read(payloadLength) { [self] payload in
                    if server.configuration.refuseLocalDestinations, address.isLocalOnly {
                        // Silently drop LAN/multicast probes; nothing on cellular can answer.
                        readDatagramFrame(); return
                    }
                    server.counter.addTx(payload.count)
                    peer(for: address).send(payload)
                    readDatagramFrame()
                }
            }
        }
    }

    /// Human wording for the errors that show up in the diagnostics log.
    static func describe(_ error: NWError) -> String {
        switch error {
        case .posix(let code):
            switch code {
            case .ECONNRESET: return "connection reset by the far end"
            case .ETIMEDOUT: return "timed out"
            case .ECONNREFUSED: return "connection refused"
            case .ENETDOWN: return "network is down (cellular not available)"
            case .ENETUNREACH: return "network unreachable"
            case .EHOSTUNREACH: return "host unreachable"
            default: return String(describing: code)
            }
        case .dns(let code): return "DNS error \(code)"
        default: return String(describing: error)
        }
    }

    private func peer(for address: SOCKS5.Address) -> UDPPeer {
        if let existing = udpPeers[address] {
            if !existing.dead {
                existing.lastActivity = Date()
                return existing
            }
            // The old socket failed or never became viable (radio asleep, cell
            // handoff): replace it, otherwise every later datagram would queue
            // on a corpse forever and e.g. DNS would silently stop working.
            existing.cancel()
            udpPeers[address] = nil
        }
        if udpPeers.count >= server.configuration.maxUDPPeersPerSession, let oldest = udpPeers.min(by: { $0.value.lastActivity < $1.value.lastActivity }) {
            oldest.value.cancel()
            udpPeers[oldest.key] = nil
        }
        remoteLabel = "\(address)"
        let peer = UDPPeer(address: address, parameters: server.remoteParameters(tcp: false), queue: queue,
                           waitTimeout: TimeInterval(server.configuration.connectTimeout)) { [weak self] datagram in
            guard let self, !self.closed else { return }
            self.server.counter.addRx(datagram.count)
            self.write(SOCKS5.frameDatagram(address: address.raw, payload: datagram))
        }
        peer.onDead = { [weak self, weak peer] in
            guard let self, let peer, self.udpPeers[address] === peer else { return }
            self.udpPeers[address] = nil
        }
        udpPeers[address] = peer
        return peer
    }

    private func pruneIdlePeers() {
        let cutoff = Date().addingTimeInterval(-server.configuration.udpIdleTimeout)
        for (key, peer) in udpPeers where peer.lastActivity < cutoff {
            peer.cancel()
            udpPeers[key] = nil
        }
    }

    // MARK: Teardown

    func close(reason: String) {
        queue.async { [self] in
            guard !closed else { return }
            closed = true
            client.cancel()
            remote?.cancel()
            udpTimer?.cancel()
            handshakeTimer?.cancel()
            waitTimer?.cancel()
            udpPeers.values.forEach { $0.cancel() }
            udpPeers.removeAll()
            if countedOpen { server.counter.connectionClosed() }
            server.remove(self)
        }
    }
}

/// One outbound UDP "socket" for a given destination inside a forwarding session.
private final class UDPPeer: @unchecked Sendable {
    private let connection: NWConnection
    private let queue: DispatchQueue
    private var ready = false
    private var pending: [Data] = []
    private var waitTimer: DispatchSourceTimer?
    private let waitTimeout: TimeInterval
    /// Set once the socket failed or never became viable; the session replaces it.
    private(set) var dead = false
    var lastActivity = Date()
    var onDead: (() -> Void)?
    private let onDatagram: (Data) -> Void
    private let label: String

    init(address: SOCKS5.Address, parameters: NWParameters, queue: DispatchQueue, waitTimeout: TimeInterval, onDatagram: @escaping (Data) -> Void) {
        self.onDatagram = onDatagram
        self.label = "\(address)"
        self.queue = queue
        self.waitTimeout = waitTimeout
        connection = NWConnection(host: address.host, port: address.port, using: parameters)
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.waitTimer?.cancel(); self.waitTimer = nil
                self.ready = true
                let queued = self.pending
                self.pending = []
                queued.forEach { self.send($0) }
                self.receiveLoop()
            case .waiting(let error):
                // No viable path right now (radio waking, handoff). Give it a
                // bounded chance, then declare the peer dead so it gets replaced.
                if case .posix(let code) = error, code == .ECONNREFUSED || code == .EHOSTUNREACH || code == .ENETUNREACH {
                    self.markDead("waiting: \(Session.describe(error))"); return
                }
                guard self.waitTimer == nil else { return }
                let timer = DispatchSource.makeTimerSource(queue: self.queue)
                timer.schedule(deadline: .now() + self.waitTimeout)
                timer.setEventHandler { [weak self] in
                    guard let self, !self.ready else { return }
                    self.markDead("no route for \(Int(self.waitTimeout))s (radio asleep or destination unreachable)")
                }
                timer.resume()
                self.waitTimer = timer
            case .failed(let error):
                self.markDead(Session.describe(error))
            case .cancelled:
                self.markDead(nil)
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func markDead(_ why: String?) {
        guard !dead else { return }
        dead = true
        waitTimer?.cancel(); waitTimer = nil
        pending = []
        if let why { ptLog(.debug, "UDP to \(label) reset: \(why)") }
        connection.cancel()
        onDead?()
    }

    func send(_ datagram: Data) {
        lastActivity = Date()
        guard !dead else { return }
        guard ready else {
            if pending.count < 64 { pending.append(datagram) }
            return
        }
        connection.send(content: datagram, completion: .idempotent)
    }

    private func receiveLoop() {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let error {
                if case .posix(.ECANCELED) = error {} else { self.markDead(Session.describe(error)) }
                return
            }
            if let data, !data.isEmpty {
                self.lastActivity = Date()
                self.onDatagram(data)
            }
            self.receiveLoop()
        }
    }

    func cancel() {
        waitTimer?.cancel(); waitTimer = nil
        dead = true
        connection.cancel()
    }
}
