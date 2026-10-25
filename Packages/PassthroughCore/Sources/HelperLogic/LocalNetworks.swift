#if os(macOS)
import Darwin
import Foundation

/// The networks this Mac is directly on, for the kill switch's "Allow local
/// network" (LAN devices, AirPlay, the remote shell's local and hotspot
/// paths) and for the phone dialing in over the wireless link, which the
/// kill switch lets through either way (`KillSwitchRules.PhoneLink`).
public enum LocalNetworks {
    public struct Address: Equatable, Sendable {
        public var interface: String
        public var address: String
        public var prefixLength: Int
        public var isUp: Bool
        public var isLoopback: Bool
        public var isPointToPoint: Bool
        public init(interface: String, address: String, prefixLength: Int, isUp: Bool = true,
                    isLoopback: Bool = false, isPointToPoint: Bool = false) {
            self.interface = interface; self.address = address; self.prefixLength = prefixLength
            self.isUp = isUp; self.isLoopback = isLoopback; self.isPointToPoint = isPointToPoint
        }
    }

    /// Tunnels (the VPN's, the passthrough's, other VPN clients') carry
    /// traffic elsewhere; `feth` is the passthrough's dummy keepalive.
    static let tunnelPrefixes = ["utun", "ipsec", "ppp", "gif", "stf", "feth", "tun", "tap"]

    /// Where a directly connected network may lie for the kill switch to let
    /// it through: private IPv4 and IPv6 unique-local space (link-local is
    /// let through on its own). Not carrier-grade NAT (100.64.0.0/10): a LAN handing that out is more
    /// likely posing as Tailscale than being one. A network's prefix must sit
    /// inside one of these whole, so a hostile netmask ("10.0.0.5/1") that
    /// would make half the internet "local" is refused rather than passed
    /// (TunnelCrack's LocalNet attack).
    static let localRanges = ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "fc00::/7"].compactMap { CIDR($0) }

    /// The connected subnets of up, non-tunnel interfaces, private ones only
    /// (`localRanges`). Link-local ones are left out (always allowed), as
    /// are host-only prefixes.
    public static func subnets(_ addresses: [Address]) -> [CIDR] {
        var result: [CIDR] = []
        for a in addresses where a.isUp && !a.isLoopback && !a.isPointToPoint
            && !tunnelPrefixes.contains(where: { a.interface.hasPrefix($0) }) {
            guard let subnet = CIDR(address: a.address, prefixLength: a.prefixLength),
                  subnet.prefixLength > 0, subnet.prefixLength < (subnet.isIPv6 ? 128 : 32),
                  !(subnet.isIPv6 && CIDR("fe80::/10")!.contains(subnet)),
                  localRanges.contains(where: { $0.contains(subnet) }), !result.contains(subnet) else { continue }
            result.append(subnet)
        }
        return result
    }

    /// Tailscale's interfaces: up, point-to-point `utun`s holding an address
    /// in its ranges. Anything else with such an address (a Wi-Fi network
    /// handing out carrier-grade NAT addresses, plus routes) is not Tailscale,
    /// and passing everything it carries would leak in the clear. `excluding`
    /// names interfaces that never count: the VPN's underlay, which would
    /// otherwise carry everything around the VPN.
    public static func tailscaleInterfaces(_ addresses: [Address], excluding: Set<String> = []) -> [String] {
        var names: [String] = []
        for a in addresses where a.isUp && a.isPointToPoint && a.interface.hasPrefix("utun") && !excluding.contains(a.interface)
            && KillSwitchRules.tailscaleRanges.contains(where: { $0.contains(a.address) }) && !names.contains(a.interface) {
            names.append(a.interface)
        }
        return names
    }

    /// Every IPv4 and IPv6 address on this Mac's interfaces right now.
    public static func current() -> [Address] {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(first) }
        var result: [Address] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor?.pointee {
            defer { cursor = entry.ifa_next }
            guard let addr = entry.ifa_addr, let mask = entry.ifa_netmask else { continue }
            let family = Int32(addr.pointee.sa_family)
            guard family == AF_INET || family == AF_INET6 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let maskBytes: [UInt8] = family == AF_INET
                ? mask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { withUnsafeBytes(of: $0.pointee.sin_addr) { Array($0) } }
                : mask.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { withUnsafeBytes(of: $0.pointee.sin6_addr) { Array($0) } }
            let flags = Int32(entry.ifa_flags)
            result.append(Address(interface: String(cString: entry.ifa_name), address: String(cString: host),
                                  prefixLength: maskBytes.reduce(0) { $0 + $1.nonzeroBitCount },
                                  isUp: flags & IFF_UP != 0, isLoopback: flags & IFF_LOOPBACK != 0,
                                  isPointToPoint: flags & IFF_POINTOPOINT != 0))
        }
        return result
    }
}
#endif
