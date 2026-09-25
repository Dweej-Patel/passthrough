import Foundation
import Network
import CryptoKit
import Security

/// Shared pieces of the wireless link (protocol/README.md, "Wireless link").
public enum WirelessLink {
    public static let serviceType = "_passthrough._tcp"
    static let proofLabel = Data("passthrough-link-v1".utf8)
    public static let handshakeTimeout: TimeInterval = 10

    /// What a Mac advertises instead of anything personal: the first 16 hex
    /// digits of SHA-256(its clientID).
    public static func macTag(clientID: String) -> String {
        String(SHA256.hash(data: Data(clientID.utf8)).map { String(format: "%02x", $0) }.joined().prefix(16))
    }

    /// HMAC-SHA256(linkKey, label ‖ nonce): the phone's answer to the Mac's challenge.
    public static func proof(linkKey: Data, nonce: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: proofLabel + nonce, using: SymmetricKey(data: linkKey)))
    }

    public static func proofIsValid(_ proof: Data, linkKey: Data, nonce: Data) -> Bool {
        HMAC<SHA256>.isValidAuthenticationCode(proof, authenticating: proofLabel + nonce, using: SymmetricKey(data: linkKey))
    }

    public static func randomBytes(_ count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return Data(bytes)
    }

    /// TLS 1.3 client that accepts exactly the certificate whose SHA-256 is `pin`.
    public static func pinnedClientParameters(pin: String, peerToPeer: Bool) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let options = tls.securityProtocolOptions
        sec_protocol_options_set_min_tls_protocol_version(options, .TLSv13)
        sec_protocol_options_set_verify_block(options, { _, trust, complete in
            let chain = SecTrustCopyCertificateChain(sec_trust_copy_ref(trust).takeRetainedValue()) as? [SecCertificate]
            let leaf = chain?.first.map { SecCertificateCopyData($0) as Data }
            complete(leaf.map { fingerprint($0) == pin } ?? false)
        }, DispatchQueue.global(qos: .userInitiated))
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 10
        let params = NWParameters(tls: tls, tcp: tcp)
        params.includePeerToPeer = peerToPeer
        return params
    }

    public static func fingerprint(_ certificate: Data) -> String {
        SHA256.hash(data: certificate).map { String(format: "%02x", $0) }.joined()
    }

    public struct Handshake: Codable, Sendable {
        public var t: String
        public var nonce: String?
        public var phoneID: String?
        public var mac: String?
        public init(t: String, nonce: String? = nil, phoneID: String? = nil, mac: String? = nil) {
            self.t = t; self.nonce = nonce; self.phoneID = phoneID; self.mac = mac
        }
    }

    /// Reads one newline-terminated line (≤ 4 KB); hands back any bytes after it.
    public static func readLine(_ stream: ByteStream, buffered: Data = Data(), completion: @escaping @Sendable (Result<(Data, Data), Error>) -> Void) {
        if let newline = buffered.firstIndex(of: 0x0A) {
            completion(.success((Data(buffered[..<newline]), Data(buffered[buffered.index(after: newline)...])))); return
        }
        guard buffered.count < 4096 else { completion(.failure(MuxError.protocolViolation("handshake line too long"))); return }
        stream.receive(maximumLength: 4096) { data, complete, error in
            if let error { completion(.failure(error)); return }
            guard let data, !data.isEmpty else { completion(.failure(complete ? MuxError.linkClosed : MuxError.badFrame)); return }
            readLine(stream, buffered: buffered + data, completion: completion)
        }
    }

    public static func sendLine(_ message: Handshake, on stream: ByteStream) {
        guard var data = try? JSONEncoder().encode(message) else { return }
        data.append(0x0A)
        stream.send(data, isComplete: false) { _ in }
    }
}

