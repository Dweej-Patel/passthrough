import Foundation

/// The app's own links (`passthrough://…`): what the Live Activity, widgets
/// and Control Center open. Each lands in the app, which unlocks first; the
/// ones that change the Mac run once it's reachable.
///
/// `.mac` and `.session` can name the Mac they belong to (`?mac=<id>`), so a
/// tap on another Mac's Live Activity switches to that Mac first. Links
/// without it (from older builds) mean the Mac selected now.
public enum AppLink: Equatable, Sendable {
    case mac(String?)
    case keepAwake
    case vpnOn
    case session(String, mac: String?)

    public static let scheme = "passthrough"
    /// The query item naming the Mac.
    static let macItem = "mac"
    /// Pairing caps client IDs at this length.
    static let maxMacIDLength = 64

    public var url: URL {
        switch self {
        case .mac(let macID): Self.url("\(Self.scheme)://mac", macID: macID)
        case .keepAwake: URL(string: "\(Self.scheme)://keep-awake")!
        case .vpnOn: URL(string: "\(Self.scheme)://vpn-on")!
        case .session(let id, let macID):
            Self.url("\(Self.scheme)://session/\(id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id)", macID: macID)
        }
    }

    private static func url(_ base: String, macID: String?) -> URL {
        var components = URLComponents(string: base)!
        if let macID { components.queryItems = [URLQueryItem(name: macItem, value: macID)] }
        return components.url!
    }

    /// Which Mac a link is carried out on.
    public enum Target: Equatable, Sendable {
        /// The Mac selected now.
        case current
        /// Switch to this paired Mac first.
        case mac(String)
        /// It names a Mac that isn't paired: nothing is attached; land on the Mac tab.
        case rejected
    }

    /// Where to carry this link out. A named Mac must be in `paired`. A `.mac` or
    /// `.session` link without one (from a Live Activity an older build started,
    /// which can't carry its Mac, or a widget snapshot from before Macs were named)
    /// belongs to the running activity's Mac, `activityMac` (tagged or adopted), when
    /// that is paired: while an activity runs, the widget shows its Mac too. Otherwise
    /// it means the Mac selected now.
    public func target(activityMac: String?, paired: [String]) -> Target {
        switch self {
        case .keepAwake, .vpnOn: return .current
        case .mac(let macID), .session(_, let macID):
            if let macID { return paired.contains(macID) ? .mac(macID) : .rejected }
            if let activityMac, paired.contains(activityMac) { return .mac(activityMac) }
            return .current
        }
    }

    public init?(url: URL) {
        guard url.scheme == Self.scheme, let host = url.host() else { return nil }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        var macID: String?
        if let item = items.first(where: { $0.name == Self.macItem }) {
            // Named but not a Mac ID pairing could have given: not one of ours.
            guard let value = item.value, !value.isEmpty, value.count <= Self.maxMacIDLength else { return nil }
            macID = value
        }
        switch host {
        case "mac": self = .mac(macID)
        case "keep-awake": self = .keepAwake
        case "vpn-on": self = .vpnOn
        case "session":
            let id = url.path().trimmingCharacters(in: CharacterSet(charactersIn: "/")).removingPercentEncoding ?? ""
            // Session IDs are UUIDs; anything else is not one of ours.
            guard UUID(uuidString: id) != nil else { return nil }
            self = .session(id, mac: macID)
        default: return nil
        }
    }
}
