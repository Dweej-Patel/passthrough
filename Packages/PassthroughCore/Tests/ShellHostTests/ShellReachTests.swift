#if os(macOS)
import XCTest
import IrohTransport
import PassthroughCore
@testable import ShellHost

final class ShellReachTests: XCTestCase {
    private let id = String(repeating: "ab", count: 32)
    private let addresses = ["192.168.1.2", "100.64.0.1"]

    func testOffSendsAddressesWithoutIroh() {
        let reach = ShellReach(reachAnywhere: false, endpointID: id, homeRelay: "https://euw1-1.relay.iroh.network./",
                               relay: IrohRelayConfig(url: "https://relay.example.com/", token: "secret"), addresses: addresses)
        XCTAssertNil(reach.iroh)
        let info = reach.macInfo()
        XCTAssertEqual(info?.t, ShellEnvelope.macInfo)
        XCTAssertEqual(info?.addresses, addresses)
        XCTAssertNil(info?.irohID)
        XCTAssertNil(info?.irohRelay)
        XCTAssertNil(info?.relayToken)
    }

    func testStartingSendsNothing() {
        let reach = ShellReach(reachAnywhere: true, endpointID: nil, addresses: addresses)
        XCTAssertNil(reach.iroh)
        XCTAssertNil(reach.macInfo(), "phones keep their details until the endpoint is up")
    }

    func testDefaultRelayUsesHomeRelayWithoutToken() {
        let reach = ShellReach(reachAnywhere: true, endpointID: id, homeRelay: "https://euw1-1.relay.iroh.network./",
                               relay: IrohRelayConfig(url: nil, token: "stale"), addresses: addresses)
        XCTAssertEqual(reach.iroh, ShellReach.Iroh(id: id, relay: "https://euw1-1.relay.iroh.network./", token: nil))
        let info = reach.macInfo()
        XCTAssertEqual(info?.irohID, id)
        XCTAssertEqual(info?.irohRelay, "https://euw1-1.relay.iroh.network./")
        XCTAssertNil(info?.relayToken)
        XCTAssertEqual(info?.addresses, addresses)
    }

    func testDefaultRelayNotYetKnownSendsNothing() {
        let reach = ShellReach(reachAnywhere: true, endpointID: id, addresses: addresses)
        XCTAssertNil(reach.iroh, "the grant leaves iroh out until the home relay is known")
        XCTAssertNil(reach.macInfo(), "an absent irohID would clear phones' stored details")
    }

    func testCustomRelayAlwaysCarriesItsToken() {
        let reach = ShellReach(reachAnywhere: true, endpointID: id, homeRelay: "https://other.example.com/",
                               relay: IrohRelayConfig(url: "https://relay.example.com/", token: "secret"), addresses: addresses)
        XCTAssertEqual(reach.iroh, ShellReach.Iroh(id: id, relay: "https://relay.example.com/", token: "secret"))
        let info = reach.macInfo()
        XCTAssertEqual(info?.irohRelay, "https://relay.example.com/", "the configured URL, not whatever is home now")
        XCTAssertEqual(info?.relayToken, "secret")
    }

    func testCustomRelayDoesNotWaitForHomeRelay() {
        let reach = ShellReach(reachAnywhere: true, endpointID: id,
                               relay: IrohRelayConfig(url: "https://relay.example.com/", token: nil), addresses: addresses)
        XCTAssertEqual(reach.macInfo()?.irohID, id)
        XCTAssertEqual(reach.macInfo()?.irohRelay, "https://relay.example.com/")
    }

    func testEmptyTokenIsNone() {
        let reach = ShellReach(reachAnywhere: true, endpointID: id,
                               relay: IrohRelayConfig(url: "https://relay.example.com/", token: ""))
        XCTAssertNil(reach.iroh?.token)
        XCTAssertNil(reach.macInfo()?.relayToken)
    }
}
#endif
