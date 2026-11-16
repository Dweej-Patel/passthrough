import Foundation
import Network
import PassthroughCore

/// The iPad's side of QR pairing (`IPadEnrollment`): listens while its pairing
/// code shows, challenges whoever dials in to prove the code's secret, and
/// hands the iPhone it then knows to `onEnrolled`, which keeps it. Once one
/// iPhone has enrolled, or the code expires, it stops.
public final class EnrollmentListener: @unchecked Sendable {
    public let invitation: IPadEnrollment.Invitation
    private let identity: MacIdentity
    private let advertise: Bool
    private let queue = DispatchQueue(label: "\(PassthroughProtocol.identifier).enrollment")
    private var listener: NWListener?
    private var streams: [ObjectIdentifier: ConnectionStream] = [:]
    private var used = false
    private var failures = 0
    /// Keeps the iPhone; true when it was stored. Called on the listener's queue.
    public var onEnrolled: (@Sendable (UpstreamPhone) -> Bool)?
    /// The listener's port once it listens (tests).
    public private(set) var port: UInt16?

    public init(invitation: IPadEnrollment.Invitation, identity: MacIdentity, advertise: Bool = true) {
        self.invitation = invitation
        self.identity = identity
        self.advertise = advertise
    }

    public func start(onReady: (@Sendable (UInt16) -> Void)? = nil) throws {
        let params = try identity.tlsListenerParameters()
        params.includePeerToPeer = false
        let listener = try NWListener(using: params)
        if advertise {
            let tag = invitation.tag
            listener.service = NWListener.Service(name: "\(tag)-pair", type: WirelessLink.serviceType,
                                                  txtRecord: NWTXTRecord([IPadEnrollment.txtKey: tag]))
        }
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            if case .ready = state, let port = listener?.port?.rawValue {
                self?.port = port
                onReady?(port)
            }
            if case .failed(let error) = state { ptLog(.error, "pairing: listener failed: \(error)") }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.start(queue: queue)
        self.listener = listener
        queue.asyncAfter(deadline: .now() + max(0, invitation.expiry.timeIntervalSinceNow)) { [weak self] in self?.stop() }
    }

    public func stop() {
        queue.async { [self] in
            listener?.cancel()
            listener = nil
            streams.values.forEach { $0.cancel() }
            streams.removeAll()
        }
    }

    private func accept(_ connection: NWConnection) {
        guard !used, streams.count < 4 else { connection.cancel(); return }
        let stream = ConnectionStream(connection, queue: queue)
        let id = ObjectIdentifier(stream)
        streams[id] = stream
        stream.onTerminated = { [weak self] _ in self?.queue.async { self?.streams[id] = nil } }
        let nonce = WirelessLink.randomBytes(32)
        IPadEnrollment.send(.init(t: "challenge", nonce: nonce.base64EncodedString()), on: stream)
        IPadEnrollment.read(stream) { [weak self] result in
            self?.queue.async { self?.answered(result, nonce: nonce, on: stream) }
        }
        queue.asyncAfter(deadline: .now() + 15) { [weak self] in
            guard self?.streams[id] != nil else { return }
            stream.cancel()
        }
    }

    private func answered(_ result: Result<IPadEnrollment.Message, Error>, nonce: Data, on stream: ConnectionStream) {
        func refuse(_ why: String) {
            IPadEnrollment.send(.init(t: "error", error: why), on: stream)
            queue.asyncAfter(deadline: .now() + 0.5) { stream.cancel() }
        }
        guard !used else { return refuse("this code was already used") }
        guard !invitation.isExpired else { return refuse("this code has expired") }
        guard case .success(let m) = result, m.t == "enroll",
              let mac = m.mac.flatMap({ Data(base64Encoded: $0) }),
              IPadEnrollment.proofIsValid(mac, secret: invitation.secret, nonce: nonce) else {
            failures += 1
            if failures >= 5 { ptLog(.warning, "pairing: too many wrong answers; stopping"); stop() }
            return refuse("that isn't the iPhone that scanned this code")
        }
        guard let phoneID = m.phoneID, !phoneID.isEmpty, phoneID.count <= 64,
              let name = m.name, !name.isEmpty, name.count <= 64,
              let token = m.token, PairingToken.isWellFormed(token),
              let linkKey = m.linkKey.flatMap({ Data(base64Encoded: $0) }), linkKey.count == 32 else {
            return refuse("the pairing details were incomplete")
        }
        let phone = UpstreamPhone(phoneID: phoneID, name: name, token: token, linkKey: linkKey)
        guard onEnrolled?(phone) == true else { return refuse("this iPad couldn't store the pairing") }
        used = true
        ptLog(.info, "pairing: paired with \(name)")
        IPadEnrollment.send(.init(t: "enrolled"), on: stream)
        queue.asyncAfter(deadline: .now() + 0.5) { [weak self] in stream.cancel(); self?.stop() }
    }
}
