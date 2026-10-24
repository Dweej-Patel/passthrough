import Foundation
import Network
import PassthroughCore

/// Mac side of the control channel: says hello, proves the pairing (or
/// pairs), keeps a heartbeat, and relays the phone's live status.
///
/// Whatever answers on the phone's port may not be the phone: another
/// iPhone on the cable, or an app squatting the port on an Android phone.
/// So the token is never sent; the phone must prove it holds the pairing
/// first (`ControlAuth`), and only then does the Mac prove itself and hand
/// over anything (link and shell keys are refused before that).
public final class ControlClient: @unchecked Sendable {
    public struct Identity: Sendable {
        public var clientID: String
        public var name: String
        /// The pairing token the proofs are made with. Never sent.
        public var token: String?
        /// `token` is only a guess at this phone's pairing (the slot every
        /// iPhone once shared): a phone that can't prove it counts as
        /// unpaired. Otherwise a failed proof ends the connection.
        public var tokenIsGuess: Bool
        public init(clientID: String, name: String, token: String?, tokenIsGuess: Bool = false) {
            self.clientID = clientID; self.name = name; self.token = token; self.tokenIsGuess = tokenIsGuess
        }
    }

    public enum Event: Sendable {
        /// `paired`: the phone proved it holds this Mac's pairing, and the
        /// Mac has proved it back. False: pair first.
        case welcomed(paired: Bool, status: DeviceStatus, socksPort: UInt16)
        case paired(token: String)
        case pairingFailed(PairingFailure)
        case status(DeviceStatus, rx: Int64, tx: Int64, active: Int)
        /// The phone stored our wireless-link credentials. Android adds the
        /// Wi-Fi Direct network it hosts for us to join.
        case linked(phoneID: String, network: String?, passphrase: String?)
        /// The phone stored a shell grant. `grantID` echoes the grant it
        /// answers; nil from phones that predate it.
        case shellGranted(phoneID: String, grantID: String?)
        case disconnected(Error?)
    }

    /// Why the channel closed, when it was this side's decision.
    public enum ControlError: LocalizedError, Equatable {
        /// The phone said it was paired but could not prove it.
        case proofFailed(kind: String)
        /// The phone speaks another protocol version; `phoneIsOlder` says which side to update.
        case incompatible(kind: String, phoneIsOlder: Bool)

        public var errorDescription: String? {
            switch self {
            case .proofFailed(let kind):
                return "The \(kind) on the cable could not prove it is paired with this Mac. If it is yours, use Forget Pairing in Settings and pair again."
            case .incompatible(let kind, let phoneIsOlder):
                return phoneIsOlder ? "Passthrough on the \(kind) is out of date. Update it on the \(kind), then connect again."
                                    : "Passthrough on this Mac is out of date. Update it on this Mac, then connect again."
            }
        }
    }

    private let device: PhoneDevice
    private let port: UInt16
    private let identity: Identity
    private let queue = DispatchQueue(label: "\(PassthroughProtocol.identifier).control-client")
    private var channel: ControlConnection?
    private var heartbeat: DispatchSourceTimer?
    private var lastPong = Date()
    private var closed = false
    private let handler: @Sendable (Event) -> Void
    private let macNonce = ControlAuth.nonce()
    private var welcomed = false
    /// The phone proved the pairing (or paired here): link and shell keys may go out.
    private var authenticated = false
    /// A `pair` is out and unanswered: the one time a `paired` counts.
    private var pairing = false
    /// A code entered before the phone's welcome; sent once it arrives.
    private var pendingCode: String?

    /// Silence after which the phone counts as gone: short over the cable,
    /// longer than a wireless link's resume window over the air.
    private var silenceLimit: TimeInterval { device.medium == .wireless ? Mux.suspendTimeout + 30 : 20 }

