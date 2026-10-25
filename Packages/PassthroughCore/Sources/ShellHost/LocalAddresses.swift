#if os(macOS)
import Darwin
import Foundation
import PassthroughCore

/// The Mac's own addresses, as told to a phone granted a shell.
public enum LocalAddresses {
    /// One address of an interface that is up, with what decides whether its
    /// network is one the Mac is really on.
    struct Interface: Equatable {
        var flags: Int32
        var address: String
        /// Leading one bits of the netmask; nil when it has none.
        var prefixLength: Int?
        /// The BSD name ("en0", "utun4").
        var name = ""

        /// What the address policy needs to know of it.
        var policyAddress: ShellAddressPolicy.LocalAddress {
            .init(address: address, interface: name, isPointToPoint: flags & Int32(IFF_POINTOPOINT) != 0)
        }
    }

    /// Every IPv4 and IPv6 address on an interface that is up, numeric, in
    /// interface order (IPv6 link-local ones keep their `%scope`).
    public static func all() -> [String] { interfaces().map(\.address) }

    /// `all()` with the interface each address is on, for `ShellAddressPolicy`.
    public static func withInterfaces() -> [ShellAddressPolicy.LocalAddress] { interfaces().map(\.policyAddress) }

    static func interfaces() -> [Interface] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }
        var result: [Interface] = []
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(entry.pointee.ifa_flags)
            guard flags & IFF_UP != 0, let address = entry.pointee.ifa_addr else { continue }
            let family = Int32(address.pointee.sa_family)
            guard family == AF_INET || family == AF_INET6 else { continue }
            let length = socklen_t(family == AF_INET ? MemoryLayout<sockaddr_in>.size : MemoryLayout<sockaddr_in6>.size)
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, length, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            result.append(Interface(flags: flags, address: String(cString: host),
                                    prefixLength: prefixLength(of: entry.pointee.ifa_netmask),
                                    name: String(cString: entry.pointee.ifa_name)))
        }
        return result
    }

    private static func prefixLength(of mask: UnsafeMutablePointer<sockaddr>?) -> Int? {
        guard let mask else { return nil }
        switch Int32(mask.pointee.sa_family) {
        case AF_INET6:
            return mask.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { pointer in
                withUnsafeBytes(of: pointer.pointee.sin6_addr) { $0.reduce(0) { $0 + $1.nonzeroBitCount } }
            }
        case AF_INET:
            return mask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { pointer in
                pointer.pointee.sin_addr.s_addr.nonzeroBitCount
            }
        default:
            // BSD netmasks may carry a shortened sa_family/len; treat as unknown.
            return nil
        }
    }

    /// The ones worth dialing from a phone (`ShellAddressPolicy.advertisable`).
    public static func advertisable() -> [String] { ShellAddressPolicy.advertisable(all()) }

    /// The /64s of the Mac's global IPv6 addresses on real links: networks it is on itself.
    public static func onLinkPrefixes() -> Set<Data> { onLinkPrefixes(of: interfaces()) }

    /// Point-to-point and loopback interfaces (VPN tunnels such as utun and
    /// ipsec, including this app's own WireGuard/OpenVPN layer) are not
    /// on-link, and neither is an address with a netmask longer than /64 (a
    /// host route or a /80 carve-out): its /64 is not shared with neighbours.
    /// Peers are still compared at /64.
    static func onLinkPrefixes(of interfaces: [Interface]) -> Set<Data> {
        let onLink = interfaces.filter {
            $0.flags & (Int32(IFF_POINTOPOINT) | Int32(IFF_LOOPBACK)) == 0
                && ($0.prefixLength.map { $0 <= 64 } ?? false)
        }
        return ShellAddressPolicy.onLinkPrefixes(of: onLink.map(\.address))
    }
}
#endif
