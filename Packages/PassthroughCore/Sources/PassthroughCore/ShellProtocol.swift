import Foundation
import Network
import CryptoKit

/// Shared pieces of the remote shell (protocol/README.md, "Remote shell").
public enum RemoteShell {
    public static let defaultPort: UInt16 = 7893
    public static let serviceType = "_passthrough-sh._tcp"
    public static let proofLabel = "passthrough-shell-v1"
    /// Most sessions a Mac keeps open at once.
    public static let maxSessions = 8
    /// Output a session remembers for a phone that attaches later.
    public static let scrollbackBytes = 1_048_576
    /// Largest piece of raw output (before base64) in one `output` line.
    public static let outputChunk = 16_384
    /// Longest line either side accepts.
    public static let lineLimit = 262_144
    /// Where macOS Screen Sharing listens; a `screen` request is relayed to it on loopback.
    public static let screenSharingPort: UInt16 = 5900

    /// HMAC-SHA256(shellKey, label ‖ nonce): the phone's answer to the Mac's challenge.
    public static func proof(shellKey: Data, nonce: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data(proofLabel.utf8) + nonce, using: SymmetricKey(data: shellKey)))
    }

    public static func proofIsValid(_ mac: Data, shellKey: Data, nonce: Data) -> Bool {
        HMAC<SHA256>.isValidAuthenticationCode(mac, authenticating: Data(proofLabel.utf8) + nonce, using: SymmetricKey(data: shellKey))
    }
}

/// Newline-delimited JSON envelope on the shell connection. Binary fields
/// (`data`, `nonce`, `mac`) are base64.
public struct ShellEnvelope: Codable, Equatable, Sendable {
    public var t: String
    public var nonce: String?
    public var phoneID: String?
    public var mac: String?
    public var session: String?
    public var data: String?
    public var cols: Int?
    public var rows: Int?
    public var sessions: [ShellSessionInfo]?
    public var history: [ShellHistoryEntry]?
    public var exitStatus: Int32?
    public var reason: String?
    public var done: Bool?
    /// macInfo: the Mac's iroh endpoint id, its home relay and the relay's
    /// token (if any), and the addresses a phone can dial it on.
    public var irohID: String?
    public var irohRelay: String?
    public var relayToken: String?
    public var addresses: [String]?

    public init(t: String) { self.t = t }

    public static let hello = "hello"
    public static let macInfo = "macInfo"
    public static let challenge = "challenge"
    public static let proof = "proof"
    public static let ready = "ready"
    public static let list = "list"
    public static let sessions = "sessions"
    public static let open = "open"
    public static let opened = "opened"
    public static let attach = "attach"
    public static let attached = "attached"
    public static let input = "input"
    public static let resize = "resize"
    public static let output = "output"
    public static let close = "close"
    public static let ended = "ended"
    public static let detached = "detached"
    public static let history = "history"
    public static let historyList = "historyList"
    public static let transcript = "transcript"
    public static let transcriptData = "transcriptData"
    public static let screen = "screen"
    public static let screenReady = "screenReady"
    /// The Mac's own H.264 stream of its screen (`ScreenVideoWire`), rather than Screen Sharing.
    public static let screenVideo = "screenVideo"
    public static let screenVideoReady = "screenVideoReady"
    public static let ping = "ping"
    public static let pong = "pong"
    public static let error = "error"

    public func encodedLine() throws -> Data {
        var data = try JSONEncoder().encode(self)
        data.append(0x0A)
        return data
    }

    public static func decode(_ line: Data) throws -> ShellEnvelope {
        try JSONDecoder().decode(ShellEnvelope.self, from: line)
    }
}

/// What a phone accepts as the Mac's iroh details (grant and `macInfo`).
public enum IrohInfo {
    public static let maxRelayLength = 256
    public static let maxTokenLength = 512
    public static let maxAddresses = 16

    /// An iroh EndpointId: 64 lowercase hex characters.
    public static func isValidID(_ id: String) -> Bool {
        id.utf8.count == 64 && id.utf8.allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66) }
    }

    /// An https URL with a host, at most 256 characters.
    public static func isValidRelay(_ relay: String) -> Bool {
        guard relay.utf8.count <= maxRelayLength, let url = URLComponents(string: relay) else { return false }
        return url.scheme?.lowercased() == "https" && !(url.host ?? "").isEmpty
    }

    public static func isValidToken(_ token: String) -> Bool { token.utf8.count <= maxTokenLength }

    /// Whether the iroh details form a usable group: a valid id, and a relay and
    /// token that are valid when present. A relay or token without an id is not usable.
    public static func areValid(id: String?, relay: String?, token: String?) -> Bool {
        guard let id, isValidID(id) else { return false }
        return (relay.map(isValidRelay) ?? true) && (token.map(isValidToken) ?? true)
    }
}

