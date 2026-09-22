import Foundation
import PassthroughCore

/// A saved VPN configuration for the VPN layer. Metadata lives in UserDefaults;
/// the config text (which may contain a private key) and any credentials live
/// in the Keychain.
struct VPNProfile: Codable, Identifiable, Equatable {
    enum Engine: String, Codable, CaseIterable {
        case wireguard, openvpn
        var label: String { self == .wireguard ? "WireGuard" : "OpenVPN" }
    }
    enum Source: String, Codable { case imported, nordvpn }

    var id = UUID()
    var name: String
    var engine: Engine
    var source: Source = .imported
    /// Server host name (e.g. us9591.nordvpn.com) or endpoint for display.
    var server: String?
    /// Human-readable location ("New York, United States").
    var location: String?
    /// NordVPN: "udp" or "tcp".
    var nordProtocol: String?
    /// NordVPN: chosen country, nil = fastest anywhere.
    var nordCountryID: Int?
    var nordCountryName: String?
    var nordCityID: Int?
    var nordCityName: String?
    /// OpenVPN profiles that ask for a username/password.
    var needsCredentials = false
    var createdAt = Date()

    var subtitle: String {
        var parts = [engine.label]
        if let location, !location.isEmpty { parts.append(location) }
        else if let server, !server.isEmpty { parts.append(server) }
        return parts.joined(separator: " · ")
    }
}

/// Persistence for profiles: JSON metadata in defaults, secrets in the Keychain.
enum VPNProfileStore {
    private static let key = "vpnProfiles"

    static func load() -> [VPNProfile] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let list = try? JSONDecoder().decode([VPNProfile].self, from: data) else { return [] }
        return list
    }

    static func save(_ profiles: [VPNProfile]) {
        if let data = try? JSONEncoder().encode(profiles) { UserDefaults.standard.set(data, forKey: key) }
    }

    static func config(for profile: VPNProfile) -> String? { Keychain.read("vpn.\(profile.id.uuidString).config") }
    static func setConfig(_ text: String, for profile: VPNProfile) { Keychain.write(text, account: "vpn.\(profile.id.uuidString).config") }

    static func credentials(for profile: VPNProfile) -> (username: String, password: String) {
        (Keychain.read("vpn.\(profile.id.uuidString).user") ?? "", Keychain.read("vpn.\(profile.id.uuidString).pass") ?? "")
    }
    static func setCredentials(username: String, password: String, for profile: VPNProfile) {
        Keychain.write(username, account: "vpn.\(profile.id.uuidString).user")
        Keychain.write(password, account: "vpn.\(profile.id.uuidString).pass")
    }

    static func deleteSecrets(for profile: VPNProfile) {
        for suffix in ["config", "user", "pass"] { Keychain.delete("vpn.\(profile.id.uuidString).\(suffix)") }
    }

    /// Builds a profile from a dropped-in file, sniffing the engine from its content.
    static func importProfile(named filename: String, text: String) throws -> VPNProfile {
        let base = (filename as NSString).deletingPathExtension
        if text.contains("[Interface]") && text.contains("[Peer]") {
            let endpoint = text.split(whereSeparator: \.isNewline)
                .first { $0.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("endpoint") }?
                .split(separator: "=", maxSplits: 1).last.map { $0.trimmingCharacters(in: .whitespaces) }
            return VPNProfile(name: base, engine: .wireguard, server: endpoint)
        }
        if text.contains("remote ") && (text.contains("<ca>") || text.contains("\nca ")) {
            let remote = text.split(whereSeparator: \.isNewline)
                .first { $0.trimmingCharacters(in: .whitespaces).hasPrefix("remote ") }?
                .split(separator: " ").dropFirst().first.map(String.init)
            let needsCreds = text.split(whereSeparator: \.isNewline)
                .contains { $0.trimmingCharacters(in: .whitespaces) == "auth-user-pass" }
            return VPNProfile(name: base, engine: .openvpn, server: remote, needsCredentials: needsCreds)
        }
        throw ImportError.unrecognized
    }

    enum ImportError: LocalizedError {
        case unrecognized
        var errorDescription: String? { "This file isn't a WireGuard (.conf) or OpenVPN (.ovpn) profile." }
    }
}

/// NordVPN's public, unauthenticated server directory and per-server OpenVPN
/// profiles: the same files their "manual setup" page hands out.
enum NordVPN {
    struct Server: Decodable {
        let hostname: String
        let name: String
        let load: Int
        let locations: [Location]
        struct Location: Decodable { let country: Country }
        struct Country: Decodable { let name: String; let city: City? }
        struct City: Decodable { let name: String }
        var locationText: String {
            guard let country = locations.first?.country else { return "" }
            if let city = country.city?.name { return "\(city), \(country.name)" }
            return country.name
        }
    }
    struct Country: Decodable, Identifiable, Hashable {
        let id: Int
        let name: String
        let code: String
        let cities: [City]
        struct City: Decodable, Identifiable, Hashable { let id: Int; let name: String }
    }

    enum NordError: LocalizedError {
        case noServer
        case badResponse
        var errorDescription: String? {
            switch self {
            case .noServer: return "NordVPN returned no OpenVPN server for that choice."
            case .badResponse: return "NordVPN's server directory did not respond as expected."
            }
        }
    }

    static func countries() async throws -> [Country] {
        let url = URL(string: "https://api.nordvpn.com/v1/servers/countries")!
        let (data, _) = try await URLSession.shared.data(from: url)
        return try JSONDecoder().decode([Country].self, from: data).sorted { $0.name < $1.name }
    }

    /// Nord's own "recommended" pick: lowest load near you, optionally within a country.
    static func recommend(countryID: Int?, cityID: Int? = nil, tcp: Bool) async throws -> Server {
        var components = URLComponents(string: "https://api.nordvpn.com/v1/servers/recommendations")!
        var items = [
            URLQueryItem(name: "filters[servers_technologies][identifier]", value: tcp ? "openvpn_tcp" : "openvpn_udp"),
            URLQueryItem(name: "limit", value: "1"),
        ]
        if let countryID { items.append(URLQueryItem(name: "filters[country_id]", value: String(countryID))) }
        if let cityID { items.append(URLQueryItem(name: "filters[city_id]", value: String(cityID))) }
        components.queryItems = items
        let (data, response) = try await URLSession.shared.data(from: components.url!)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw NordError.badResponse }
        guard let server = try JSONDecoder().decode([Server].self, from: data).first else { throw NordError.noServer }
        return server
    }

    static func profileText(for server: Server, tcp: Bool) async throws -> String {
        let proto = tcp ? "tcp" : "udp"
        let url = URL(string: "https://downloads.nordcdn.com/configs/files/ovpn_\(proto)/servers/\(server.hostname).\(proto).ovpn")!
        let (data, response) = try await URLSession.shared.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200, let text = String(data: data, encoding: .utf8), text.contains("<ca>") else {
            throw NordError.badResponse
        }
        return text
    }
}
