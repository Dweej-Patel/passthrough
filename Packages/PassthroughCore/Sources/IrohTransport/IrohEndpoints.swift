import Foundation
import IrohLib

public enum IrohShell {
    /// The remote shell's ALPN on iroh connections.
    public static let alpn = "passthrough/shell/1"
}

/// Which relays an endpoint uses. The Mac is the only source of this.
public struct IrohRelayConfig: Codable, Equatable, Sendable {
    /// A custom relay's URL; nil means n0's public relays.
    public var url: String?
    /// Sent to a custom relay as `Authorization: Bearer`.
    public var token: String?

    public init(url: String? = nil, token: String? = nil) {
        self.url = url
        self.token = token
    }

    func relayMode() throws -> RelayMode {
        guard let url else { return RelayMode.defaultMode() }
        let map = RelayMap.empty()
        try map.insert(config: RelayConfig(url: url, authToken: token))
        return RelayMode.custom(map: map)
    }
}

/// Binds an endpoint with the minimal preset: no n0 DNS/pkarr publishing or
/// lookup and no mDNS; peers are dialled by id plus explicit addresses.
private func bindEndpoint(secretKey: Data?, alpns: [Data], relayMode: RelayMode) async throws -> Endpoint {
    try await Endpoint.bind(options: EndpointOptions(
        preset: presetMinimal(),
        secretKey: secretKey,
        alpns: alpns,
        relayMode: relayMode
    ))
}

/// Loopback forms of an endpoint's bound sockets ("0.0.0.0:p" → "127.0.0.1:p").
private func loopback(_ sockets: [String]) -> [String] {
    sockets.compactMap { socket in
        guard let colon = socket.lastIndex(of: ":") else { return nil }
        let port = socket[socket.index(after: colon)...]
        return socket.hasPrefix("[") ? "[::1]:\(port)" : "127.0.0.1:\(port)"
    }
}

/// The Mac's endpoint: a stable id from a stored secret key, accepting the
/// phones' connections.
public final class IrohEndpointHost: @unchecked Sendable {
    let endpoint: Endpoint
    private let lock = NSLock()
    private var alpns: [Data]

    /// A fresh 32-byte endpoint secret key, for the Mac to store.
    public static func newSecretKey() -> Data {
        SecretKey.generate().toBytes()
    }

    public convenience init(secretKey: Data, relay: IrohRelayConfig) async throws {
        try await self.init(secretKey: secretKey, relayMode: relay.relayMode())
    }

    /// Relays off entirely (tests) or n0's defaults.
    convenience init(secretKey: Data, relayEnabled: Bool) async throws {
        try await self.init(secretKey: secretKey, relayMode: relayEnabled ? RelayMode.defaultMode() : RelayMode.disabled())
    }

    init(secretKey: Data, relayMode: RelayMode) async throws {
        guard secretKey.count == 32 else { throw IrohTransportError.invalidSecretKey }
        alpns = [Data(IrohShell.alpn.utf8)]
        endpoint = try await bindEndpoint(secretKey: secretKey, alpns: alpns, relayMode: relayMode)
    }

    /// This endpoint's id (derived from the secret key).
    public var endpointID: String { endpoint.id().description }

    /// The relay this endpoint is currently reachable through, if any.
    public var homeRelay: String? { endpoint.addr().relayUrl() }

    /// The direct (IP:port) addresses iroh currently knows for this endpoint.
    public var directAddresses: [String] { endpoint.addr().directAddresses() }

    /// Loopback addresses of the bound sockets (same-machine dialling, tests).
    var loopbackAddresses: [String] { loopback(endpoint.boundSockets()) }

    /// Waits for the next incoming connection attempt. Returns before the
    /// handshake so one slow peer can't hold up the accept loop; finish it
    /// with `IrohIncoming.acceptStream()`. Run one accept loop per endpoint.
    public func accept(alpn: String) async throws -> IrohIncoming {
        let wanted = Data(alpn.utf8)
        lock.withLock {
            if !alpns.contains(wanted) {
                alpns.append(wanted)
                endpoint.setAlpns(alpns: alpns)
            }
        }
        guard let incoming = await endpoint.acceptNext() else { throw IrohTransportError.endpointClosed }
        return IrohIncoming(incoming: incoming, alpn: wanted)
    }

    public func shutdown() async {
        try? await endpoint.close()
    }
}