    public init(device: PhoneDevice, port: UInt16 = PassthroughProtocol.defaultControlPort, identity: Identity, handler: @escaping @Sendable (Event) -> Void) {
        self.device = device
        self.port = port
        self.identity = identity
        self.handler = handler
    }

    public func connect() {
        device.connect(port: port, queue: queue) { [weak self] result in
            guard let self else { return }
            self.queue.async { self.opened(result) }
        }
    }

    private func opened(_ result: Result<ByteStream, Error>) {
        switch result {
        case .failure(let error):
            finish(error)
        case .success(let stream):
            guard !closed else { stream.cancel(); return }
            let channel = ControlConnection(stream)
            channel.onMessage = { [weak self] message in self?.handle(message) }
            channel.onClose = { [weak self] error in self?.finish(error) }
            self.channel = channel
            channel.start(queue: queue)
            var hello = ControlEnvelope(t: ControlEnvelope.hello)
            hello.protocolVersion = PassthroughProtocol.version
            hello.clientID = identity.clientID
            hello.name = identity.name
            hello.nonce = macNonce.base64EncodedString()
            hello.via = device.medium == .wireless ? "wireless" : "usb"
            send(hello)
            startHeartbeat()
        }
    }

    public func pair(code: String) {
        queue.async {
            guard self.welcomed else { self.pendingCode = code; return }
            self.sendPair(code)
        }
    }

    private func sendPair(_ code: String) {
        var m = ControlEnvelope(t: ControlEnvelope.pair)
        m.clientID = identity.clientID
        m.name = identity.name
        m.code = code
        pairing = true
        send(m)
    }

    /// Hands the phone what it needs to reach this Mac wirelessly (after pairing).
    public func link(linkKey: Data, certificateSHA256: String) {
        queue.async {
            guard self.authenticated else { ptLog(.warning, "control: not sending the link key over an unauthenticated channel"); return }
            var m = ControlEnvelope(t: ControlEnvelope.link)
            m.linkKey = linkKey.base64EncodedString()
            m.certSHA256 = certificateSHA256
            self.send(m)
        }
    }

    /// Hands the phone a key to open shells on this Mac, and where to find it (after pairing).
    /// `grantID` (at most 64 UTF-8 bytes) comes back in the phone's answer.
    public func grantShell(shellKey: Data, certificateSHA256: String, port: UInt16, addresses: [String], macName: String,
                           irohID: String? = nil, irohRelay: String? = nil, relayToken: String? = nil, grantID: String? = nil) {
        queue.async {
            guard self.authenticated else { ptLog(.warning, "control: not sending a shell key over an unauthenticated channel"); return }
            var m = ControlEnvelope(t: ControlEnvelope.shellGrant)
            m.grantID = grantID
            m.shellKey = shellKey.base64EncodedString()
            m.certSHA256 = certificateSHA256
            m.shellPort = Int(port)
            m.addresses = addresses
            m.macName = macName
            m.irohID = irohID
            m.irohRelay = irohRelay
            m.relayToken = relayToken
            self.send(m)
        }
    }

    public func close() {
        queue.async { self.finish(nil, silent: true) }
    }

