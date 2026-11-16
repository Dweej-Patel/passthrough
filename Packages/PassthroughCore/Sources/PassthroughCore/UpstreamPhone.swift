import Foundation

/// The iPhone an iPad gets its internet from, as the iPad keeps it: what the
/// iPad proves itself with when the iPhone dials it over the hotspot, and
/// what its SOCKS password and control proofs are made from.
public struct UpstreamPhone: Codable, Equatable, Sendable {
    /// The iPhone's `phoneID`, as it answers the link challenge with.
    public var phoneID: String
    public var name: String
    /// The pairing token the iPhone issued for this iPad. Never sent.
    public var token: String
    /// The wireless link key the iPhone proves itself with.
    public var linkKey: Data
    public var pairedAt: Date

    public init(phoneID: String, name: String, token: String, linkKey: Data, pairedAt: Date = Date()) {
        self.phoneID = phoneID; self.name = name; self.token = token; self.linkKey = linkKey; self.pairedAt = pairedAt
    }
}

/// Where an iPad keeps its iPhone (one at a time) and its own client ID,
/// in the Keychain shared by the app and the tunnel extension.
public final class UpstreamPhoneStore: @unchecked Sendable {
    private let secrets: SecretStore
    private let lock = NSLock()
    static let phoneAccount = "upstream.phone"
    static let clientIDAccount = "upstream.clientID"

    public init(secrets: SecretStore) { self.secrets = secrets }

    /// The app's and extension's store (the App Group's Keychain).
    public static func shared() -> UpstreamPhoneStore {
        UpstreamPhoneStore(secrets: KeychainSecrets(accessGroup: PassthroughProtocol.appGroup))
    }

    public func load() -> UpstreamPhone? {
        secrets.read(Self.phoneAccount).flatMap { try? JSONDecoder().decode(UpstreamPhone.self, from: $0) }
    }

    @discardableResult
    public func save(_ phone: UpstreamPhone) -> Bool {
        guard let data = try? JSONEncoder().encode(phone) else { return false }
        return secrets.write(data, account: Self.phoneAccount)
    }

    public func forget() { secrets.delete(Self.phoneAccount) }

    /// This iPad's client ID with its iPhone: random, made once, kept across
    /// re-pairing (the iPhone keys the pairing by it, like a Mac's).
    public func clientID() -> String {
        lock.lock(); defer { lock.unlock() }
        if let data = secrets.read(Self.clientIDAccount), let id = String(data: data, encoding: .utf8), !id.isEmpty { return id }
        let id = UUID().uuidString.lowercased()
        secrets.write(Data(id.utf8), account: Self.clientIDAccount)
        return id
    }
}

/// What an iPad's tunnel extension reports to its app about the link to its
/// iPhone ("Internet through iPhone").
public struct HotspotStatus: Codable, Equatable, Sendable {
    public enum Phase: String, Codable, Sendable {
        /// The iPhone hasn't dialed in (yet, or again).
        case waiting
        /// Linked and proved: traffic goes through the iPhone.
        case online
        /// The link dropped and both sides are waiting to resume it.
        case reconnecting
        /// The iPhone dialed in but doesn't know this iPad any more.
        case refused
    }

    public var phase: Phase
    public var phoneName: String?
    /// The iPhone's radio and battery, from its status.
    public var radio: String?
    public var battery: Double?
    /// Whether the iPhone's network routes IPv6.
    public var ipv6: Bool?
    /// Since when it's been online.
    public var since: Date?
    /// Bytes this iPad sent and received through the iPhone since the tunnel started.
    public var rx: Int64
    public var tx: Int64
    /// Why it's refused, or what went wrong.
    public var message: String?

    public init(phase: Phase, phoneName: String? = nil, radio: String? = nil, battery: Double? = nil, ipv6: Bool? = nil,
                since: Date? = nil, rx: Int64 = 0, tx: Int64 = 0, message: String? = nil) {
        self.phase = phase; self.phoneName = phoneName; self.radio = radio; self.battery = battery; self.ipv6 = ipv6
        self.since = since; self.rx = rx; self.tx = tx; self.message = message
    }
}
