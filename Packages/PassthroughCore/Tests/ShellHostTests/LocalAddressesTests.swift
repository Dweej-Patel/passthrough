#if os(macOS)
import XCTest
import PassthroughCore
@testable import ShellHost

final class LocalAddressesTests: XCTestCase {
    func testAllIncludesLoopback() {
        let all = LocalAddresses.all()
        XCTAssertTrue(all.contains("127.0.0.1"), "\(all.count) addresses, no IPv4 loopback")
        XCTAssertTrue(all.contains("::1"))
    }

    func testAdvertisableKeepsOnlyDialableAddresses() {
        let advertised = LocalAddresses.advertisable()
        XCTAssertEqual(advertised, ShellAddressPolicy.advertisable(LocalAddresses.all()))
        XCTAssertFalse(advertised.contains("127.0.0.1"))
        XCTAssertFalse(advertised.contains("::1"))
        XCTAssertFalse(advertised.contains { $0.hasPrefix("fe80") || $0.hasPrefix("169.254.") })
        XCTAssertTrue(advertised.allSatisfy(ShellAddressPolicy.isAllowed))
        XCTAssertEqual(Set(advertised).count, advertised.count)
    }

    /// Loopback stays allowed through the listener's default policy, and a
    /// global address the Mac holds makes its own /64 allowed.
    func testDefaultPeerPolicyUsesTheMacsOwnPrefixes() {
        XCTAssertTrue(ShellListener.defaultPeerAllowed("127.0.0.1"))
        XCTAssertFalse(ShellListener.defaultPeerAllowed("8.8.8.8"))
        for prefix in LocalAddresses.onLinkPrefixes() { XCTAssertEqual(prefix.count, 8) }
    }

    func testOnLinkPrefixesSkipTunnelsLoopbackAndWideNetworks() {
        let up = Int32(IFF_UP)
        func interface(_ flags: Int32, _ address: String, _ length: Int?) -> LocalAddresses.Interface {
            .init(flags: up | flags, address: address, prefixLength: length)
        }
        let prefixes = LocalAddresses.onLinkPrefixes(of: [
            interface(0, "2001:db8:1:1::5", 64),                         // a real LAN
            interface(0, "2001:db8:2:2::5", 56),                         // shorter than /64: still on-link
            interface(Int32(IFF_POINTOPOINT), "2001:db8:3:3::5", 64),    // a VPN tunnel
            interface(Int32(IFF_LOOPBACK), "2001:db8:4:4::5", 64),
            interface(0, "2001:db8:5:5::5", 128),                        // a host route, not a shared network
            interface(0, "2001:db8:8:8::5", 80),
            interface(0, "2001:db8:6:6::5", 8),                          // a very wide mask
            interface(0, "2001:db8:7:7::5", nil),
        ])
        XCTAssertEqual(prefixes, ShellAddressPolicy.onLinkPrefixes(of: ["2001:db8:1:1::5", "2001:db8:2:2::5", "2001:db8:6:6::5"]))
    }
}
#endif
