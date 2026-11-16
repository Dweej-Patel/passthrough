#if os(macOS)
import CryptoKit
import Foundation
import PassthroughCore

/// What signs requests to Apple's push service: the developer team, and a
/// key made for it in the developer account (Keys › Apple Push Notifications
/// service). The Mac keeps the key in its Keychain; it never leaves the Mac.
public struct APNsCredentials: Equatable, Sendable {
    public var teamID: String
    public var keyID: String
    /// The `.p8` file's contents (a PEM PKCS#8 P-256 key).
    public var privateKey: String

    public init(teamID: String, keyID: String, privateKey: String) {
        self.teamID = teamID; self.keyID = keyID; self.privateKey = privateKey
    }

    /// Ten-character IDs and a key CryptoKit can read; nil when all is well, else what is wrong.
    public var problem: String? {
        let id = { (s: String) in s.count == 10 && s.allSatisfy { $0.isASCII && ($0.isUppercase || $0.isNumber) } }
        if !id(teamID) { return "The Team ID is ten letters and digits, as the developer account shows it." }
        if !id(keyID) { return "The Key ID is ten letters and digits, as the developer account shows it." }
        if (try? P256.Signing.PrivateKey(pemRepresentation: privateKey)) == nil { return "That is not an APNs key (.p8) file." }
        return nil
    }
}

/// What can carry a request to APNs; URLSession (HTTP/2), or a fake in tests.
public protocol PushTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (status: Int, body: Data)
}

public struct URLSessionPushTransport: PushTransport {
    private let session: URLSession
    public init(session: URLSession = URLSession(configuration: .ephemeral)) { self.session = session }
    public func send(_ request: URLRequest) async throws -> (status: Int, body: Data) {
        let (data, response) = try await session.data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
    }
}

/// Sends notices to APNs with token (JWT) authentication.
/// https://developer.apple.com/documentation/usernotifications/sending-notification-requests-to-apns
public actor APNsClient {
    public enum Outcome: Equatable, Sendable {
        case sent
        /// The phone's token no longer works (the app was removed, or it is another build's): forget it.
        case tokenGone
        /// The team, key or key ID was refused: nothing will go out until they are fixed.
        case credentialsRefused(String)
        /// Anything else (network, APNs busy): this notice is lost, the next may go.
        case failed(String)
    }

    private let credentials: APNsCredentials
    private let transport: PushTransport
    private let now: @Sendable () -> Date
    private var token: (jwt: String, at: Date)?
    /// APNs refuses a token older than an hour and one refreshed more often than every 20 minutes.
    static let tokenLifetime: TimeInterval = 45 * 60

    public init(credentials: APNsCredentials, transport: PushTransport = URLSessionPushTransport(),
                now: @escaping @Sendable () -> Date = Date.init) {
        self.credentials = credentials; self.transport = transport; self.now = now
    }

    /// Sends `payload` (the APNs JSON) to `registration`'s device. `collapseID`
    /// lets a newer notice about the same thing replace an older one.
    public func send(_ payload: Data, to registration: PushRegistration, collapseID: String?, timeSensitive: Bool) async -> Outcome {
        let host = registration.environment == PushRegistration.sandbox ? "api.sandbox.push.apple.com" : "api.push.apple.com"
        guard let url = URL(string: "https://\(host)/3/device/\(registration.token)") else { return .tokenGone }
        let jwt: String
        do { jwt = try bearer() } catch { return .credentialsRefused("The APNs key could not sign: \(error.localizedDescription)") }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = payload
        request.timeoutInterval = 20
        request.setValue("bearer \(jwt)", forHTTPHeaderField: "authorization")
        request.setValue(registration.topic, forHTTPHeaderField: "apns-topic")
        request.setValue("alert", forHTTPHeaderField: "apns-push-type")
        request.setValue(timeSensitive ? "10" : "5", forHTTPHeaderField: "apns-priority")
        // Worth delivering for an hour, not once the phone is back days later.
        request.setValue(String(Int(now().timeIntervalSince1970) + 3600), forHTTPHeaderField: "apns-expiration")
        if let collapseID { request.setValue(String(collapseID.prefix(64)), forHTTPHeaderField: "apns-collapse-id") }
        let status: Int, body: Data
        do { (status, body) = try await transport.send(request) } catch { return .failed(error.localizedDescription) }
        if status == 200 { return .sent }
        let reason = (try? JSONSerialization.jsonObject(with: body) as? [String: Any])?["reason"] as? String ?? "HTTP \(status)"
        switch (status, reason) {
        case (410, _), (400, "BadDeviceToken"):
            return .tokenGone
        case (400, "TopicDisallowed"), (400, "DeviceTokenNotForTopic"):
            // The key's team isn't the app's (or the app is another build's): a
            // phone asking again would get the same, so it is kept and the key questioned.
            return .credentialsRefused(reason)
        case (403, "ExpiredProviderToken"):
            self.token = nil
            return .failed(reason)
        case (403, _):
            return .credentialsRefused(reason)
        default:
            return .failed(reason)
        }
    }

    /// A signed JWT (ES256) for the credentials, reused until `tokenLifetime`.
    private func bearer() throws -> String {
        if let token, now().timeIntervalSince(token.at) < Self.tokenLifetime { return token.jwt }
        let key = try P256.Signing.PrivateKey(pemRepresentation: credentials.privateKey)
        let issued = now()
        let header = Self.base64URL(Data(#"{"alg":"ES256","kid":"\#(credentials.keyID)"}"#.utf8))
        let claims = Self.base64URL(Data(#"{"iss":"\#(credentials.teamID)","iat":\#(Int(issued.timeIntervalSince1970))}"#.utf8))
        let input = header + "." + claims
        let signature = try key.signature(for: Data(input.utf8)).rawRepresentation
        let jwt = input + "." + Self.base64URL(signature)
        token = (jwt, issued)
        return jwt
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
#endif
