import Foundation

/// The VPN kill switch's packet filter (pf) rules.
///
/// Routes alone can't hold the line: the kill switch's reject routes and the
/// VPN's /2 routes win only by prefix length, so any longer route the network
/// pushes (DHCP option 121, IPv6 route information, a /8 netmask) carries
/// traffic past them in the clear. pf filters by where a packet leaves and
/// where it goes, whatever the routing table says: out through the VPN's
/// interface, to the VPN server, or to the local network, else dropped.
///
/// Where the rules live: macOS's /etc/pf.conf, loaded at boot by launchd,
/// evaluates only the anchors under "com.apple/*" (`anchor "com.apple/*"`),
/// so a top-level anchor of our own would never be looked at, and loading a
/// main ruleset of our own would replace Apple's and any other tool's rules.
/// Like other third-party pf users, the rules go in a child anchor of
/// com.apple, under a name that is plainly ours. Children are evaluated in
/// name order and ours starts "100.", before Apple's "200.AirDrop" and
/// "250.ApplicationFirewall", so its `quick` rules decide first. Every rule
/// is stateless (`no state`): a connection already open when the kill
/// switch engaged is judged packet by packet like a new one.
public enum KillSwitchRules {
    public struct Endpoint: Equatable, Sendable {
        public var ip: String
        public var port: Int
        public init(ip: String, port: Int) { self.ip = ip; self.port = port }
    }

    public struct Input: Equatable, Sendable {
        /// The VPN's interface while it is connected; nil while it is down.
        public var vpnInterface: String?
        /// The VPN servers: their encrypted flow leaves on whatever
        /// interface reaches them (the passthrough utun, Wi-Fi).
        public var endpoints: [Endpoint] = []
        /// Directly connected networks, when the local network is allowed.
        public var localSubnets: [CIDR] = []
        /// Tailscale's interfaces (they hold an address in its ranges).
        public var tailscaleInterfaces: [String] = []
        /// IPv6 may leave outside the VPN: Block IPv6 is off and the VPN
        /// carries none (the user chose that bypass).
        public var allowIPv6Bypass = false

        public init(vpnInterface: String? = nil, endpoints: [Endpoint] = [], localSubnets: [CIDR] = [],
                    tailscaleInterfaces: [String] = [], allowIPv6Bypass: Bool = false) {
            self.vpnInterface = vpnInterface
            self.endpoints = endpoints
            self.localSubnets = localSubnets
            self.tailscaleInterfaces = tailscaleInterfaces
            self.allowIPv6Bypass = allowIPv6Bypass
        }
    }

    public static let tailscaleRanges = [CIDR("100.64.0.0/10")!, CIDR("fd7a:115c:a1e0::/48")!]

    /// "com.apple/100.<identifier>.killswitch"; a shorter fixed name if the
    /// identifier would overflow pf's 64-byte anchor name.
    public static func anchor(identifier: String) -> String {
        let name = "100.\(identifier).killswitch"
        return "com.apple/" + (name.utf8.count < 64 && isSafeName(identifier) ? name : "100.passthrough.killswitch")
    }

    /// The ruleset for `pfctl -a <anchor> -f -`. Anything malformed in the
    /// input (it comes from the kernel and from config files) is left out
    /// rather than spliced in.
    public static func ruleset(_ input: Input) -> String {
        var rules = [
            "# Passthrough VPN kill switch: everything this Mac sends goes into the VPN,",
            "# to the VPN server, or to the local network; the rest is dropped.",
            "pass quick on lo0 all no state",
        ]
        if let vpn = input.vpnInterface, isInterfaceName(vpn) {
            rules.append("pass out quick on \(vpn) all no state")
        }
        var seen = Set<String>()
        for endpoint in input.endpoints where XPCInput.isIPAddress(endpoint.ip) && (1...65535).contains(endpoint.port) {
            guard seen.insert("\(endpoint.ip) \(endpoint.port)").inserted else { continue }
            rules.append("pass out quick proto { tcp udp } to \(endpoint.ip) port \(endpoint.port) no state")
        }
        rules += [
            // Getting an address at all: DHCP, DHCPv6, and IPv6 neighbour
            // and router discovery (never forwarded past the link).
            "pass out quick inet proto udp from any port 68 to any port 67 no state",
            "pass out quick inet6 proto udp from any port 546 to any port 547 no state",
            "pass out quick inet6 proto icmp6 all icmp6-type { neighbrsol, neighbradv, routersol } no state",
            // Link-local addresses and link-scoped multicast (mDNS, IGMP/MLD)
            // stay on the link by definition: AirDrop, Bonjour, peer-to-peer.
            "pass out quick inet to 169.254.0.0/16 no state",
            "pass out quick inet6 to fe80::/10 no state",
            "pass out quick inet to 224.0.0.0/24 no state",
            "pass out quick inet6 to ff02::/16 no state",
        ]
        // DNS goes into the VPN, never to a resolver on the local network
        // (a router, or one Tailscale still forwards to), where it would
        // leave in the clear; everything else local stays reachable.
        for subnet in input.localSubnets where subnet.prefixLength > 0 {
            rules.append("block drop out quick \(subnet.isIPv6 ? "inet6" : "inet") proto { tcp udp } to \(subnet) port { 53 853 }")
        }
        for subnet in input.localSubnets where subnet.prefixLength > 0 {
            rules.append("pass out quick \(subnet.isIPv6 ? "inet6" : "inet") to \(subnet) no state")
        }
        for interface in input.tailscaleInterfaces where isInterfaceName(interface) && interface != input.vpnInterface {
            rules.append("pass out quick on \(interface) all no state")
        }
        for range in tailscaleRanges {
            rules.append("pass out quick \(range.isIPv6 ? "inet6" : "inet") to \(range) no state")
        }
        if input.allowIPv6Bypass { rules.append("pass out quick inet6 all no state") }
        rules.append("block drop out quick all")
        return rules.joined(separator: "\n") + "\n"
    }

