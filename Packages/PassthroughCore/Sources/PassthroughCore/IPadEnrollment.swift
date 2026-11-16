import Foundation
import Network
import CryptoKit

/// Pairing an iPad with an iPhone without a Mac: the iPad shows a QR code, the
/// iPhone scans it and dials the iPad over the hotspot.
///
/// The camera plays the cable's part. The code carries the iPad's certificate
/// fingerprint, so the iPhone's TLS (pinned to it) reaches only that iPad and
/// no one else can read what it sends; and a one-time secret, so the iPad
/// knows the iPhone dialing in is the one that scanned it (it proves the
/// secret against a fresh challenge). Only then does the iPad keep the token
/// and link key the iPhone issued. The code works once, for five minutes.
public enum IPadEnrollment {
    public static let lifetime: TimeInterval = 300
    /// The TXT key the iPad's pairing listener advertises its tag under (the
    /// link's own listener uses `m`, so the two never mix).
    public static let txtKey = "e"
    static let proofLabel = Data("passthrough-enroll-v1".utf8)

    /// What the QR code says.
    public struct Invitation: Equatable, Sendable {
        public var clientID: String
        public var name: String
        public var certSHA256: String
        public var secret: Data
        public var expiry: Date

        public init(clientID: String, name: String, certSHA256: String, secret: Data = WirelessLink.randomBytes(32),
                    expiry: Date = Date().addingTimeInterval(IPadEnrollment.lifetime)) {
            self.clientID = clientID; self.name = name; self.certSHA256 = certSHA256; self.secret = secret; self.expiry = expiry
        }

        public var tag: String { WirelessLink.macTag(clientID: clientID) }
        public var isExpired: Bool { Date() > expiry }

        public var url: URL {
            var c = URLComponents()
            c.scheme = "passthrough"
            c.host = "pair-ipad"
            c.queryItems = [
                URLQueryItem(name: "v", value: "1"),
                URLQueryItem(name: "c", value: clientID),
                URLQueryItem(name: "n", value: name),
                URLQueryItem(name: "f", value: certSHA256),
                URLQueryItem(name: "s", value: secret.base64URL),
                URLQueryItem(name: "e", value: String(Int(expiry.timeIntervalSince1970))),
            ]
            return c.url!
        }

