import Foundation
import Network
import CryptoKit

/// Facts about the phone the Mac likes to display.
public struct DeviceStatus: Sendable, Equatable {
    public var deviceName: String
    public var radio: String?
    public var carrier: String?
    public var battery: Double?
    public var hosting: String
    /// Whether the network the phone sends Mac traffic out on routes IPv6; nil when unknown.
    public var ipv6: Bool?
    public init(deviceName: String, radio: String? = nil, carrier: String? = nil, battery: Double? = nil, hosting: String, ipv6: Bool? = nil) {
        self.deviceName = deviceName; self.radio = radio; self.carrier = carrier; self.battery = battery; self.hosting = hosting; self.ipv6 = ipv6
    }
}

/// A connected Mac as seen by the phone.
public struct ConnectedMac: Identifiable, Sendable, Equatable, Codable {
    public let id: String
    public let name: String
    public let since: Date
    /// Over the wireless link rather than the cable; nil when the Mac didn't say.
    public let wireless: Bool?
    public init(id: String, name: String, since: Date, wireless: Bool? = nil) {
        self.id = id; self.name = name; self.since = since; self.wireless = wireless
    }
}

/// Newline-delimited JSON control channel: pairing, heartbeat, live status.
/// Anything on the phone can connect to its loopback port (and over adb, so
/// can anything on the Mac), so a connection is a stranger until the Mac
/// proves its pairing (`auth`) or pairs with the code shown. Only then is it
/// sent status or allowed to change anything.
public final class ControlServer: @unchecked Sendable {
    public let port: UInt16
    private let registry: PairingRegistry
    private let counter: ByteCounter
    private let statusProvider: @Sendable () -> DeviceStatus
    private let socksPort: UInt16
    fileprivate let queue = DispatchQueue(label: "\(PassthroughProtocol.identifier).control")
    private var listeners: [NWListener] = []
    private var peers: [ObjectIdentifier: Peer] = [:]
    public private(set) var isRunning = false
    public var onClientsChanged: (@Sendable ([ConnectedMac]) -> Void)?
    /// How long a connection may go without proving a pairing, and an
    /// authenticated Mac on the cable without a word. Shorter in tests.
    private let unauthenticatedTimeout: TimeInterval
    private let cableSilenceLimit: TimeInterval

    public init(port: UInt16 = PassthroughProtocol.defaultControlPort,
                socksPort: UInt16,
                registry: PairingRegistry,
                counter: ByteCounter,
                unauthenticatedTimeout: TimeInterval = PassthroughProtocol.unauthenticatedTimeout,
                cableSilenceLimit: TimeInterval = PassthroughProtocol.cableSilenceLimit,
                statusProvider: @escaping @Sendable () -> DeviceStatus) {
        self.port = port
        self.socksPort = socksPort
        self.registry = registry
        self.counter = counter
        self.unauthenticatedTimeout = unauthenticatedTimeout
        self.cableSilenceLimit = cableSilenceLimit
        self.statusProvider = statusProvider
    }

    public func start() throws {
        try queue.sync {
            guard !isRunning else { return }
            var lastError: Error?
            for host in [NWEndpoint.Host.ipv4(.loopback), .ipv6(.loopback)] {
                do { listeners.append(try makeListener(host: host)) } catch { lastError = error }
            }
            if listeners.isEmpty, let lastError { throw lastError }
            isRunning = true
            ptLog(.info, "Control channel listening on port \(port)")
        }
    }

    public func stop() {
        queue.sync {
            guard isRunning else { return }
            isRunning = false
            listeners.forEach { $0.cancel() }
            listeners = []
            peers.values.forEach { $0.cancel() }
            peers.removeAll()
            onClientsChanged?([])
        }
    }

    public var connectedMacs: [ConnectedMac] {
        queue.sync { authenticatedMacs() }
    }

    private func authenticatedMacs() -> [ConnectedMac] {
        peers.values.compactMap { $0.mac }.sorted { $0.since < $1.since }
    }

