import XCTest
import Network
@testable import PassthroughCore
@testable import PhoneTransport

/// A stand-in cable: plain TCP to the phone's loopback servers.
struct LoopbackLink: PhoneLink {
    func connect(port: UInt16, queue: DispatchQueue, completion: @escaping @Sendable (Result<ByteStream, Error>) -> Void) {
        let c = NWConnection(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        c.stateUpdateHandler = { state in
            switch state {
            case .ready: c.stateUpdateHandler = nil; completion(.success(ConnectionStream(c, queue: queue)))
            case .failed(let e): c.stateUpdateHandler = nil; completion(.failure(e))
            default: break
            }
        }
        c.start(queue: queue)
    }
}

final class LinkingTests: XCTestCase {
    /// Pair over the (stand-in) cable, then link: the phone ends up with a
    /// credential for this Mac and answers with its phone ID.
    func testPairThenLink() throws {
        let suite = "dev.dpatel.passthrough.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let registry = PairingRegistry(defaults: defaults, secrets: InMemorySecrets())
        let port = freePort()
        let server = ControlServer(port: port, socksPort: 7890, registry: registry, counter: ByteCounter()) {
            DeviceStatus(deviceName: "Test iPhone", hosting: "test")
        }
        try server.start()
        defer { server.stop() }

        let device = PhoneDevice(id: "test", kind: .iPhone, label: "test", pairingSlot: "t", link: LoopbackLink())
        let events = Locked<[ControlClient.Event]>([])
        let welcomed = expectation(description: "welcomed"), paired = expectation(description: "paired"), linked = expectation(description: "linked")
        let client = ControlClient(device: device, port: port, identity: .init(clientID: "mac1", name: "MacBook", token: nil)) { event in
            events.set(events.get() + [event])
            switch event {
            case .welcomed: welcomed.fulfill()
            case .paired: paired.fulfill()
            case .linked: linked.fulfill()
            default: break
            }
        }
        client.connect()
        wait(for: [welcomed], timeout: 5)

        // Linking before pairing is ignored.
        client.link(linkKey: WirelessLink.randomBytes(32), certificateSHA256: String(repeating: "a", count: 64))
        let (code, _) = registry.issueCode()
        client.pair(code: code)
        wait(for: [paired], timeout: 5)
        XCTAssertTrue(registry.linkCredentials().isEmpty, "a link sent before pairing must not count")

        let key = WirelessLink.randomBytes(32)
        client.link(linkKey: key, certificateSHA256: String(repeating: "b", count: 64))
        wait(for: [linked], timeout: 5)
        client.close()

        guard case .linked(let phoneID, let network, _) = events.get().last else { return XCTFail() }
        XCTAssertEqual(phoneID, registry.phoneID)
        XCTAssertNil(network, "iPhones host no network")
        XCTAssertEqual(registry.linkCredentials(), [LinkCredential(macTag: WirelessLink.macTag(clientID: "mac1"), certSHA256: String(repeating: "b", count: 64), linkKey: key, phoneID: phoneID)])
        registry.revoke(clientID: "mac1")
        XCTAssertTrue(registry.linkCredentials().isEmpty, "unpairing forgets the link")
    }
}