    private func startHeartbeat() {
        lastPong = Date()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 5, repeating: 5)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            if Date().timeIntervalSince(self.lastPong) > self.silenceLimit {
                self.finish(NSError(domain: "Passthrough", code: 1, userInfo: [NSLocalizedDescriptionKey: "The phone stopped responding"]))
                return
            }
            self.send(ControlEnvelope(t: ControlEnvelope.ping))
        }
        timer.resume()
        heartbeat = timer
    }

    private func send(_ message: ControlEnvelope) {
        channel?.send(message)
    }

    private func handle(_ m: ControlEnvelope) {
        lastPong = Date()
        let status = DeviceStatus(deviceName: m.deviceName ?? device.kindName, radio: m.radio, carrier: m.carrier, battery: m.battery, hosting: m.hosting ?? "", ipv6: m.ipv6)
        switch m.t {
        case ControlEnvelope.welcome:
            guard !welcomed else { return }
            welcomed = true
            welcome(m, status: status)
        case ControlEnvelope.paired:
            // Only the answer to our own `pair`, once: anything else could
            // plant a token of its choosing.
            guard pairing else { ptLog(.warning, "control: ignoring a pairing the Mac did not ask for"); return }
            pairing = false
            if let token = m.token {
                authenticated = true
                handler(.paired(token: token))
            }
        case ControlEnvelope.error:
            let failure = PairingFailure(rawValue: m.reason ?? "") ?? .badCode
            if failure == .unsupportedVersion {
                // Phones from before version 2 say nothing of their own version.
                finish(ControlError.incompatible(kind: device.kindName, phoneIsOlder: (m.protocolVersion ?? 1) < PassthroughProtocol.version))
                return
            }
            pairing = false
            handler(.pairingFailed(failure))
        case ControlEnvelope.linked:
            if authenticated, let phoneID = m.phoneID, !phoneID.isEmpty, phoneID.count <= 64 {
                handler(.linked(phoneID: phoneID, network: m.network, passphrase: m.passphrase))
            }
        case ControlEnvelope.shellGranted:
            if authenticated, let phoneID = m.phoneID, !phoneID.isEmpty, phoneID.count <= 64 {
                handler(.shellGranted(phoneID: phoneID, grantID: m.grantID))
            }
        case ControlEnvelope.status:
            guard authenticated else { return }
            handler(.status(status, rx: m.rxBytes ?? 0, tx: m.txBytes ?? 0, active: m.activeConnections ?? 0))
        default: break
        }
    }

    private func welcome(_ m: ControlEnvelope, status: DeviceStatus) {
        let version = m.protocolVersion ?? 0
        guard version == PassthroughProtocol.version else {
            finish(ControlError.incompatible(kind: device.kindName, phoneIsOlder: version < PassthroughProtocol.version))
            return
        }
        // From the phone: a port it can't have is the default, never a trap.
        let socksPort = m.socksPort.flatMap { UInt16(exactly: $0) }.flatMap { $0 > 0 ? $0 : nil } ?? PassthroughProtocol.defaultSOCKSPort
        var paired = false
        if m.paired == true {
            if let token = identity.token, let phoneNonce = ControlAuth.decodeNonce(m.nonce),
               ControlAuth.isValidPhoneProof(m.proof, key: ControlAuth.key(token: token), clientID: identity.clientID, macNonce: macNonce, phoneNonce: phoneNonce) {
                // Our proof goes before anything else on this channel.
                var auth = ControlEnvelope(t: ControlEnvelope.auth)
                auth.proof = ControlAuth.macProof(key: ControlAuth.key(token: token), clientID: identity.clientID,
                                                  macNonce: macNonce, phoneNonce: phoneNonce).base64EncodedString()
                send(auth)
                authenticated = true
                paired = true
            } else if identity.token == nil {
                // The phone remembers a pairing this Mac no longer has; pairing again replaces it.
                ptLog(.info, "control: the \(device.kindName) remembers this Mac, but this Mac has no pairing for it")
            } else if identity.tokenIsGuess {
                ptLog(.warning, "control: the \(device.kindName) is not the one this Mac's earlier iPhone pairing belongs to")
            } else {
                ptLog(.warning, "control: the \(device.kindName) said it was paired but could not prove it; closing the connection")
                finish(ControlError.proofFailed(kind: device.kindName))
                return
            }
        }
        handler(.welcomed(paired: paired, status: status, socksPort: socksPort))
        if !paired, let code = pendingCode {
            pendingCode = nil
            sendPair(code)
        }
    }

    private func finish(_ error: Error?, silent: Bool = false) {
        guard !closed else { return }
        closed = true
        heartbeat?.cancel()
        channel?.cancel()
        channel = nil
        if !silent { handler(.disconnected(error)) }
    }
}
