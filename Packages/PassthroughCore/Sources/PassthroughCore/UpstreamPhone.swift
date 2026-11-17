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

/// What the iPad's app and its tunnel extension agree on for "Internet through iPhone".
public enum HotspotTunnel {
    /// `providerConfiguration[roleKey] == clientRole`: the extension is an
    /// iPad's client, not a phone's proxy host.
    public static let roleKey = "role"
    public static let clientRole = "hotspotClient"
    /// The iPad's name, as its iPhone lists it.
    public static let nameKey = "name"
    /// The app message that asks the extension for its `HotspotStatus`.
    public static let statusMessage = Data("hotspot".utf8)
    /// In the start options: the user turned it on (iOS didn't start it on demand).
    public static let manualStartKey = "manual"
    /// The Keychain label of the iPad's TLS identity (its iPhone pins the certificate).
    public static let identityLabel = "\(PassthroughProtocol.identifier).ipad-link"
    /// The tunnel's addresses: the iPad's side, and the DNS server apps are
    /// told to use (a private address, so the iPhone sends it to its own resolver).
    public static let ipv4Address = "10.255.253.2"
    public static let dnsAddress = "10.255.253.53"

    /// The DNS servers the iPhone's hotspot handed this iPad, learned once a
    /// link through it worked. An IPv6-only hotspot names the iPhone's own
    /// link-local address rather than 172.20.10.1, so this is how the
    /// on-demand rule (and the hotspot check) knows it next time.
    /// v2: what earlier builds learned may be any shared Wi-Fi (the iPhone
    /// then also linked an iPad there), so it's dropped.
    static let knownDNSKey = "hotspot.knownDNS.v2"

    /// Read clean: entries saved by earlier builds may hold duplicates or
    /// addresses every network of a kind shares (192.0.0.1), which say nothing.
    public static func knownHotspotDNS(_ defaults: UserDefaults) -> [String] {
        var known: [String] = []
        for server in defaults.stringArray(forKey: knownDNSKey) ?? [] where
            !WirelessLink.isGenericAddress(server) && server != dnsAddress && !known.contains(server) {
            known.append(server)
        }
        return known
    }

    /// Adds `servers` (the network's DNS servers and routers, as a link
    /// through the iPhone found them) to what's known, newest first, a few at
    /// most. Skips the tunnel's own address and addresses every network of a
    /// kind shares. True if anything new was added.
    @discardableResult
    public static func rememberHotspotDNS(_ servers: [String], in defaults: UserDefaults) -> Bool {
        let known = knownHotspotDNS(defaults)
        var fresh: [String] = []
        for server in servers.map(WirelessLink.bareAddress) where !server.isEmpty && server != dnsAddress
            && server != "127.0.0.1" && server != "::1" && !WirelessLink.isGenericAddress(server)
            && !known.contains(server) && !fresh.contains(server) {
            fresh.append(server)
        }
        guard !fresh.isEmpty else { return false }
        defaults.set(Array((fresh + known).prefix(6)), forKey: knownDNSKey)
        return true
    }

    /// Forgets every hotspot learned (the iPhone was forgotten or replaced).
    public static func forgetHotspots(in defaults: UserDefaults) {
        defaults.removeObject(forKey: knownDNSKey)
        defaults.removeObject(forKey: "hotspot.knownDNS")
    }

    /// Drops what was learned that matches `addresses` (this network's DNS
    /// servers and routers) when the network isn't one an iPhone's hotspot
    /// can be (iOS doesn't count it as costly). True if anything was dropped.
    @discardableResult
    public static func forgetHotspots(matching addresses: [String], in defaults: UserDefaults) -> Bool {
        let bare = Set(addresses.map(WirelessLink.bareAddress))
        let known = knownHotspotDNS(defaults)
        let kept = known.filter { !bare.contains($0) }
        guard kept != known else { return false }
        defaults.set(kept, forKey: knownDNSKey)
        return true
    }

    /// The on-demand rule's DNS matches: each known server, and a link-local
    /// one also with its scope (iOS may report it either way).
    public static func onDemandDNSMatches(_ defaults: UserDefaults) -> [String] {
        var matches = [WirelessLink.hotspotGateway]
        for server in knownHotspotDNS(defaults) where !matches.contains(server) {
            matches.append(server)
            if server.lowercased().hasPrefix("fe80:") { matches.append(server + "%en0") }
        }
        return matches
    }
}
