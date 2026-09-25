import Foundation
import Network
import PassthroughCore

/// The Mac's side of the wireless link: a TLS 1.3 listener advertised over
/// peer-to-peer Wi-Fi (and whatever network the Mac is on, which is how an
/// Android phone's Wi-Fi Direct group reaches it). Each connection must answer
/// a challenge with a linked phone's key before it becomes a link.
public final class WirelessListener: @unchecked Sendable {
    public struct Link {
        public let phoneID: String
        public let mux: Mux
    }

    private let identity: MacIdentity
    private let macTag: String
    private let advertise: Bool
    private let linkKey: @Sendable (String) -> Data?
    private let queue = DispatchQueue(label: "dev.dpatel.passthrough.wireless-listener")
    private var listener: NWListener?
    private var pending = 0
    /// A phone proved itself; on the listener's queue.
    public var onLink: (@Sendable (Link) -> Void)?
    /// The TCP port once listening (tests).
    public private(set) var port: UInt16?

    /// `linkKey` returns the key shared with the phone of that ID, if linked.
    /// `advertise` is false in tests (no Bonjour).
    public init(identity: MacIdentity, macTag: String, advertise: Bool = true, linkKey: @escaping @Sendable (String) -> Data?) {
        self.identity = identity
        self.macTag = macTag
        self.advertise = advertise
        self.linkKey = linkKey
    }

    public func start(onReady: (@Sendable (UInt16) -> Void)? = nil) throws {
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv13)
        guard let secIdentity = sec_identity_create(identity.identity) else {
            throw MuxError.protocolViolation("could not use the Mac's identity")
        }
        sec_protocol_options_set_local_identity(tls.securityProtocolOptions, secIdentity)
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 10
        let params = NWParameters(tls: tls, tcp: tcp)
        params.includePeerToPeer = true
        let listener = try NWListener(using: params)
        if advertise {
            let txt = NWTXTRecord(["m": macTag])
            listener.service = NWListener.Service(name: macTag, type: WirelessLink.serviceType, txtRecord: txt)
        }
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            switch state {
            case .ready:
                let port = listener?.port?.rawValue
                self?.port = port
                if let port { onReady?(port) }
                ptLog(.info, "wireless: listening on port \(port ?? 0)")
            case .failed(let error):
                ptLog(.error, "wireless: listener failed: \(error)")
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.start(queue: queue)
        self.listener = listener
    }

    public func stop() {
        queue.async { [self] in listener?.cancel(); listener = nil }
    }

    private func accept(_ connection: NWConnection) {
        // A handful of phones handshaking at once, not a flood from a stranger.
        guard pending < 8 else { connection.cancel(); return }
        pending += 1
        let stream = ConnectionStream(connection, queue: queue)
        let nonce = WirelessLink.randomBytes(32)
        var done = false
        let finish: (Link?) -> Void = { [weak self] link in
            guard !done, let self else { return }
            done = true
            self.pending -= 1
            if let link { self.onLink?(link) } else { stream.cancel() }
        }
        queue.asyncAfter(deadline: .now() + WirelessLink.handshakeTimeout) { finish(nil) }
        WirelessLink.sendLine(.init(t: "challenge", nonce: nonce.base64EncodedString()), on: stream)
        WirelessLink.readLine(stream) { [weak self] result in
            guard let self else { return }
            self.queue.async {
                guard case .success(let (line, rest)) = result,
                      let message = try? JSONDecoder().decode(WirelessLink.Handshake.self, from: line),
                      message.t == "proof", let phoneID = message.phoneID,
                      let proof = message.mac.flatMap({ Data(base64Encoded: $0) }),
                      let key = self.linkKey(phoneID),
                      WirelessLink.proofIsValid(proof, linkKey: key, nonce: nonce) else {
                    ptLog(.warning, "wireless: rejected a connection that could not prove a link")
                    finish(nil); return
                }
                let mux = Mux(transport: stream, isOpener: true,
                              queue: DispatchQueue(label: "dev.dpatel.passthrough.wireless-mux"), initialBytes: rest)
                finish(Link(phoneID: phoneID, mux: mux))
            }
        }
    }
}

/// A phone reached over the wireless link: each stream is one mux stream.
public struct MuxLink: PhoneLink {
    public let mux: Mux
    public init(mux: Mux) { self.mux = mux }
    public func connect(port: UInt16, queue: DispatchQueue, completion: @escaping @Sendable (Result<ByteStream, Error>) -> Void) {
        completion(.success(mux.open(port: port)))
    }
}