/// An incoming connection attempt, not yet handshaken.
public final class IrohIncoming: @unchecked Sendable {
    private let incoming: Incoming
    private let alpn: Data
    private let lock = NSLock()
    private enum State { case waiting, accepting, connected(Connection), cancelled }
    private var state = State.waiting

    init(incoming: Incoming, alpn: Data) {
        self.incoming = incoming
        self.alpn = alpn
    }

    /// Where the attempt comes from, before any handshake: the path and,
    /// for direct paths, the peer's IP.
    public func origin() async -> (path: IrohPath, ip: String?) {
        switch try? await incoming.remoteAddr() {
        case .ip(let addr): return (.direct, IrohPaths.host(ofSocketAddress: addr))
        case .relay: return (.relay, nil)
        default: return (.unknown, nil)
        }
    }

    /// Whether the peer has shown it receives packets at the address it
    /// came from (QUIC address validation: it echoed a retry token).
    public func isAddressValidated() async -> Bool {
        (try? await incoming.remoteAddrValidated()) ?? false
    }

    /// Ends this attempt with a QUIC retry, keeping no state: a peer that
    /// really is at its address comes again with a token, and that attempt
    /// is validated. False if it cannot be asked (it already came with one).
    public func retry() async -> Bool {
        do { try await incoming.retry(); return true } catch { return false }
    }

    /// Turns the attempt away without a handshake.
    public func refuse() async {
        try? await incoming.refuse()
    }

    /// Completes the handshake and waits for the peer's first bidirectional
    /// stream (which arrives once the peer has written to it).
    public func acceptStream() async throws -> IrohByteStream {
        let start: Bool = lock.withLock {
            guard case .waiting = state else { return false }
            state = .accepting
            return true
        }
        guard start else { throw IrohTransportError.cancelled }
        let connection = try await incoming.accept().connect()
        let cancelled: Bool = lock.withLock {
            if case .cancelled = state { return true }
            state = .connected(connection)
            return false
        }
        do {
            if cancelled { throw IrohTransportError.cancelled }
            guard connection.alpn() == alpn else { throw IrohTransportError.wrongALPN }
            let stream = try await connection.acceptBi()
            return IrohByteStream(connection: connection, stream: stream)
        } catch {
            try? connection.close(errorCode: 0, reason: Data())
            throw error
        }
    }

    /// Abandons the attempt: refuses it if `acceptStream()` hasn't started,
    /// closes the connection if the handshake is done (a pending
    /// `acceptStream()` then fails), and otherwise fails `acceptStream()` as
    /// soon as its handshake ends.
    public func cancel() {
        let previous: State = lock.withLock {
            defer { state = .cancelled }
            return state
        }
        switch previous {
        case .waiting: Task { [incoming] in try? await incoming.refuse() }
        case .connected(let connection): try? connection.close(errorCode: 0, reason: Data())
        case .accepting, .cancelled: break
        }
    }
}

/// The phone's endpoint: an ephemeral key per connection attempt, dialling the Mac.
public final class IrohDialer: @unchecked Sendable {
    let endpoint: Endpoint

    public convenience init(relay: IrohRelayConfig) async throws {
        try await self.init(relayMode: relay.relayMode())
    }

    /// Relays off entirely (tests) or n0's defaults.
    convenience init(relayEnabled: Bool) async throws {
        try await self.init(relayMode: relayEnabled ? RelayMode.defaultMode() : RelayMode.disabled())
    }

    init(relayMode: RelayMode) async throws {
        endpoint = try await bindEndpoint(secretKey: nil, alpns: [], relayMode: relayMode)
    }

    /// Connects to endpoint `id` at `relayURL` and/or `addresses` ("ip:port")
    /// and opens a bidirectional stream. The peer sees the stream once this
    /// side writes to it.
    public func connect(to id: String, relayURL: String?, addresses: [String], alpn: String) async throws -> IrohByteStream {
        let address = EndpointAddr(id: try EndpointId.fromString(s: id), relayUrl: relayURL, addresses: addresses)
        let connection = try await endpoint.connect(addr: address, alpn: Data(alpn.utf8))
        do {
            return IrohByteStream(connection: connection, stream: try await connection.openBi())
        } catch {
            try? connection.close(errorCode: 0, reason: Data())
            throw error
        }
    }

    public func shutdown() async {
        try? await endpoint.close()
    }
}
