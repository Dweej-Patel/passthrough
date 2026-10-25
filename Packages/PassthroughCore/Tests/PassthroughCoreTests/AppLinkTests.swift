import XCTest
@testable import PassthroughCore

final class AppLinkTests: XCTestCase {
    func testEachLinkRoundTrips() {
        let id = UUID().uuidString
        for link in [AppLink.mac, .keepAwake, .vpnOn, .session(id)] {
            XCTAssertEqual(AppLink(url: link.url), link, link.url.absoluteString)
        }
    }

    /// Nothing lowers protection from a link: there is no VPN-off or sleep link to forge.
    func testOnlyOurLinks() {
        for text in ["passthrough://vpn-off", "passthrough://keep-awake-off", "https://mac", "other://mac",
                     "passthrough://session/not-a-uuid", "passthrough://session/", "passthrough://"] {
            XCTAssertNil(AppLink(url: URL(string: text)!), text)
        }
    }
}