        /// Nil unless it's a well-formed version 1 invitation.
        public init?(url: URL) {
            guard url.scheme == "passthrough", url.host == "pair-ipad",
                  let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return nil }
            func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
            guard value("v") == "1",
                  let clientID = value("c"), (1...64).contains(clientID.count),
                  let name = value("n"), (1...64).contains(name.count),
                  let cert = value("f"), cert.count == 64, cert.allSatisfy(\.isHexDigit),
                  let secret = value("s").flatMap(Data.init(base64URL:)), secret.count == 32,
                  let expiry = value("e").flatMap(TimeInterval.init) else { return nil }
            self.init(clientID: clientID, name: name, certSHA256: cert.lowercased(), secret: secret,
                      expiry: Date(timeIntervalSince1970: expiry))
        }
    }

    /// The lines each side sends: challenge (iPad), enroll (iPhone), enrolled or error (iPad).
    public struct Message: Codable, Sendable {
        public var t: String
        public var nonce: String?
        public var mac: String?
        public var phoneID: String?
        public var name: String?
        public var token: String?
        public var linkKey: String?
        public var error: String?
        public init(t: String, nonce: String? = nil, mac: String? = nil, phoneID: String? = nil, name: String? = nil,
                    token: String? = nil, linkKey: String? = nil, error: String? = nil) {
            self.t = t; self.nonce = nonce; self.mac = mac; self.phoneID = phoneID; self.name = name
            self.token = token; self.linkKey = linkKey; self.error = error
        }
    }

    public static func proof(secret: Data, nonce: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: proofLabel + nonce, using: SymmetricKey(data: secret)))
    }

    public static func proofIsValid(_ proof: Data, secret: Data, nonce: Data) -> Bool {
        HMAC<SHA256>.isValidAuthenticationCode(proof, authenticating: proofLabel + nonce, using: SymmetricKey(data: secret))
    }

    public enum EnrollmentError: LocalizedError, Equatable {
        case notFound, refused(String), expired, failed(String)
        public var errorDescription: String? {
            switch self {
            case .notFound: "Couldn't find the iPad. Make sure it's on this iPhone's Personal Hotspot with its pairing code showing."
            case .refused(let why): "The iPad refused: \(why)"
            case .expired: "That code has expired. Show a new one on the iPad."
            case .failed(let why): "Pairing didn't finish: \(why)"
            }
        }
    }

    public static func send(_ message: Message, on stream: ByteStream) {
        guard var data = try? JSONEncoder().encode(message) else { return }
        data.append(0x0A)
        stream.send(data, isComplete: false) { _ in }
    }

    public static func read(_ stream: ByteStream, completion: @escaping @Sendable (Result<Message, Error>) -> Void) {
        WirelessLink.readLine(stream, limit: 16 * 1024) { result in
            completion(result.flatMap { line, _ in
                Result { try JSONDecoder().decode(Message.self, from: line) }
            })
        }
    }

    /// The iPhone's side: finds the iPad from `invitation` on a network both
    /// are on (its hotspot), proves the scanned secret, and hands over the
    /// iPad's pairing token and link key. Completes on `queue` once the iPad
    /// has kept them.
    public static func enroll(_ invitation: Invitation, phoneID: String, phoneName: String, token: String, linkKey: Data,
                              timeout: TimeInterval = 20, queue: DispatchQueue = .main,
                              completion: @escaping @Sendable (Result<Void, EnrollmentError>) -> Void) {
        guard !invitation.isExpired else { queue.async { completion(.failure(.expired)) }; return }
        let work = DispatchQueue(label: "\(PassthroughProtocol.identifier).enroll")
        let state = EnrollState(queue: queue, completion: completion)
        let params = NWParameters.tcp
        params.includePeerToPeer = false
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: WirelessLink.serviceType, domain: nil), using: params)
        state.browser = browser
        browser.browseResultsChangedHandler = { results, _ in
            guard let result = results.first(where: {
                if case .bonjour(let txt) = $0.metadata { return txt[txtKey] == invitation.tag } else { return false }
            }), state.claimDial() else { return }
            browser.cancel()
            let connection = NWConnection(to: result.endpoint, using: WirelessLink.pinnedClientParameters(pin: invitation.certSHA256, peerToPeer: false))
            let stream = ConnectionStream(connection, queue: work)
            state.stream = stream
            stream.onTerminated = { error in state.finish(.failure(.failed(error?.localizedDescription ?? "the connection closed"))) }
            read(stream) { result in
                guard case .success(let challenge) = result, challenge.t == "challenge",
                      let nonce = challenge.nonce.flatMap({ Data(base64Encoded: $0) }), nonce.count == 32 else {
                    state.finish(.failure(.failed("the iPad didn't answer as expected"))); return
                }
                let mac = proof(secret: invitation.secret, nonce: nonce).base64EncodedString()
                send(Message(t: "enroll", mac: mac, phoneID: phoneID, name: phoneName, token: token,
                             linkKey: linkKey.base64EncodedString()), on: stream)
                read(stream) { result in
                    switch result {
                    case .success(let answer) where answer.t == "enrolled": state.finish(.success(()))
                    case .success(let answer): state.finish(.failure(.refused(answer.error ?? "no reason given")))
                    case .failure(let error): state.finish(.failure(.failed(error.localizedDescription)))
                    }
                }
            }
        }
        browser.start(queue: work)
        work.asyncAfter(deadline: .now() + timeout) { state.finish(.failure(.notFound)) }
    }

    /// One enrollment attempt's state: finishes once.
    private final class EnrollState: @unchecked Sendable {
        let queue: DispatchQueue
        let completion: @Sendable (Result<Void, EnrollmentError>) -> Void
        var browser: NWBrowser?
        var stream: ConnectionStream?
        private let lock = NSLock()
        private var dialed = false
        private var done = false
        init(queue: DispatchQueue, completion: @escaping @Sendable (Result<Void, EnrollmentError>) -> Void) {
            self.queue = queue; self.completion = completion
        }
        func claimDial() -> Bool { lock.withLock { defer { dialed = true }; return !dialed } }
        func finish(_ result: Result<Void, EnrollmentError>) {
            guard lock.withLock({ defer { done = true }; return !done }) else { return }
            browser?.cancel()
            stream?.onTerminated = nil
            stream?.cancel()
            queue.async { self.completion(result) }
        }
    }
}

extension Data {
    var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    init?(base64URL: String) {
        var s = base64URL.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s += "=" }
        self.init(base64Encoded: s)
    }
}
