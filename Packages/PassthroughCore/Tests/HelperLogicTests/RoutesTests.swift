import XCTest
@testable import HelperLogic

final class CIDRTests: XCTestCase {
    func testParsesAndMasks() {
        XCTAssertEqual(CIDR("192.168.1.81/24")?.description, "192.168.1.0/24")
        XCTAssertEqual(CIDR("10.7.0.2")?.description, "10.7.0.2/32")
        XCTAssertEqual(CIDR("2001:db8:1:2::5/64")?.description, "2001:db8:1:2::/64")
        XCTAssertEqual(CIDR("fe80::1%en0/64")?.description, "fe80::/64")
        XCTAssertEqual(CIDR("128.0.0.0/3")?.description, "128.0.0.0/3")
        XCTAssertNil(CIDR("10.0.0.0/33"))
        XCTAssertNil(CIDR("vpn.example.com/24"))
        XCTAssertNil(CIDR("10.0.0.0/x"))
    }

    func testContains() {
        let lan = CIDR("192.168.1.0/24")!
        XCTAssertTrue(lan.contains("192.168.1.200"))
        XCTAssertFalse(lan.contains("192.168.2.1"))
        XCTAssertFalse(lan.contains("::1"))
        XCTAssertTrue(CIDR("100.64.0.0/10")!.contains(CIDR("100.100.100.100/32")!))
        XCTAssertFalse(CIDR("100.64.0.0/10")!.contains(CIDR("100.0.0.0/8")!))
    }

    func testPublic() {
        XCTAssertTrue(CIDR("1.0.0.0/8")!.isPublic)
        XCTAssertTrue(CIDR("2000::/3")!.isPublic)
        XCTAssertFalse(CIDR("10.1.0.0/16")!.isPublic)
        XCTAssertFalse(CIDR("fd24:a08f:a670:1::/64")!.isPublic)
        XCTAssertFalse(CIDR("224.0.0.0/4")!.isPublic)
        XCTAssertFalse(CIDR("255.255.255.255/32")!.isPublic)
        XCTAssertFalse(CIDR("100.95.219.56/32")!.isPublic, "Tailscale's CGNAT space")
    }
}

final class RouteTableParsingTests: XCTestCase {
    /// Trimmed from a real `netstat -rn -f inet` (Wi-Fi and Tailscale up).
    private let inet = """
    Routing tables

    Internet:
    Destination        Gateway            Flags               Netif Expire
    default            192.168.1.1        UGScg                 en0
    default            link#34            UCSIg               utun9
    0/3                127.0.0.1          UGSc                  lo0
    32/3               127.0.0.1          UGRSc                 lo0
    100.64/10          link#34            UCS                 utun9
    100.95.219.56      100.95.219.56      UH                  utun9
    127                127.0.0.1          UCS                   lo0
    169.254            link#15            UCS                   en0      !
    192.168.1          link#15            UCS                   en0      !
    192.168.1.1/32     link#15            UCS                   en0      !
    224.0.0/4          link#15            UmCS                  en0      !
    224.0.0/4          link#34            UmCSI               utun9
    """

    func testParsesLines() {
        let entries = RouteEntry.parse(inet)
        XCTAssertEqual(entries.count, 12)
        XCTAssertEqual(entries.first, RouteEntry(destination: "default", gateway: "192.168.1.1", flags: "UGScg", interface: "en0"))
        XCTAssertEqual(entries.map(\.prefix?.description), [
            nil, nil, "0.0.0.0/3", "32.0.0.0/3", "100.64.0.0/10", "100.95.219.56/32", "127.0.0.0/8",
            "169.254.0.0/16", "192.168.1.0/24", "192.168.1.1/32", "224.0.0.0/4", "224.0.0.0/4",
        ])
    }

    func testUnscopedPrefersTheRouteUnboundSocketsUse() {
        let table = RouteEntry.unscoped(RouteEntry.parse(inet))
        XCTAssertEqual(table["224.0.0/4"]?.interface, "en0")
        XCTAssertEqual(table["default"]?.interface, "en0")
    }

    func testIPv6Lines() {
        let entries = RouteEntry.parse("""
        Destination                             Gateway                                 Flags               Netif Expire
        ::/3                                    ::1                                     UGRSc                 lo0
        2000::/3                                fe80::cae3:6ff:fe05:3ded%en0            UGc                   en0
        fe80::%en0/64                           link#15                                 UCI                   en0
        ::1                                     ::1                                     UHLr                  lo0
        """)
        XCTAssertEqual(entries.map(\.prefix?.description), ["::/3", "2000::/3", "fe80::/64", "::1/128"])
        XCTAssertTrue(RejectRoutes.isOurs(entries[0], v6: true))
    }

    func testNetstatNames() {
        XCTAssertEqual(RouteNames.netstat("0.0.0.0/2"), "0/2")
        XCTAssertEqual(RouteNames.netstat("128.0.0.0/3"), "128.0/3")
        XCTAssertEqual(RouteNames.netstat("192.0.0.0/3"), "192.0.0/3")
        XCTAssertEqual(RouteNames.netstat("224.0.0.0/3"), "224.0.0/3")
        XCTAssertEqual(RouteNames.netstat("2000::/3"), "2000::/3")
        // Round trip through the parser.
        for q in ["0.0.0.0/3", "32.0.0.0/3", "64.0.0.0/3", "96.0.0.0/3", "128.0.0.0/3", "160.0.0.0/3", "192.0.0.0/3", "224.0.0.0/3"] {
            XCTAssertEqual(RouteEntry(destination: RouteNames.netstat(q), gateway: "", flags: "UGSc", interface: "lo0").prefix, CIDR(q), q)
        }
    }
}

