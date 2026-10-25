import Foundation

/// The app's own links (`passthrough://…`): what the Live Activity, widgets
/// and Control Center open. Each lands in the app, which unlocks first; the
/// ones that change the Mac run once it's reachable.
enum AppLink: Equatable {
    case mac
    case stepAway
    case keepAwake
    case vpnOn
    case session(String)

    static let scheme = "passthrough"

    var url: URL {
        switch self {
        case .mac: URL(string: "\(Self.scheme)://mac")!
        case .stepAway: URL(string: "\(Self.scheme)://step-away")!
        case .keepAwake: URL(string: "\(Self.scheme)://keep-awake")!
        case .vpnOn: URL(string: "\(Self.scheme)://vpn-on")!
        case .session(let id):
            URL(string: "\(Self.scheme)://session/\(id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id)")!
        }
    }

    init?(url: URL) {
        guard url.scheme == Self.scheme, let host = url.host() else { return nil }
        switch host {
        case "mac": self = .mac
        case "step-away": self = .stepAway
        case "keep-awake": self = .keepAwake
        case "vpn-on": self = .vpnOn
        case "session":
            let id = url.path().trimmingCharacters(in: CharacterSet(charactersIn: "/")).removingPercentEncoding ?? ""
            // Session IDs are UUIDs; anything else is not one of ours.
            guard UUID(uuidString: id) != nil else { return nil }
            self = .session(id)
        default: return nil
        }
    }
}