/// A live shell session as the Mac lists it. Times are Unix seconds.
public struct ShellSessionInfo: Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var startedAt: Double
    public var lastOutputAt: Double
    public var running: Bool
    public var exitStatus: Int32?

    public init(id: String, title: String, startedAt: Double, lastOutputAt: Double, running: Bool, exitStatus: Int32? = nil) {
        self.id = id; self.title = title; self.startedAt = startedAt; self.lastOutputAt = lastOutputAt
        self.running = running; self.exitStatus = exitStatus
    }
}

/// A past session in the Mac's history. Times are Unix seconds.
public struct ShellHistoryEntry: Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var phoneLabel: String
    public var startedAt: Double
    public var endedAt: Double?
    public var exitStatus: Int32?
    public var bytes: Int64
    /// The terminal's size when the session started (absent from older Macs).
    /// A transcript carries its own sizes; this is for a viewer that has none.
    public var cols: Int?
    public var rows: Int?

    public init(id: String, title: String, phoneLabel: String, startedAt: Double, endedAt: Double? = nil,
                exitStatus: Int32? = nil, bytes: Int64, cols: Int? = nil, rows: Int? = nil) {
        self.id = id; self.title = title; self.phoneLabel = phoneLabel; self.startedAt = startedAt
        self.endedAt = endedAt; self.exitStatus = exitStatus; self.bytes = bytes
        self.cols = cols; self.rows = rows
    }
}

/// Reasons the Mac gives in an `error` line.
public enum ShellError: String, Error, Sendable {
    case notAuthorized = "not_authorized"
    case tooManySessions = "too_many_sessions"
    case noSuchSession = "no_such_session"
    case badRequest = "bad_request"
    /// The phone has shell access but not screen access.
    case screenNotAllowed = "screen_not_allowed"
    /// Screen Sharing is off (nothing answers on its port).
    case screenUnavailable = "screen_unavailable"
    /// The Mac can't stream its screen itself (it lacks Screen Recording or
    /// Accessibility); Screen Sharing may still work.
    case screenVideoUnavailable = "screen_video_unavailable"
}

/// Which peers may reach the shell, and which of the Mac's addresses a phone
/// is told about: private networks, loopback, link-local and Tailscale only
/// (plus, for peers, global IPv6 addresses on the Mac's own links).
public enum ShellAddressPolicy {
    private enum Kind { case none, loopback, linkLocal, tailscale, other }

    public static func isAllowed(_ host: String) -> Bool { classify(host) != .none }

    /// `isAllowed`, or a global IPv6 peer inside `onLinkPrefixes`: the /64s
    /// the Mac has a global address in itself (`onLinkPrefixes(of:)`), so a
    /// neighbour on an IPv6-only LAN gets in and the rest of the internet does not.
    public static func isAllowed(_ host: String, onLinkPrefixes: Set<Data>) -> Bool {
        if isAllowed(host) { return true }
        guard !onLinkPrefixes.isEmpty, let prefix = globalPrefix(host) else { return false }
        return onLinkPrefixes.contains(prefix)
    }

    /// The /64 prefixes of the global unicast IPv6 addresses (2000::/3) among `addresses`.
    public static func onLinkPrefixes(of addresses: [String]) -> Set<Data> {
        Set(addresses.compactMap(globalPrefix))
    }

    /// The first 8 bytes of a global unicast IPv6 address; nil for anything else.
    private static func globalPrefix(_ host: String) -> Data? {
        guard let v6 = IPv6Address(bare(host)) else { return nil }
        let raw = v6.rawValue
        guard raw.count == 16, raw[raw.startIndex] & 0xE0 == 0x20 else { return nil }
        return Data(raw.prefix(8))
    }

    private static func bare(_ host: String) -> String {
        host.split(separator: "%", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? host
    }

    /// Allowed addresses worth dialing, deduplicated, with Tailscale last.
    public static func advertisable(_ addresses: [String]) -> [String] {
        var seen = Set<String>()
        let kept = addresses.filter { host in
            switch classify(host) {
            case .other, .tailscale: return seen.insert(host).inserted
            default: return false
            }
        }
        return kept.filter { classify($0) == .other } + kept.filter { classify($0) == .tailscale }
    }

    private static func classify(_ host: String) -> Kind {
        let bare = bare(host)
        if let v4 = IPv4Address(bare) {
            let b = [UInt8](v4.rawValue)
            switch (b[0], b[1]) {
            case (127, _): return .loopback
            case (169, 254): return .linkLocal
            case (100, 64...127): return .tailscale
            case (10, _), (192, 168): return .other
            case (172, 16...31): return .other
            default: return .none
            }
        }
        if let v6 = IPv6Address(bare) {
            let b = [UInt8](v6.rawValue)
            if b == [UInt8](repeating: 0, count: 15) + [1] { return .loopback }
            if b[0] == 0xFE && b[1] & 0xC0 == 0x80 { return .linkLocal }
            if b.starts(with: [0xFD, 0x7A, 0x11, 0x5C, 0xA1, 0xE0]) { return .tailscale }
            if b[0] & 0xFE == 0xFC { return .other }
        }
        return .none
    }
}
