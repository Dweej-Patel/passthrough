import Foundation

/// A parsed wg-quick style .conf. Only the keys the helper configures over
/// wireguard-go's UAPI are read; wg-quick extras (PostUp, Table, ...) are
/// ignored, never executed. Keys are kept as hex, the form UAPI expects.
public struct WireGuardConfig {
    public struct Peer {
        public var publicKeyHex: String
        public var presharedKeyHex: String?
        public var endpointHost: String
        public var endpointPort: Int
        public var allowedIPs: [String]
        public var keepalive: Int?
    }

    public enum ConfigError: LocalizedError, Equatable {
        case invalid(String)
        public var errorDescription: String? {
            switch self {
            case .invalid(let why): return why
            }
        }
    }

    public private(set) var privateKeyHex = ""
    public private(set) var addresses: [String] = []
    public private(set) var dns: [String] = []
    public private(set) var mtu: Int?
    public private(set) var listenPort: Int?
    public private(set) var peers: [Peer] = []

    public var endpoints: [(host: String, port: Int)] { peers.map { ($0.endpointHost, $0.endpointPort) } }

    public init(text: String) throws {
        var section = ""
        var peer: Peer?
        func flushPeer() { if let p = peer { peers.append(p) }; peer = nil }
        for raw in text.split(whereSeparator: \.isNewline) {
            var line = String(raw)
            if let hash = line.firstIndex(of: "#") { line = String(line[..<hash]) }
            line = line.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            if line.hasPrefix("[") {
                flushPeer()
                section = line.lowercased()
                if section == "[peer]" { peer = Peer(publicKeyHex: "", endpointHost: "", endpointPort: 0, allowedIPs: []) }
                continue
            }
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else { continue }
            let key = parts[0].lowercased(), value = parts[1]
            let list = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            switch (section, key) {
            case ("[interface]", "privatekey"): privateKeyHex = try Self.keyHex(value, "PrivateKey")
            case ("[interface]", "address"): addresses += list
            case ("[interface]", "dns"): dns += list.filter { $0.first?.isNumber == true || $0.contains(":") }
            case ("[interface]", "mtu"): mtu = Int(value)
            case ("[interface]", "listenport"): listenPort = Int(value)
            case ("[peer]", "publickey"): peer?.publicKeyHex = try Self.keyHex(value, "PublicKey")
            case ("[peer]", "presharedkey"): peer?.presharedKeyHex = try Self.keyHex(value, "PresharedKey")
            case ("[peer]", "allowedips"): peer?.allowedIPs += list
            case ("[peer]", "persistentkeepalive"): peer?.keepalive = Int(value)
            case ("[peer]", "endpoint"):
                guard let colon = value.lastIndex(of: ":"), let port = Int(value[value.index(after: colon)...]) else {
                    throw ConfigError.invalid("Endpoint must be host:port")
                }
                peer?.endpointHost = String(value[..<colon]).trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
                peer?.endpointPort = port
            default: break
            }
        }
        flushPeer()
        guard !privateKeyHex.isEmpty else { throw ConfigError.invalid("missing PrivateKey") }
        guard !addresses.isEmpty else { throw ConfigError.invalid("missing Address") }
        guard let first = peers.first, !first.publicKeyHex.isEmpty, !first.endpointHost.isEmpty else {
            throw ConfigError.invalid("missing [Peer] with PublicKey and Endpoint")
        }
    }

    private static func keyHex(_ base64: String, _ name: String) throws -> String {
        guard let data = Data(base64Encoded: base64), data.count == 32 else {
            throw ConfigError.invalid("\(name) is not a valid 32-byte base64 key")
        }
        return data.map { String(format: "%02x", $0) }.joined()
    }
}