    private func makeListener(host: NWEndpoint.Host) throws -> NWListener {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.acceptLocalOnly = true
        params.requiredLocalEndpoint = .hostPort(host: host, port: NWEndpoint.Port(rawValue: port)!)
        let listener = try NWListener(using: params)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            guard self.peers.count < 8 else { connection.cancel(); return }   // a handful of Macs, not a flood
            let peer = Peer(server: self, connection: connection)
            self.peers[ObjectIdentifier(peer)] = peer
            peer.start(on: self.queue)
        }
        listener.start(queue: queue)
        return listener
    }

    fileprivate func remove(_ peer: Peer) {
        peers[ObjectIdentifier(peer)] = nil
        onClientsChanged?(authenticatedMacs())
    }

    fileprivate func clientsChanged() {
        onClientsChanged?(authenticatedMacs())
    }

    // MARK: Message handling

    fileprivate func handle(_ message: ControlEnvelope, from peer: Peer) -> [ControlEnvelope] {
        switch message.t {
        case ControlEnvelope.hello:
            guard peer.hello == nil else { return [] }
            let version = message.protocolVersion ?? 0
            guard version == PassthroughProtocol.version else {
                ptLog(.warning, version < PassthroughProtocol.version
                      ? "A Mac with an older Passthrough tried to connect: update Passthrough on the Mac"
                      : "A Mac with a newer Passthrough tried to connect: update Passthrough on this phone")
                // Our version tells the Mac which side to update.
                var e = Self.error(.unsupportedVersion)
                e.protocolVersion = PassthroughProtocol.version
                peer.reject()
                return [e]
            }
            guard let id = message.clientID, !id.isEmpty, id.utf8.count <= 64,
                  let macNonce = ControlAuth.decodeNonce(message.nonce) else {
                peer.reject()
                return [Self.error(.notAuthenticated)]
            }
            peer.via = message.via
            let phoneNonce = ControlAuth.nonce()
            peer.hello = Hello(clientID: id, name: String((message.name ?? "Mac").prefix(64)), macNonce: macNonce, phoneNonce: phoneNonce)
            var reply = welcome()
            reply.nonce = phoneNonce.base64EncodedString()
            // Proving first gives nothing away: the proof is bound to the
            // Mac's fresh nonce and only says something to whoever holds K.
            if let key = registry.pairingKey(clientID: id) {
                reply.paired = true
                reply.proof = ControlAuth.phoneProof(key: key, clientID: id, macNonce: macNonce, phoneNonce: phoneNonce).base64EncodedString()
            } else {
                reply.paired = false
            }
            return [reply]
        case ControlEnvelope.auth:
            guard peer.mac == nil else { return [] }
            guard let hello = peer.hello, let key = registry.pairingKey(clientID: hello.clientID),
                  ControlAuth.isValidMacProof(message.proof, key: key, clientID: hello.clientID, macNonce: hello.macNonce, phoneNonce: hello.phoneNonce) else {
                ptLog(.warning, "A Mac could not prove its pairing; closing its control connection")
                peer.reject()
                return [Self.error(.notAuthenticated)]
            }
            registry.touch(clientID: hello.clientID)
            peer.authenticate(id: hello.clientID, name: hello.name)
            return []
        case ControlEnvelope.pair:
            // After hello, which checked the version and named the Mac being paired.
            guard let hello = peer.hello else { return [Self.error(.notAuthenticated)] }
            guard let code = message.code, message.clientID.map({ $0 == hello.clientID }) ?? true else { return [Self.error(.badCode)] }
            switch registry.pair(code: code, clientID: hello.clientID, name: hello.name) {
            case .success(let token):
                peer.authenticate(id: hello.clientID, name: hello.name)
                var reply = ControlEnvelope(t: ControlEnvelope.paired)
                reply.token = token
                reply.deviceName = statusProvider().deviceName
                reply.socksPort = Int(socksPort)
                return [reply, statusMessage()]
            case .failure(let failure):
                return [Self.error(failure)]
            }
        case ControlEnvelope.link:
            // Only a Mac that already proved its pairing may link.
            guard let mac = peer.mac, let cert = message.certSHA256, cert.count == 64,
                  let key = message.linkKey.flatMap({ Data(base64Encoded: $0) }), key.count == 32 else { return [] }
            // No reply if the key could not be stored: the Mac stays unlinked
            // and offers the link again next time.
            guard registry.link(clientID: mac.id, certificateSHA256: cert, linkKey: key) else {
                ptLog(.error, "Could not link \(mac.name) for the wireless link")
                return []
            }
            var reply = ControlEnvelope(t: ControlEnvelope.linked)
            reply.phoneID = registry.phoneID
            ptLog(.info, "Linked \(mac.name) for the wireless link")
            return [reply]
        case ControlEnvelope.shellGrant:
            // Only a Mac that already proved its pairing may be granted a shell.
            guard let mac = peer.mac, let cert = message.certSHA256, cert.utf8.count == 64,
                  cert.utf8.allSatisfy({ (0x30...0x39).contains($0) || (0x41...0x46).contains($0) || (0x61...0x66).contains($0) }),
                  let key = message.shellKey.flatMap({ Data(base64Encoded: $0) }), key.count == 32,
                  let port = message.shellPort.flatMap({ UInt16(exactly: $0) }), port > 0 else { return [] }
            // The iroh details are all or nothing; bad ones never cost the LAN grant.
            var iroh = (id: message.irohID, relay: message.irohRelay, token: message.relayToken)
            if !IrohInfo.areValid(id: iroh.id, relay: iroh.relay, token: iroh.token) {
                if iroh.id != nil || iroh.relay != nil || iroh.token != nil { ptLog(.info, "shell: ignoring invalid iroh info in grant") }
                iroh = (nil, nil, nil)
            }
            let grant = ShellGrant(certSHA256: cert.lowercased(), port: port, addresses: Array((message.addresses ?? []).prefix(IrohInfo.maxAddresses)),
                                   macName: String((message.macName ?? mac.name).prefix(64)),
                                   irohID: iroh.id, irohRelay: iroh.relay)
            guard registry.grantShell(clientID: mac.id, grant: grant, shellKey: key, relayToken: iroh.token) else {
                ptLog(.error, "Could not store the shell key from \(mac.name)")
                return []
            }
            var reply = ControlEnvelope(t: ControlEnvelope.shellGranted)
            reply.phoneID = registry.phoneID
            // Echo the grant's name so the Mac records the key this answer is for.
            reply.grantID = message.grantID.flatMap { $0.isEmpty || $0.utf8.count > ControlEnvelope.maxGrantIDLength ? nil : $0 }
            ptLog(.info, "Granted \(mac.name) a shell")
            return [reply]
        case ControlEnvelope.ping:
            return [ControlEnvelope(t: ControlEnvelope.pong)]
        default:
            return []
        }
    }

    private static func error(_ failure: PairingFailure) -> ControlEnvelope {
        var e = ControlEnvelope(t: ControlEnvelope.error)
        e.reason = failure.rawValue
        return e
    }

    /// Why `peer` should be closed now, if it should: it was rejected, has
    /// not proved a pairing in time, or (authenticated) has gone silent.
    fileprivate func closeReason(for peer: Peer, now: Date = Date()) -> String? {
        if peer.isRejected { return "was refused" }
        if peer.mac == nil {
            var deadline = peer.openedAt.addingTimeInterval(unauthenticatedTimeout)
            // A Mac waiting for its user to type the code shown may wait as long as the code lasts.
            if peer.hello != nil, let code = registry.activeCode { deadline = max(deadline, code.expiry) }
            return now > deadline ? "did not prove a pairing in time" : nil
        }
        // Over the air the Mac's pings stop while the link waits to resume.
        let limit = peer.via == "wireless" ? Mux.suspendTimeout + 30 : cableSilenceLimit
        return now.timeIntervalSince(peer.lastHeard) > limit ? "stopped answering" : nil
    }

    private func welcome() -> ControlEnvelope {
        let status = statusProvider()
        var reply = ControlEnvelope(t: ControlEnvelope.welcome)
        reply.protocolVersion = PassthroughProtocol.version
        reply.deviceName = status.deviceName
        reply.socksPort = Int(socksPort)
        reply.radio = status.radio
        reply.carrier = status.carrier
        reply.battery = status.battery
        reply.hosting = status.hosting
        reply.ipv6 = status.ipv6
        return reply
    }

    fileprivate func statusMessage() -> ControlEnvelope {
        let status = statusProvider()
        let snap = counter.snapshot()
        var m = ControlEnvelope(t: ControlEnvelope.status)
        m.deviceName = status.deviceName
        m.radio = status.radio
        m.carrier = status.carrier
        m.battery = status.battery
        m.hosting = status.hosting
        m.ipv6 = status.ipv6
        m.activeConnections = snap.active
        m.rxBytes = snap.rx
        m.txBytes = snap.tx
        m.timestamp = Date().timeIntervalSince1970
        return m
    }
}

