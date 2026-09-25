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

    /// What carries a link, from the interface its connection uses: short
    /// names for the flow maps and menus.
    public static func carrier(interface: String?, onPhoneHotspot: Bool = false) -> String {
        guard let name = interface else { return "Wireless" }
        if name.hasPrefix("awdl") || name.hasPrefix("llw") { return "Peer-to-peer" }
        // The network a USB-C cable brings up between the phone and the Mac.
        if name.hasPrefix("anpi") { return "USB" }
        if name.hasPrefix("bridge") || name.hasPrefix("ap") || onPhoneHotspot { return "Hotspot" }
        return "Wi-Fi network"
    }

    /// What carries a link's connection. Personal Hotspot is also recognised
    /// by its addresses (always 172.20.10.0/28), whatever iOS names the
    /// interface on its side.
    public static func carrier(of stream: ByteStream) -> String {
        let path = (stream as? ConnectionStream)?.connection.currentPath
        let hotspot = [path?.localEndpoint, path?.remoteEndpoint].contains { isHotspotAddress($0) }
        return carrier(interface: interfaceName(of: stream), onPhoneHotspot: hotspot)
    }

    public static func interfaceName(of stream: ByteStream) -> String? {
        (stream as? ConnectionStream)?.connection.currentPath?.availableInterfaces.first?.name
    }

    static func isHotspotAddress(_ endpoint: NWEndpoint?) -> Bool {
        guard case .hostPort(.ipv4(let address), _)? = endpoint else { return false }
        let b = [UInt8](address.rawValue)
        return b.count == 4 && b[0] == 172 && b[1] == 20 && b[2] == 10 && b[3] < 16
    }

    public static func fingerprint(_ certificate: Data) -> String {
        SHA256.hash(data: certificate).map { String(format: "%02x", $0) }.joined()
    }

    /// Handshake lines: challenge (Mac), proof (phone), then resume or fresh (Mac).
    public struct Handshake: Codable, Sendable {
        public var t: String
        public var nonce: String?
        public var phoneID: String?
        public var mac: String?
        /// The session the phone wants to continue (proof), or the new one (fresh).
        public var session: String?
        /// Stream positions of the side that sends the line (proof, resume).
        public var streams: [MuxStreamState]?
        public init(t: String, nonce: String? = nil, phoneID: String? = nil, mac: String? = nil, session: String? = nil, streams: [MuxStreamState]? = nil) {
            self.t = t; self.nonce = nonce; self.phoneID = phoneID; self.mac = mac; self.session = session; self.streams = streams
        }
    }

    /// Handshake lines carry every open stream's position when resuming:
    /// thousands of streams fit well within this.
    static let handshakeLineLimit = 1 << 20

    /// Reads one newline-terminated line; hands back any bytes after it.
    public static func readLine(_ stream: ByteStream, buffered: Data = Data(), completion: @escaping @Sendable (Result<(Data, Data), Error>) -> Void) {
        if let newline = buffered.firstIndex(of: 0x0A) {
            completion(.success((Data(buffered[..<newline]), Data(buffered[buffered.index(after: newline)...])))); return
        }
        guard buffered.count < handshakeLineLimit else { completion(.failure(MuxError.protocolViolation("handshake line too long"))); return }
        stream.receive(maximumLength: 65536) { data, complete, error in
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

/// The phone's side: finds linked Macs advertising on a network it shares
/// with them (its own Personal Hotspot, or peer-to-peer Wi-Fi when enabled),
/// dials each, proves who it is, and then serves the streams the Mac opens by
/// connecting them to its own proxy. When a link drops it redials and resumes
/// the same session, so the Mac's connections pause instead of failing.
public final class WirelessDialer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "dev.dpatel.passthrough.wireless-dialer")
    private let credentials: @Sendable () -> [LinkCredential]
    private let allowedPorts: Set<UInt16>
    private let peerToPeer: Bool
    private var browser: NWBrowser?
    private var results: Set<NWBrowser.Result> = []
    private var links: [String: MacLink] = [:]   // by macTag
    private var running = false

    /// `allowedPorts`: the only loopback ports the Mac may open streams to.
    /// Without `peerToPeer` the Mac is found only on a network both share,
    /// typically this iPhone's Personal Hotspot.
    public init(allowedPorts: Set<UInt16>, peerToPeer: Bool = false, credentials: @escaping @Sendable () -> [LinkCredential]) {
        self.allowedPorts = allowedPorts
        self.peerToPeer = peerToPeer
        self.credentials = credentials
    }

    /// Macs whose link is up right now.
    public var connectedMacTags: [String] { queue.sync { links.filter { $0.value.isUp }.map(\.key) } }
    /// What carries each link that is up ("Hotspot", "Peer-to-peer", …), by Mac tag.
    public var carriers: [String: String] { queue.sync { links.filter { $0.value.isUp }.compactMapValues(\.carrier) } }

    public func start() {
        queue.async { [self] in
            guard !running else { return }
            running = true
            let params = NWParameters.tcp
            params.includePeerToPeer = peerToPeer
            let browser = NWBrowser(for: .bonjourWithTXTRecord(type: WirelessLink.serviceType, domain: nil), using: params)
            browser.stateUpdateHandler = { state in
                switch state {
                case .failed(let e): ptLog(.warning, "wireless: browsing failed: \(e)")
                case .waiting(let e): ptLog(.warning, "wireless: browsing is waiting: \(e)")
                default: break
                }
            }
            browser.browseResultsChangedHandler = { [weak self] results, _ in self?.queue.async { self?.found(results) } }
            browser.start(queue: queue)
            self.browser = browser
            ptLog(.info, "wireless: looking for linked Macs \(peerToPeer ? "nearby and on shared networks" : "on shared networks (Personal Hotspot)")")
        }
    }

    public func stop() {
        queue.async { [self] in
            running = false
            browser?.cancel(); browser = nil
            results = []
            links.values.forEach { $0.stop() }
            links.removeAll()
        }
    }

    /// Looks at the Macs in view again: call when a Mac was just linked, since
    /// one already advertising produces no new browse results.
    public func refresh() {
        queue.async { [self] in found(results) }
    }

    /// Dials `endpoint` directly (tests, and hosts found without Bonjour).
    public func dial(_ endpoint: NWEndpoint, credential: LinkCredential, peerToPeer: Bool = true) {
        queue.async { [self] in link(for: credential.macTag, peerToPeer: peerToPeer) { credential }.reach(endpoint) }
    }

    private func found(_ results: Set<NWBrowser.Result>) {
        guard running else { return }
        self.results = results
        let known = Set(credentials().map(\.macTag))
        var inView: Set<String> = []
        for result in results {
            guard case .bonjour(let txt) = result.metadata, let tag = txt["m"], known.contains(tag) else { continue }
            inView.insert(tag)
            link(for: tag, peerToPeer: peerToPeer) { [weak self] in self?.credential(for: tag) }.reach(result.endpoint)
        }
        for (tag, link) in links where !inView.contains(tag) { link.outOfView() }
    }

    /// The credential stored for `tag` now: a relinked Mac has a new key, a
    /// forgotten one has none.
    private func credential(for tag: String) -> LinkCredential? {
        credentials().first { $0.macTag == tag }
    }

    private func link(for tag: String, peerToPeer: Bool, credential: @escaping () -> LinkCredential?) -> MacLink {
        if let existing = links[tag], !existing.isStopped { return existing }   // a stopped one was forgotten
        let link = MacLink(tag: tag, credential: credential, peerToPeer: peerToPeer, allowedPorts: allowedPorts, queue: queue)
        links[tag] = link
        return link
    }
}