    /// A BSD interface name ("en0", "utun12", "bridge100").
    public static func isInterfaceName(_ s: String) -> Bool {
        !s.isEmpty && s.count <= 15 && s.first!.isLetter && s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }

    private static func isSafeName(_ s: String) -> Bool {
        !s.isEmpty && s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") }
    }
}

/// What pfctl prints, as far as the kill switch needs to read it.
public enum PFOutput {
    /// `pfctl -E` prints "Token : 12345…" (on stderr) for the reference it took.
    public static func token(fromEnable output: String) -> String? {
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2, parts[0] == "Token", !parts[1].isEmpty, parts[1].allSatisfy(\.isNumber) { return parts[1] }
        }
        return nil
    }

    /// `pfctl -s info`'s first line: "Status: Enabled for …" or "Status: Disabled …".
    public static func isEnabled(info output: String) -> Bool? {
        guard let line = output.split(separator: "\n").first(where: { $0.hasPrefix("Status:") }) else { return nil }
        if line.contains("Enabled") { return true }
        if line.contains("Disabled") { return false }
        return nil
    }

    /// Whether the main ruleset (`pfctl -s rules`) evaluates `anchor`: it has
    /// an `anchor "<parent>/*"` rule for the anchor's parent.
    public static func evaluates(anchor: String, mainRules output: String) -> Bool {
        let parent = (anchor as NSString).deletingLastPathComponent
        return output.split(separator: "\n").contains { $0.hasPrefix("anchor \"\(parent)/*\"") }
    }
}

/// The kill switch's state that must outlive the app and the helper, in the
/// helper's root-only state directory:
///
/// * `vpn-wanted`: the VPN is on with its kill switch, and nobody turned it
///   off. While it exists the block stays: when the app goes away without
///   turning the VPN off (it crashed, or was killed), and when a helper
///   starts after one crashed. Turning the VPN off removes it.
/// * `vpn-endpoints.json`: the VPN servers' last resolved addresses, so a
///   reconnect under the block needs no DNS outside the tunnel.
/// * `pf.token`: the pf enable reference the kill switch holds, so it can be
///   released (`pfctl -X`) by a later helper, and whether pf was already on
///   before (then it stays on).
public struct KillSwitchStateStore {
    public let directory: String
    public init(directory: String) { self.directory = directory }

    var wantedPath: String { directory + "/vpn-wanted" }
    var endpointsPath: String { directory + "/vpn-endpoints.json" }
    var tokenPath: String { directory + "/pf.token" }

    public struct Wanted: Codable, Equatable {
        public var allowLocalNetwork: Bool
        public var since: Date
        public init(allowLocalNetwork: Bool, since: Date = Date()) { self.allowLocalNetwork = allowLocalNetwork; self.since = since }
    }

    public struct Token: Codable, Equatable {
        public var token: String?
        /// pf was enabled before the kill switch took its reference.
        public var wasEnabled: Bool
        public init(token: String?, wasEnabled: Bool) { self.token = token; self.wasEnabled = wasEnabled }
    }

    public var isWanted: Bool { FileManager.default.fileExists(atPath: wantedPath) }
    public var wanted: Wanted? { read(wantedPath) }
    public func setWanted(_ value: Wanted) throws { try write(value, to: wantedPath) }
    public func clearWanted() { unlink(wantedPath) }

    public var endpoints: [String: [String]] {
        (read(endpointsPath) as [String: [String]]?)?.filter { !$0.value.isEmpty && $0.value.allSatisfy(XPCInput.isIPAddress) } ?? [:]
    }
    public func setEndpoints(_ value: [String: [String]]) throws { try write(value, to: endpointsPath) }

    public var token: Token? { read(tokenPath) }
    public func setToken(_ value: Token) throws { try write(value, to: tokenPath) }
    public func clearToken() { unlink(tokenPath) }

    private func read<T: Decodable>(_ path: String) -> T? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    /// Written whole (rename into place) and readable by root alone.
    private func write<T: Encodable>(_ value: T, to path: String) throws {
        let data = try JSONEncoder().encode(value)
        let temporary = path + ".tmp"
        unlink(temporary)
        guard FileManager.default.createFile(atPath: temporary, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: temporary])
        }
        guard rename(temporary, path) == 0 else { throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: path]) }
    }
}

/// What happens to the kill switch at the moments nobody explicitly turned
/// the VPN off.
public enum KillSwitchHold {
    public enum Decision: Equatable {
        /// The engine stops but the block stays (routes and pf) until the
        /// VPN reconnects or is turned off.
        case hold
        /// Everything goes: engine, routes, pf, the state file.
        case lift
    }

    /// The app that started the VPN disconnected without turning it off
    /// (it crashed or was killed; a clean quit turns it off first).
    public static func appGone(killSwitch: Bool) -> Decision { killSwitch ? .hold : .lift }

    /// A helper starting up: a predecessor that crashed with the VPN on left `vpn-wanted`.
    public static func helperStart(wanted: Bool) -> Decision { wanted ? .hold : .lift }

    /// A start that failed: a block that was already held (a reconnect
    /// after a crash) stays; a fresh start leaves nothing behind.
    public static func failedStart(wasHeld: Bool) -> Decision { wasHeld ? .hold : .lift }
}