final class RejectRouteOwnershipTests: XCTestCase {
    private func entry(_ gateway: String, _ flags: String, _ interface: String = "lo0") -> RouteEntry {
        RouteEntry(destination: "32/3", gateway: gateway, flags: flags, interface: interface)
    }

    func testOnlyALoopbackRejectRouteIsOurs() {
        XCTAssertTrue(RejectRoutes.isOurs(entry("127.0.0.1", "UGRSc"), v6: false))
        XCTAssertFalse(RejectRoutes.isOurs(entry("127.0.0.1", "UGSc"), v6: false), "a plain route to loopback (a failed -reject) is not ours")
        XCTAssertFalse(RejectRoutes.isOurs(entry("192.168.1.1", "UGSc", "en0"), v6: false))
        XCTAssertFalse(RejectRoutes.isOurs(entry("10.0.0.1", "UGRSc", "en0"), v6: false), "someone else's reject route")
        XCTAssertFalse(RejectRoutes.isOurs(nil, v6: false))
    }

    func testInstallReplacesAForeignRouteAndKeepsOurs() {
        XCTAssertEqual(RejectRoutes.install(over: nil, v6: false), .add)
        XCTAssertEqual(RejectRoutes.install(over: entry("127.0.0.1", "UGRSc"), v6: false), .keep)
        let pushed = entry("192.168.1.1", "UGSc", "en0")
        XCTAssertEqual(RejectRoutes.install(over: pushed, v6: false), .replace(pushed), "a network's /3 must not survive the kill switch")
    }

    func testDeletesOnlyOurs() {
        XCTAssertTrue(RejectRoutes.mayDelete(entry("127.0.0.1", "UGRSc"), v6: false))
        XCTAssertTrue(RejectRoutes.mayDelete(entry("127.0.0.1", "UGSc"), v6: false), "ours even if the reject flag was lost: lifting must not leave it")
        XCTAssertFalse(RejectRoutes.mayDelete(entry("192.168.1.1", "UGSc", "en0"), v6: false))
        XCTAssertFalse(RejectRoutes.mayDelete(entry("10.0.0.1", "UGRSc", "en0"), v6: false), "someone else's reject route")
        XCTAssertFalse(RejectRoutes.mayDelete(nil, v6: false))
    }
}

final class ForeignRoutesTests: XCTestCase {
    func testFindsPublicRoutesAroundTheVPN() {
        let entries = RouteEntry.parse("""
        default            192.168.1.1        UGScg                 en0
        0/2                link#40            UCS                 utun12
        1                  192.168.1.1        UGSc                  en0
        8.8.8.8            192.168.1.1        UGHS                  en0
        203.0.113.7        192.168.1.1        UGHS                  en0
        64/3               127.0.0.1          UGRSc                 lo0
        10.20              192.168.1.1        UGSc                  en0
        192.168.1          link#15            UCS                   en0
        198.51.100.9       a4:1:2:3:4:5       UHLWIi                en0
        203.0.113.64/26    100.100.1.1        UGSc                utun9
        128/1              link#30            UCS                 utun3
        """)
        let found = ForeignRoutes.find(entries, vpnInterface: "utun12", ownInterfaces: ["utun9"], ownHosts: ["203.0.113.7"])
        XCTAssertEqual(found.map(\.destination), ["1", "8.8.8.8"],
                       "public, more specific than /2, not into the VPN, not ours, not a neighbour or private")
    }

    /// A hostile netmask (TunnelCrack's LocalNet) makes public addresses look
    /// directly connected: reported, like a pushed route. A LAN's own global
    /// IPv6 /64 is how IPv6 works, and is not.
    func testConnectedPublicNetworksAreReported() {
        let v4 = RouteEntry.parse("""
        8/7                link#15            UCS                   en0
        8/7                link#15            UCSI                  en0
        203.0.113          link#16            UCS                   en1
        10.0.0             link#15            UCS                   en0
        172.20.10.0/28     link#15            UCS                   en0
        100.64/10          link#17            UCS                 utun9
        203.0.113.40       link#16            UHLWIi                en1
        """)
        XCTAssertEqual(ForeignRoutes.find(v4, vpnInterface: "utun12", ownInterfaces: ["utun9"]).map(\.destination), ["8/7", "203.0.113"],
                       "public, once each; private, Tailscale's and neighbours are not")
        let v6 = RouteEntry.parse("""
        2001:db8:1::/64                         link#15                                 UC                    en0
        2000::/3                                link#15                                 UC                    en0
        fd24:a08f:a670:1::/64                   link#15                                 UC                    en0
        """)
        XCTAssertEqual(ForeignRoutes.find(v6, vpnInterface: "utun12").map(\.destination), ["2000::/3"])
    }

    func testIPv6RouteInformation() {
        let entries = RouteEntry.parse("""
        2000::/3                                fe80::1%en0                             UGc                   en0
        fd24:a08f:a670:1::/64                   fe80::cae3:6ff:fe05:3ded%en0            UGc                   en0
        ::/2                                    link#40                                 UCS                 utun12
        """)
        XCTAssertEqual(ForeignRoutes.find(entries, vpnInterface: "utun12").map(\.destination), ["2000::/3"])
    }
}
