import Foundation

/// An IPv4 or IPv6 prefix.
public struct CIDR: Equatable, Hashable, Sendable, CustomStringConvertible {
    public let bytes: [UInt8]
    public let prefixLength: Int
    public var isIPv6: Bool { bytes.count == 16 }

    /// The network `address`/`prefixLength` belongs to (host bits cleared).
    public init?(address: String, prefixLength: Int) {
        guard let raw = CIDR.parse(address), (0...(raw.count * 8)).contains(prefixLength) else { return nil }
        bytes = CIDR.masked(raw, prefixLength)
        self.prefixLength = prefixLength
    }

    /// "a.b.c.d/n" or "x::/n"; a bare address is a host prefix.
    public init?(_ text: String) {
        let parts = text.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard let raw = CIDR.parse(parts[0]) else { return nil }
        let length = parts.count == 2 ? Int(parts[1]) : raw.count * 8
        guard let length else { return nil }
        self.init(address: parts[0], prefixLength: length)
    }

    public func contains(_ address: String) -> Bool {
        guard let raw = CIDR.parse(address), raw.count == bytes.count else { return false }
        return CIDR.masked(raw, prefixLength) == bytes
    }

    public func contains(_ other: CIDR) -> Bool {
        other.bytes.count == bytes.count && other.prefixLength >= prefixLength && CIDR.masked(other.bytes, prefixLength) == bytes
    }

    public var address: String { CIDR.format(bytes) }
    public var description: String { "\(address)/\(prefixLength)" }

    /// Numeric IPv4 or IPv6 only (a zone like `%en0` is dropped first).
    static func parse(_ text: String) -> [UInt8]? {
        let plain = text.split(separator: "%", maxSplits: 1).first.map(String.init) ?? text
        var v4 = in_addr(), v6 = in6_addr()
        if inet_pton(AF_INET, plain, &v4) == 1 { return withUnsafeBytes(of: &v4) { Array($0) } }
        if inet_pton(AF_INET6, plain, &v6) == 1 { return withUnsafeBytes(of: &v6) { Array($0) } }
        return nil
    }

    static func masked(_ bytes: [UInt8], _ length: Int) -> [UInt8] {
        bytes.enumerated().map { index, byte in
            let bits = max(0, min(8, length - index * 8))
            return bits == 8 ? byte : byte & UInt8(truncatingIfNeeded: 0xFF00 >> bits)
        }
    }

    static func format(_ bytes: [UInt8]) -> String {
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        let family = bytes.count == 16 ? AF_INET6 : AF_INET
        _ = bytes.withUnsafeBytes { inet_ntop(family, $0.baseAddress, &buffer, socklen_t(buffer.count)) }
        return String(cString: buffer)
    }

    /// Never routed beyond this network or this Mac: private, carrier-grade
    /// NAT, link-local, loopback, multicast, broadcast and ULA space.
    public static let nonPublic: [CIDR] = [
        "0.0.0.0/8", "10.0.0.0/8", "100.64.0.0/10", "127.0.0.0/8", "169.254.0.0/16", "172.16.0.0/12",
        "192.168.0.0/16", "224.0.0.0/4", "240.0.0.0/4",
        "::1/128", "::/128", "fc00::/7", "fe80::/10", "ff00::/8",
    ].compactMap { CIDR($0) }

    public var isPublic: Bool { !CIDR.nonPublic.contains { $0.contains(self) } }
}

/// The kernel routing table as `netstat -rn` prints it.
public enum RouteNames {
    /// netstat prints IPv4 prefixes classfully abbreviated: trailing zero
    /// octets dropped beyond the class's network part ("0.0.0.0/2" is "0/2",
    /// "128.0.0.0/3" is "128.0/3", "192.0.0.0/3" is "192.0.0/3").
    public static func netstat(_ prefix: String) -> String {
        let parts = prefix.split(separator: "/", maxSplits: 1)
        let octets = parts[0].split(separator: ".")
        guard parts.count == 2, octets.count == 4, let first = Int(octets[0]) else { return prefix }
        let keep = first < 128 ? 1 : first < 192 ? 2 : 3
        var shown = Array(octets)
        while shown.count > keep, shown.last == "0" { shown.removeLast() }
        return shown.joined(separator: ".") + "/" + parts[1]
    }
}

/// One line of `netstat -rn`.
public struct RouteEntry: Equatable, Sendable {
    /// As printed ("default", "128.0/3", "192.168.1", "fe80::%en0/64").
    public var destination: String
    public var gateway: String
    public var flags: String
    public var interface: String

    public init(destination: String, gateway: String, flags: String, interface: String) {
        self.destination = destination; self.gateway = gateway; self.flags = flags; self.interface = interface
    }

    public var isReject: Bool { flags.contains("R") }
    /// Bound to one interface (RTF_IFSCOPE): only for sockets bound there.
    public var isScoped: Bool { flags.contains("I") }

