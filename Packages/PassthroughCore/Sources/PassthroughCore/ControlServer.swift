import Foundation
import Network

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
    public init(id: String, name: String, since: Date) { self.id = id; self.name = name; self.since = since }
}

/// Newline-delimited JSON control channel: pairing, heartbeat, live status.
public final class ControlServer: @unchecked Sendable {
    public let port: UInt16
    private let registry: PairingRegistry
    private let counter: ByteCounter
    private let statusProvider: @Sendable () -> DeviceStatus
    private let socksPort: UInt16
    fileprivate let queue = DispatchQueue(label: "dev.dpatel.passthrough.control")
    private var listeners: [NWListener] = []
    private var peers: [ObjectIdentifier: Peer] = [:]
    public private(set) var isRunning = false
    public var onClientsChanged: (@Sendable ([ConnectedMac]) -> Void)?
    /// A Mac was just linked for the wireless link, on the control queue.
    public var onLinked: (@Sendable () -> Void)?

    public init(port: UInt16 = PassthroughProtocol.defaultControlPort,
                socksPort: UInt16,
                registry: PairingRegistry,
                counter: ByteCounter,
                statusProvider: @escaping @Sendable () -> DeviceStatus) {
        self.port = port
        self.socksPort = socksPort
        self.registry = registry
        self.counter = counter
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
            guard (message.protocolVersion ?? 0) == PassthroughProtocol.version else {
                var e = ControlEnvelope(t: ControlEnvelope.error); e.reason = PairingFailure.unsupportedVersion.rawValue
                return [e]
            }
            var paired = false
            if let id = message.clientID, let token = message.token, registry.verify(clientID: id, token: token) {
                paired = true
                registry.touch(clientID: id)
                peer.authenticate(id: id, name: message.name ?? "Mac")
            }
            var reply = welcome()
            reply.paired = paired
            return [reply]
        case ControlEnvelope.pair:
            guard let id = message.clientID, let code = message.code else {
                var e = ControlEnvelope(t: ControlEnvelope.error); e.reason = PairingFailure.badCode.rawValue
                return [e]
            }
            switch registry.pair(code: code, clientID: id, name: message.name ?? "Mac") {
            case .success(let token):
                peer.authenticate(id: id, name: message.name ?? "Mac")
                var reply = ControlEnvelope(t: ControlEnvelope.paired)
                reply.token = token
                reply.deviceName = statusProvider().deviceName
                reply.socksPort = Int(socksPort)
                return [reply, statusMessage()]
            case .failure(let failure):
                var e = ControlEnvelope(t: ControlEnvelope.error); e.reason = failure.rawValue
                return [e]
            }
        case ControlEnvelope.link:
            // Only a Mac that already proved its pairing token may link.
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
            onLinked?()
            return [reply]
        case ControlEnvelope.ping:
            return [ControlEnvelope(t: ControlEnvelope.pong)]
        default:
            return []
        }
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

private final class Peer: @unchecked Sendable {
    private let server: ControlServer
    private let channel: ControlConnection
    private var timer: DispatchSourceTimer?
    private var cancelled = false
    private(set) var mac: ConnectedMac?

    init(server: ControlServer, connection: NWConnection) {
        self.server = server
        self.channel = ControlConnection(connection, queue: server.queue)
    }

    func start(on queue: DispatchQueue) {
        channel.onMessage = { [weak self] message in
            guard let self else { return }
            self.channel.send(self.server.handle(message, from: self))
        }
        channel.onClose = { [weak self] _ in self?.cancel() }
        channel.start(queue: queue)
        // Status broadcast once authenticated.
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in
            guard let self, self.mac != nil else { return }
            self.channel.send(self.server.statusMessage())
        }
        timer.resume()
        self.timer = timer
    }

    func authenticate(id: String, name: String) {
        if mac == nil {
            mac = ConnectedMac(id: id, name: name, since: Date())
            ptLog(.info, "\(name) connected")
            server.clientsChanged()
        }
    }

    func cancel() {
        guard !cancelled else { return }
        cancelled = true
        timer?.cancel()
        channel.cancel()
        if let mac { ptLog(.info, "\(mac.name) disconnected") }
        server.remove(self)
    }
}