/// The phone's link to one Mac: one multiplexed session, carried by whichever
/// connection currently works. Everything runs on `queue`.
private final class MacLink: @unchecked Sendable {
    private let macTag: String
    private let credential: () -> LinkCredential?
    private let peerToPeer: Bool
    private let allowedPorts: Set<UInt16>
    private let queue: DispatchQueue
    private var endpoint: NWEndpoint?
    /// Advertising right now; a Mac out of view is redialed only to resume.
    private var inView = true
    private var mux: Mux?
    private var attempt: ConnectionStream?
    private var attemptID = 0
    private var failures = 0
    private var redial: DispatchWorkItem?
    private var stopped = false
    private var splices: [ObjectIdentifier: Splice] = [:]
    private(set) var isUp = false
    private(set) var carrier: String?
    var isStopped: Bool { stopped }

    init(tag: String, credential: @escaping () -> LinkCredential?, peerToPeer: Bool, allowedPorts: Set<UInt16>, queue: DispatchQueue) {
        self.macTag = tag
        self.credential = credential
        self.peerToPeer = peerToPeer
        self.allowedPorts = allowedPorts
        self.queue = queue
    }

    private var tag: String { String(macTag.prefix(6)) }

    /// The Mac is (still) at `endpoint`: connect unless already up or trying.
    func reach(_ endpoint: NWEndpoint) {
        self.endpoint = endpoint
        inView = true
        guard !stopped, !isUp, attempt == nil, redial == nil else { return }
        dial()
    }

    /// The Mac stopped advertising. Keep trying only while a session waits to
    /// resume; otherwise wait until it is seen again.
    func outOfView() {
        inView = false
        guard mux == nil else { return }
        redial?.cancel(); redial = nil
    }

    func stop() {
        stopped = true
        redial?.cancel(); redial = nil
        attempt?.cancel(); attempt = nil
        mux?.close(); mux = nil
        splices.values.forEach { $0.close() }
        splices.removeAll()
    }

    private func dial() {
        redial = nil
        guard !stopped, let endpoint else { return }
        guard let credential = credential() else {
            ptLog(.info, "wireless: Mac \(tag) is no longer linked")
            stop()
            return
        }
        attemptID += 1
        let id = attemptID
        let connection = NWConnection(to: endpoint, using: WirelessLink.pinnedClientParameters(pin: credential.certSHA256, peerToPeer: peerToPeer))
        let stream = ConnectionStream(connection, queue: queue)
        attempt = stream
        stream.onTerminated = { [weak self] error in self?.queue.async { self?.attemptFailed(id, error) } }
        queue.asyncAfter(deadline: .now() + WirelessLink.handshakeTimeout) { [weak self] in
            self?.attemptFailed(id, MuxError.protocolViolation("handshake timed out"))
        }
        WirelessLink.readLine(stream) { [weak self] result in self?.queue.async { self?.challenged(id, stream, credential, result) } }
    }