    /// The prefix this line describes; nil for "default" or anything unparsable.
    /// An IPv4 name without a length has its class's natural mask (a host
    /// route, flag H, is /32): netstat leaves the length out exactly then.
    public var prefix: CIDR? {
        guard destination != "default" else { return nil }
        let parts = destination.split(separator: "/", maxSplits: 1).map(String.init)
        var address = parts[0].split(separator: "%", maxSplits: 1).first.map(String.init) ?? parts[0]
        let v6 = address.contains(":")
        var length = parts.count == 2 ? Int(parts[1]) : nil
        if !v6 {
            var octets = address.split(separator: ".").map(String.init)
            guard (1...4).contains(octets.count), let first = Int(octets[0]) else { return nil }
            if length == nil {
                length = flags.contains("H") ? 32 : first < 128 ? 8 : first < 192 ? 16 : first < 224 ? 24 : 32
            }
            while octets.count < 4 { octets.append("0") }
            address = octets.joined(separator: ".")
        } else if length == nil {
            length = 128
        }
        return length.flatMap { CIDR(address: address, prefixLength: $0) }
    }

    /// Every route line of a `netstat -rn [-f inet|inet6]` output.
    public static func parse(_ output: String) -> [RouteEntry] {
        output.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard fields.count >= 4, fields[0] != "Destination", fields[0] != "Routing", fields[0] != "Internet:",
                  fields[0] != "Internet6:" else { return nil }
            return RouteEntry(destination: fields[0], gateway: fields[1], flags: fields[2], interface: fields[3])
        }
    }

    /// The unscoped route for each destination (what unbound sockets use),
    /// keyed by the destination as netstat prints it.
    public static func unscoped(_ entries: [RouteEntry]) -> [String: RouteEntry] {
        var table: [String: RouteEntry] = [:]
        for entry in entries where !entry.isScoped && table[entry.destination] == nil { table[entry.destination] = entry }
        return table
    }
}

/// The kill switch's reject routes, and which routes at those prefixes are ours.
public enum RejectRoutes {
    public static func loopback(v6: Bool) -> String { v6 ? "::1" : "127.0.0.1" }

    /// A reject route to loopback: the only kind this app adds at its
    /// kill-switch and guard prefixes. Anything else there is someone else's.
    public static func isOurs(_ entry: RouteEntry?, v6: Bool) -> Bool {
        guard let entry else { return false }
        return entry.isReject && entry.gateway == loopback(v6: v6)
    }

    public enum Install: Equatable {
        /// Nothing there yet.
        case add
        /// Already our reject route.
        case keep
        /// Something else holds the prefix (a network pushing routes, say):
        /// it is deleted and the reject route added fresh (XNU ignores
        /// -reject on `route change`).
        case replace(RouteEntry)
    }

    public static func install(over existing: RouteEntry?, v6: Bool) -> Install {
        guard let existing else { return .add }
        return isOurs(existing, v6: v6) ? .keep : .replace(existing)
    }

    /// Only ever delete our own: a route to loopback at one of our prefixes,
    /// whether or not its reject flag took (a reject route that became a
    /// plain one, as `route change` leaves it, is ours too, and must not keep
    /// the Mac blocked). Anyone else's route is left alone.
    public static func mayDelete(_ existing: RouteEntry?, v6: Bool) -> Bool {
        guard let existing else { return false }
        return existing.gateway == loopback(v6: v6) && (existing.isReject || existing.interface.hasPrefix("lo"))
    }
}

/// Routes more specific than the VPN's /2s that send public addresses
/// somewhere other than the VPN: a network pushing routes around it (DHCP
/// option 121, "TunnelVision"; IPv6 router advertisements' route
/// information), or claiming public addresses as directly connected (a
/// hostile netmask, TunnelCrack's "LocalNet"). Longest prefix wins, so they
/// would carry that traffic in the clear even while the VPN is connected;
/// the kill switch's packet filter drops it, and this is how it is noticed.
public enum ForeignRoutes {
    /// - Parameters:
    ///   - vpnInterface: the VPN's interface; routes into it are fine.
    ///   - ownInterfaces: interfaces whose routes are someone's on purpose
    ///     (Tailscale's, for one).
    ///   - ownHosts: our endpoint host routes.
    public static func find(_ entries: [RouteEntry], vpnInterface: String?, ownInterfaces: Set<String> = [],
                            ownHosts: Set<String> = []) -> [RouteEntry] {
        entries.filter { entry in
            guard let prefix = entry.prefix, prefix.prefixLength > 2, prefix.isPublic,
                  !entry.isReject, entry.interface != vpnInterface, !entry.interface.hasPrefix("lo"),
                  !ownInterfaces.contains(entry.interface),
                  // Neighbours are the network itself; its own route says enough.
                  !entry.flags.contains("L"), !entry.flags.contains("W")
            else { return false }
            if entry.gateway.hasPrefix("link#") && !isHostileConnected(entry, prefix) { return false }
            return !ownHosts.contains(prefix.address) || prefix.prefixLength != (prefix.isIPv6 ? 128 : 32)
        }
    }

    /// A directly connected network that claims public addresses: any public
    /// IPv4 one, and an IPv6 one wider than the usual /64 (a LAN's own
    /// global /64 is how IPv6 normally works, and its devices are reachable
    /// only through the VPN anyway, as `LocalNetworks.subnets` keeps public
    /// space out). Scoped copies are left to the unscoped route.
    static func isHostileConnected(_ entry: RouteEntry, _ prefix: CIDR) -> Bool {
        !entry.isScoped && (!prefix.isIPv6 || prefix.prefixLength < 64)
    }
}
