import XCTest
@testable import PassthroughCore

final class AppLinkTests: XCTestCase {
    func testEachLinkRoundTrips() {
        let id = UUID().uuidString
        let macID = "6C1F2B9A-mac id/with?odd&chars"
        for link in [AppLink.mac(nil), .mac(macID), .keepAwake, .vpnOn, .session(id, mac: nil), .session(id, mac: macID)] {
            XCTAssertEqual(AppLink(url: link.url), link, link.url.absoluteString)
        }
    }

    /// Links from builds before activities named their Mac still open, meaning the Mac selected now.
    func testOldLinksWithoutAMacStillWork() {
        let id = UUID().uuidString
        XCTAssertEqual(AppLink(url: URL(string: "passthrough://mac")!), .mac(nil))
        XCTAssertEqual(AppLink(url: URL(string: "passthrough://session/\(id)")!), .session(id, mac: nil))
        XCTAssertEqual(AppLink.mac(nil).url.absoluteString, "passthrough://mac")
        XCTAssertEqual(AppLink.session(id, mac: nil).url.absoluteString, "passthrough://session/\(id)")
    }

    func testMacIDIsCarried() {
        let id = UUID().uuidString
        XCTAssertEqual(AppLink(url: URL(string: "passthrough://mac?mac=m1")!), .mac("m1"))
        XCTAssertEqual(AppLink(url: URL(string: "passthrough://session/\(id)?mac=m2")!), .session(id, mac: "m2"))
        // Other query items are ignored.
        XCTAssertEqual(AppLink(url: URL(string: "passthrough://mac?x=1&mac=m1")!), .mac("m1"))
    }

    func testTarget() {
        let id = UUID().uuidString
        let paired = ["a", "b"]
        // A named Mac: switch to it if paired, else nothing is attached.
        XCTAssertEqual(AppLink.session(id, mac: "a").target(activityMac: "b", paired: paired), .mac("a"))
        XCTAssertEqual(AppLink.mac("b").target(activityMac: nil, paired: paired), .mac("b"))
        XCTAssertEqual(AppLink.session(id, mac: "gone").target(activityMac: "a", paired: paired), .rejected)
        XCTAssertEqual(AppLink.mac("gone").target(activityMac: nil, paired: paired), .rejected)
        // An unqualified session link (older activity): the running activity's Mac, tagged or adopted.
        XCTAssertEqual(AppLink.session(id, mac: nil).target(activityMac: "a", paired: paired), .mac("a"))
        XCTAssertEqual(AppLink.session(id, mac: nil).target(activityMac: "gone", paired: paired), .current)
        XCTAssertEqual(AppLink.session(id, mac: nil).target(activityMac: nil, paired: paired), .current)
        // An unqualified Mac link (an older activity with no question waiting): the activity's Mac too.
        XCTAssertEqual(AppLink.mac(nil).target(activityMac: "a", paired: paired), .mac("a"))
        XCTAssertEqual(AppLink.mac(nil).target(activityMac: "gone", paired: paired), .current)
        XCTAssertEqual(AppLink.mac(nil).target(activityMac: nil, paired: paired), .current)
        // Other unqualified links: the Mac selected now.
        XCTAssertEqual(AppLink.keepAwake.target(activityMac: "a", paired: paired), .current)
        XCTAssertEqual(AppLink.vpnOn.target(activityMac: nil, paired: []), .current)
    }

    /// Nothing lowers protection from a link: there is no VPN-off or sleep link to forge.
    func testOnlyOurLinks() {
        let long = String(repeating: "a", count: 65)
        for text in ["passthrough://vpn-off", "passthrough://keep-awake-off", "https://mac", "other://mac",
                     "passthrough://session/not-a-uuid", "passthrough://session/", "passthrough://",
                     "passthrough://mac?mac=", "passthrough://mac?mac", "passthrough://mac?mac=\(long)"] {
            XCTAssertNil(AppLink(url: URL(string: text)!), text)
        }
    }
}