/// What a Mac's hello said, and the nonce this connection's proofs use.
private struct Hello {
    let clientID: String
    let name: String
    let macNonce: Data
    let phoneNonce: Data
}

private final class Peer: @unchecked Sendable {
    private let server: ControlServer
    private let channel: ControlConnection
    private var timer: DispatchSourceTimer?
    private var cancelled = false
    /// Set once the Mac proved its pairing, or paired with the code.
    private(set) var mac: ConnectedMac?
    var hello: Hello?
    let openedAt = Date()
    private(set) var lastHeard = Date()
    /// Answered with an error: nothing it sends counts any more, and the next tick closes it.
    private(set) var isRejected = false
    /// What the Mac's hello said carries this connection ("usb" or "wireless").
    var via: String?

    init(server: ControlServer, connection: NWConnection) {
        self.server = server
        self.channel = ControlConnection(connection, queue: server.queue)
    }

    func start(on queue: DispatchQueue) {
        channel.onMessage = { [weak self] message in
            guard let self, !self.isRejected else { return }
            self.lastHeard = Date()
            self.channel.send(self.server.handle(message, from: self))
        }
        channel.onClose = { [weak self] _ in self?.cancel() }
        channel.start(queue: queue)
        // Every second: close it if it should go, else status once authenticated.
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            if let reason = self.server.closeReason(for: self) {
                ptLog(.info, "Closing a control connection that \(reason)")
                self.cancel()
                return
            }
            guard self.mac != nil else { return }
            self.channel.send(self.server.statusMessage())
        }
        timer.resume()
        self.timer = timer
    }

    func authenticate(id: String, name: String) {
        if mac == nil {
            mac = ConnectedMac(id: id, name: name, since: Date(), wireless: via.map { $0 == "wireless" })
            ptLog(.info, "\(name) connected")
            server.clientsChanged()
        }
    }

    /// Closed at the next tick rather than now, so the error just sent gets out first.
    func reject() { isRejected = true }

    func cancel() {
        guard !cancelled else { return }
        cancelled = true
        timer?.cancel()
        channel.cancel()
        if let mac { ptLog(.info, "\(mac.name) disconnected") }
        server.remove(self)
    }
}
