import CryptoKit
import Foundation

/// A phone asking a Mac to tell it, through Apple's push service, when a
/// shell needs it or has finished (`ShellEnvelope.push`).
///
/// The Mac sends what happened sealed with `key`, which only this phone and
/// that Mac hold (it went over the authenticated shell connection): Apple
/// carries a box it cannot open, and the phone's notification extension
/// opens it (`PushBox`).
public struct PushRegistration: Codable, Equatable, Sendable {
    /// The device token from APNs, as lowercase hex.
    public var token: String
    /// `sandbox` for a development build (Xcode), `production` otherwise.
    public var environment: String
    /// The app's bundle identifier: the topic pushes are sent to.
    public var topic: String
    /// 32 random bytes, base64: what the Mac seals each notice with.
    public var key: String
    /// What the phone calls this Mac (its pairing's ID): every notice carries
    /// it, so the phone knows whose key opens it and which Mac to show.
    public var mac: String

    public static let sandbox = "sandbox", production = "production"

    public init(token: String, environment: String, topic: String, key: String, mac: String) {
        self.token = token; self.environment = environment; self.topic = topic; self.key = key; self.mac = mac
    }

    /// Hex of 32–100 bytes, a known environment, a bundle identifier, and a 32-byte key.
    public var isValid: Bool {
        let hex = token.utf8.allSatisfy { (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }
        let topicOK = topic.utf8.count <= 155 && !topic.isEmpty
            && topic.utf8.allSatisfy { (0x30...0x39).contains($0) || (0x41...0x5A).contains($0) || (0x61...0x7A).contains($0) || $0 == 0x2E || $0 == 0x2D }
        return hex && (64...200).contains(token.utf8.count) && token.utf8.count % 2 == 0
            && (environment == Self.sandbox || environment == Self.production)
            && topicOK && Data(base64Encoded: key)?.count == 32
            && (1...128).contains(mac.utf8.count) && mac.unicodeScalars.allSatisfy { $0.isASCII && $0.value > 0x20 && $0 != "\"" }
    }
}

/// What a notice says, inside the sealed box.
public struct PushNotice: Codable, Equatable, Sendable {
    /// The Mac's name, as a subtitle.
    public var macName: String
    public var title: String
    public var body: String
    /// The session it is about, to open on a tap.
    public var session: String
    /// `ShellStatus.state` (`blocked`, `done`, `error`).
    public var state: String

    public init(macName: String, title: String, body: String, session: String, state: String) {
        self.macName = macName; self.title = title; self.body = body; self.session = session; self.state = state
    }
}

/// Sealing a `PushNotice` for one phone: ChaCha20-Poly1305 with the
/// registration's key, the Mac's ID bound in as associated data (a box for
/// one Mac never opens as another's).
public enum PushBox {
    /// The field of the APNs payload carrying the box, beside `aps`.
    public static let payloadKey = "pt"
    /// What the phone shows if its extension can't open the box: nothing about what happened.
    public static let fallbackTitle = "Passthrough"
    public static let fallbackBody = "Something on your Mac needs a look."

    public static func seal(_ notice: PushNotice, key: Data, macID: String) throws -> String {
        let box = try ChaChaPoly.seal(JSONEncoder().encode(notice), using: SymmetricKey(data: key), authenticating: Data(macID.utf8))
        return box.combined.base64EncodedString()
    }

    public static func open(_ sealed: String, key: Data, macID: String) -> PushNotice? {
        guard let data = Data(base64Encoded: sealed), let box = try? ChaChaPoly.SealedBox(combined: data),
              let plain = try? ChaChaPoly.open(box, using: SymmetricKey(data: key), authenticating: Data(macID.utf8)) else { return nil }
        return try? JSONDecoder().decode(PushNotice.self, from: plain)
    }

    /// A new key for a Mac: 32 random bytes.
    public static func newKey() -> Data { SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) } }
}

/// Where the phone keeps the key each Mac seals its notices with: the
/// Keychain, shared only with the notification extension (an app group of
/// its own, `appGroup`), readable after the first unlock so notices open
/// while the phone is locked.
public enum PushKeys {
    public static let appGroup = PassthroughProtocol.appGroup + ".push"

    public static func store() -> SecretStore { KeychainSecrets(accessGroup: appGroup) }

    static func account(_ mac: String) -> String { "push." + mac }

    public static func key(for mac: String, in secrets: SecretStore) -> Data? {
        secrets.read(account(mac)).flatMap { $0.count == 32 ? $0 : nil }
    }

    /// The Mac's key, made the first time it is asked for; nil if it can't be stored.
    public static func keyCreating(for mac: String, in secrets: SecretStore) -> Data? {
        if let key = key(for: mac, in: secrets) { return key }
        let key = PushBox.newKey()
        return secrets.write(key, account: account(mac)) ? key : nil
    }

    public static func forget(_ mac: String, in secrets: SecretStore) { secrets.delete(account(mac)) }
}