    private func challenged(_ id: Int, _ stream: ConnectionStream, _ credential: LinkCredential, _ result: Result<(Data, Data), Error>) {
        guard id == attemptID, attempt === stream else { return }
        guard case .success(let (line, _)) = result else { attemptFailed(id, result.failure); return }
        guard let message = try? JSONDecoder().decode(WirelessLink.Handshake.self, from: line),
              message.t == "challenge", let nonce = message.nonce.flatMap({ Data(base64Encoded: $0) }), nonce.count == 32 else {
            attemptFailed(id, MuxError.protocolViolation("bad challenge")); return
        }
        let proof = WirelessLink.proof(linkKey: credential.linkKey, nonce: nonce).base64EncodedString()
        let send = { [self] (states: [MuxStreamState]?) in
            WirelessLink.sendLine(.init(t: "proof", phoneID: credential.phoneID, mac: proof, session: mux?.sessionID, streams: states), on: stream)
            WirelessLink.readLine(stream) { [weak self] result in self?.queue.async { self?.answered(id, stream, result) } }
        }
        if let mux { mux.streamStates { states in self.queue.async { send(states) } } } else { send(nil) }
    }

    private func answered(_ id: Int, _ stream: ConnectionStream, _ result: Result<(Data, Data), Error>) {
        guard id == attemptID, attempt === stream else { return }
        guard case .success(let (line, rest)) = result,
              let message = try? JSONDecoder().decode(WirelessLink.Handshake.self, from: line) else {
            attemptFailed(id, result.failure ?? MuxError.protocolViolation("bad handshake reply")); return
        }
        // Check the reply before taking the connection: a failure must still
        // find the attempt, or no redial is scheduled. ("resume" with no mux:
        // ours expired while the Mac answered.)
        let resume = message.t == "resume" ? mux : nil
        let freshSession = message.t == "fresh" ? message.session : nil
        guard resume != nil || freshSession != nil else {
            attemptFailed(id, MuxError.protocolViolation("unexpected handshake reply \(message.t)")); return
        }
        stream.onTerminated = nil
        attempt = nil
        failures = 0
        carrier = WirelessLink.carrier(of: stream)
        let local = stream.connection.currentPath?.localEndpoint.map { "\($0)" } ?? "?"
        let via = "\(WirelessLink.interfaceName(of: stream) ?? "?"), \(local)"
        if let resume {
            resume.resume(on: stream, peerStreams: message.streams ?? [], initialBytes: rest)
        } else if let freshSession {
            // The Mac didn't know our session (it restarted): start over.
            mux?.close()
            let mux = Mux(transport: stream, isOpener: false, queue: queue, initialBytes: rest, sessionID: freshSession, resumable: true)
            mux.onOpen = { [weak self] port, muxStream in self?.serve(port: port, muxStream) }
            mux.onSuspend = { [weak self] _ in self?.suspended() }
            mux.onClose = { [weak self, weak mux] error in
                guard let self, self.mux === mux else { return }
                self.mux = nil
                self.isUp = false
                ptLog(.info, "wireless: link to Mac \(self.tag) ended: \(error?.localizedDescription ?? "closed")")
                self.scheduleRedial()
            }
            self.mux = mux
            mux.start()
        }
        isUp = true
        ptLog(.info, "wireless: linked with Mac \(tag) over \(carrier ?? "?") (\(via))")
    }

    private func suspended() {
        isUp = false
        scheduleRedial(immediately: true)
    }

    private func attemptFailed(_ id: Int, _ error: Error?) {
        guard id == attemptID, let stream = attempt else { return }
        stream.onTerminated = nil
        stream.cancel()
        attempt = nil
        failures += 1
        if failures == 1 || failures % 10 == 0 {
            ptLog(.info, "wireless: couldn't reach Mac \(tag) (\(error?.localizedDescription ?? "no answer")); retrying")
        }
        scheduleRedial()
    }

    /// Right away after a drop, then backing off to 5 s. A Mac that is out of
    /// view is only redialed while a session waits to resume.
    private func scheduleRedial(immediately: Bool = false) {
        guard !stopped, redial == nil, attempt == nil, inView || mux != nil else { return }
        let delay = immediately ? 0.2 : min(5, 0.5 * pow(2, Double(max(0, failures - 1))))
        let work = DispatchWorkItem { [weak self] in self?.dial() }
        redial = work
        queue.asyncAfter(deadline: .now() + delay, execute: work)
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
        splices[key!] = splice
        splice.start()
    }
}

private extension Result {
    var failure: Failure? { if case .failure(let e) = self { return e } else { return nil } }
}
