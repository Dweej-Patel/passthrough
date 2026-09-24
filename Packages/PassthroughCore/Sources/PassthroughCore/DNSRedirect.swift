import Foundation
import Network
import CResolv

/// DNS the Mac aims at a private address (typically its Wi-Fi router, which
/// Tailscale or DHCP left as the resolver) can never be answered through the
/// phone. Instead of refusing it, the phone forwards the query unchanged to
/// the DNS server of its own network (the carrier's, or its Wi-Fi's), falling
/// back to `fallback` when it knows none. Replies go back under the address
/// the Mac asked, so nothing on the Mac notices. Mirrors DnsRedirect.kt.
public enum DNSRedirect {
    public static let port: UInt16 = 53
    public static let fallback = "1.1.1.1"

    /// A DNS query to a private/local IP address, which would otherwise be refused.
    public static func applies(to address: SOCKS5.Address) -> Bool {
        guard address.port.rawValue == port, address.isLocalOnly else { return false }
        switch address.host {
        case .ipv4, .ipv6: return true
        default: return false
        }
    }

    /// The server to use: the first real one the phone's network provides, else `fallback`.
    public static func server(from system: [String]) -> String {
        system.first { candidate in
            let bare = candidate.split(separator: "%").first.map(String.init) ?? candidate
            if let v4 = IPv4Address(bare) { return !v4.isLoopback && v4 != .any }
            if let v6 = IPv6Address(bare) { return !v6.isLoopback && v6 != .any }
            return false
        } ?? fallback
    }

    /// The DNS servers the phone's resolver uses right now, in order.
    public static func systemServers() -> [String] {
        var buffer = [CChar](repeating: 0, count: 1024)
        guard pt_system_dns_servers(&buffer, Int32(buffer.count)) > 0 else { return [] }
        return String(cString: buffer).split(separator: ",").map(String.init)
    }

    /// Where to send a redirected query from this phone, right now.
    static func target() -> NWEndpoint {
        .hostPort(host: NWEndpoint.Host(server(from: systemServers())), port: NWEndpoint.Port(rawValue: port)!)
    }
}
