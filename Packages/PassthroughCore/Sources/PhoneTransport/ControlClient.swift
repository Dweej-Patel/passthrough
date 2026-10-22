import Foundation
import Network
import PassthroughCore

/// Mac side of the control channel: says hello, pairs, keeps a heartbeat,
/// and relays the phone's live status.
public final class ControlClient: @unchecked Sendable {
    public struct Identity: Sendable {
        public var clientID: String
        public var name: String
        public var token: String?
        public init(clientID: String, name: String, token: String?) { self.clientID = clientID; self.name = name; self.token = token }
    }

    public enum Event: Sendable {
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

    private let device: PhoneDevice
    private let port: UInt16
    private let identity: Identity
    private let queue = DispatchQueue(label: "\(PassthroughProtocol.identifier).control-client")
    private var channel: ControlConnection?
    private var heartbeat: DispatchSourceTimer?
    private var lastPong = Date()
    private var closed = false
    private let handler: @Sendable (Event) -> Void

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
            hello.token = identity.token
            hello.via = device.medium == .wireless ? "wireless" : "usb"
            send(hello)
            startHeartbeat()
        }
    }

    public func pair(code: String) {
        queue.async {
            var m = ControlEnvelope(t: ControlEnvelope.pair)
            m.clientID = self.identity.clientID
            m.name = self.identity.name
            m.code = code
            self.send(m)
        }
    }

    /// Hands the phone what it needs to reach this Mac wirelessly (after pairing).
    public func link(linkKey: Data, certificateSHA256: String) {
        queue.async {
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
            handler(.welcomed(paired: m.paired ?? false, status: status, socksPort: UInt16(m.socksPort ?? Int(PassthroughProtocol.defaultSOCKSPort))))
        case ControlEnvelope.paired:
            if let token = m.token { handler(.paired(token: token)) }
        case ControlEnvelope.error:
            handler(.pairingFailed(PairingFailure(rawValue: m.reason ?? "") ?? .badCode))
        case ControlEnvelope.linked:
            if let phoneID = m.phoneID, !phoneID.isEmpty, phoneID.count <= 64 {
                handler(.linked(phoneID: phoneID, network: m.network, passphrase: m.passphrase))
            }
        case ControlEnvelope.shellGranted:
            if let phoneID = m.phoneID, !phoneID.isEmpty, phoneID.count <= 64 {
                handler(.shellGranted(phoneID: phoneID, grantID: m.grantID))
            }
        case ControlEnvelope.status:
            handler(.status(status, rx: m.rxBytes ?? 0, tx: m.txBytes ?? 0, active: m.activeConnections ?? 0))
        default: break
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