/// What a phone keeps for each Mac it linked with over the cable.
public struct LinkCredential: Codable, Equatable, Sendable {
    /// `WirelessLink.macTag(clientID:)` of the Mac.
    public var macTag: String
    public var certSHA256: String
    public var linkKey: Data
    public var phoneID: String
    public init(macTag: String, certSHA256: String, linkKey: Data, phoneID: String) {
        self.macTag = macTag; self.certSHA256 = certSHA256; self.linkKey = linkKey; self.phoneID = phoneID
    }
}

/// The phone's side: finds linked Macs advertising over peer-to-peer Wi-Fi
/// (or the network the phone hosts), dials each, proves who it is, and then
/// serves the streams the Mac opens by connecting them to its own proxy.
public final class WirelessDialer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "dev.dpatel.passthrough.wireless-dialer")
    private let credentials: @Sendable () -> [LinkCredential]
    private let allowedPorts: Set<UInt16>
    private var browser: NWBrowser?
    private var sessions: [String: Session] = [:]   // by macTag
    private var retryAt: [String: Date] = [:]
    private var running = false
    /// Fires on the dialer's queue when a Mac connects or drops.
    public var onChange: (@Sendable (_ connectedMacTags: [String]) -> Void)?

    /// `allowedPorts`: the only loopback ports the Mac may open streams to.
    public init(allowedPorts: Set<UInt16>, credentials: @escaping @Sendable () -> [LinkCredential]) {
        self.allowedPorts = allowedPorts
        self.credentials = credentials
    }

    public func start() {
        queue.async { [self] in
            guard !running else { return }
            running = true
            let params = NWParameters.tcp
            params.includePeerToPeer = true
            let browser = NWBrowser(for: .bonjourWithTXTRecord(type: WirelessLink.serviceType, domain: nil), using: params)
            browser.stateUpdateHandler = { state in
                if case .failed(let e) = state { ptLog(.warning, "wireless: browsing failed: \(e)") }
            }
            browser.browseResultsChangedHandler = { [weak self] results, _ in self?.queue.async { self?.found(results) } }
            browser.start(queue: queue)
            self.browser = browser
            ptLog(.info, "wireless: looking for linked Macs nearby")
        }
    }

    public func stop() {
        queue.async { [self] in
            running = false
            browser?.cancel(); browser = nil
            sessions.values.forEach { $0.close() }
            sessions.removeAll()
        }
    }

    /// Dials `endpoint` directly (tests, and hosts found without Bonjour).
    public func dial(_ endpoint: NWEndpoint, credential: LinkCredential, peerToPeer: Bool = true) {
        queue.async { [self] in connect(endpoint, credential: credential, peerToPeer: peerToPeer) }
    }

    private func found(_ results: Set<NWBrowser.Result>) {
        guard running else { return }
        let known = Dictionary(credentials().map { ($0.macTag, $0) }, uniquingKeysWith: { a, _ in a })
        for result in results {
            guard case .bonjour(let txt) = result.metadata, let tag = txt["m"], let credential = known[tag],
                  sessions[tag] == nil, (retryAt[tag] ?? .distantPast) <= Date() else { continue }
            connect(result.endpoint, credential: credential, peerToPeer: true)
        }
    }

    private func connect(_ endpoint: NWEndpoint, credential: LinkCredential, peerToPeer: Bool) {
        let tag = credential.macTag
        let session = Session(endpoint: endpoint, credential: credential, peerToPeer: peerToPeer,
                              allowedPorts: allowedPorts, queue: queue) { [weak self] error in
            guard let self else { return }
            self.sessions[tag] = nil
            self.retryAt[tag] = Date().addingTimeInterval(3)
            ptLog(.info, "wireless: link to Mac \(tag.prefix(6)) ended: \(error?.localizedDescription ?? "closed")")
            self.onChange?(Array(self.sessions.keys))
            // Bonjour won't report the Mac again while it stays visible: retry ourselves.
            self.queue.asyncAfter(deadline: .now() + 3) { [weak self] in
                guard let self, self.running, self.sessions[tag] == nil else { return }
                self.connect(endpoint, credential: credential, peerToPeer: peerToPeer)
            }
        } onReady: { [weak self] in
            guard let self else { return }
            ptLog(.info, "wireless: linked with Mac \(tag.prefix(6))")
            self.onChange?(Array(self.sessions.keys))
        }
        sessions[tag] = session
        session.start()
    }

    /// One dialed connection to one Mac.
    private final class Session: @unchecked Sendable {
        private let connection: NWConnection
        private let stream: ConnectionStream
        private let credential: LinkCredential
        private let allowedPorts: Set<UInt16>
        private let queue: DispatchQueue
        private let onEnd: (Error?) -> Void
        private let onReady: () -> Void
        private var mux: Mux?
        private var splices: [ObjectIdentifier: Splice] = [:]
        private var ended = false

        init(endpoint: NWEndpoint, credential: LinkCredential, peerToPeer: Bool, allowedPorts: Set<UInt16>,
             queue: DispatchQueue, onEnd: @escaping (Error?) -> Void, onReady: @escaping () -> Void) {
            self.credential = credential
            self.allowedPorts = allowedPorts
            self.queue = queue
            self.onEnd = onEnd
            self.onReady = onReady
            connection = NWConnection(to: endpoint, using: WirelessLink.pinnedClientParameters(pin: credential.certSHA256, peerToPeer: peerToPeer))
            stream = ConnectionStream(connection, queue: queue)
        }

        func start() {
            stream.onTerminated = { [weak self] error in self?.queue.async { self?.end(error) } }
            queue.asyncAfter(deadline: .now() + WirelessLink.handshakeTimeout) { [weak self] in
                guard let self, self.mux == nil else { return }
                self.end(MuxError.protocolViolation("handshake timed out"))
            }
            WirelessLink.readLine(stream) { [weak self] result in
                self?.queue.async { self?.challenged(result) }
            }
        }

        private func challenged(_ result: Result<(Data, Data), Error>) {
            guard !ended else { return }
            guard case .success(let (line, _)) = result else { end(result.failure ?? MuxError.linkClosed); return }
            guard let message = try? JSONDecoder().decode(WirelessLink.Handshake.self, from: line),
                  message.t == "challenge", let nonce = message.nonce.flatMap({ Data(base64Encoded: $0) }), nonce.count == 32 else {
                end(MuxError.protocolViolation("bad challenge")); return
            }
            let proof = WirelessLink.proof(linkKey: credential.linkKey, nonce: nonce)
            WirelessLink.sendLine(.init(t: "proof", phoneID: credential.phoneID, mac: proof.base64EncodedString()), on: stream)
            let mux = Mux(transport: stream, isOpener: false, queue: queue)
            mux.onOpen = { [weak self] port, muxStream in self?.serve(port: port, muxStream) }
            mux.onClose = { [weak self] error in self?.end(error) }
            self.mux = mux
            mux.start()
            onReady()
        }

        /// A stream the Mac opened: connect it to our own proxy on loopback.
        private func serve(port: UInt16, _ muxStream: MuxStream) {
            guard allowedPorts.contains(port), let nwPort = NWEndpoint.Port(rawValue: port) else { muxStream.cancel(); return }
            let local = ConnectionStream(NWConnection(host: .ipv4(.loopback), port: nwPort, using: .tcp), queue: queue)
            var key: ObjectIdentifier?
            let splice = Splice(muxStream, local, queue: queue) { [weak self] in
                if let key { self?.splices[key] = nil }
            }
            key = ObjectIdentifier(splice)
            splices[ObjectIdentifier(splice)] = splice
            splice.start()
        }

        func close() { queue.async { self.end(nil) } }

        private func end(_ error: Error?) {
            guard !ended else { return }
            ended = true
            stream.onTerminated = nil
            mux?.close()
            stream.cancel()
            splices.values.forEach { $0.close() }
            splices.removeAll()
            onEnd(error)
        }
    }
}

private extension Result {
    var failure: Failure? { if case .failure(let e) = self { return e } else { return nil } }
}
