import XCTest
import Network
import notify
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

    /// A link key that cannot be stored leaves the Mac unlinked, so the phone
    /// sends no "linked" and the Mac offers the link again next time.
    func testUnstoredKeyDoesNotLink() {
        final class RefusingSecrets: SecretStore, @unchecked Sendable {
            func read(_ account: String) -> Data? { nil }
            func write(_ data: Data, account: String) -> Bool { false }
            func delete(_ account: String) {}
        }
        let suite = "dev.dpatel.passthrough.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let registry = PairingRegistry(defaults: defaults, secrets: RefusingSecrets())
        let (code, _) = registry.issueCode()
        guard case .success = registry.pair(code: code, clientID: "mac1", name: "MacBook") else { return XCTFail("pairing failed") }
        XCTAssertFalse(registry.link(clientID: "mac1", certificateSHA256: String(repeating: "b", count: 64), linkKey: WirelessLink.randomBytes(32)))
        XCTAssertNil(registry.clients.first?.linkCertificate, "no certificate recorded without its key")
        XCTAssertFalse(registry.link(clientID: "unknown", certificateSHA256: String(repeating: "b", count: 64), linkKey: WirelessLink.randomBytes(32)))
    }

    /// Every change to the paired Macs is announced across processes, so the
    /// tunnel extension hears when the app forgets one.
    func testPairingChangesAreAnnounced() {
        let suite = "dev.dpatel.passthrough.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let registry = PairingRegistry(defaults: defaults, secrets: InMemorySecrets())
        let (code, _) = registry.issueCode()
        guard case .success = registry.pair(code: code, clientID: "mac1", name: "MacBook") else { return XCTFail("pairing failed") }
        let posted = expectation(description: "announced")
        posted.assertForOverFulfill = false
        var token: Int32 = 0
        XCTAssertEqual(notify_register_dispatch(PairingRegistry.changedNotification, &token, .global()) { _ in posted.fulfill() }, UInt32(NOTIFY_STATUS_OK))
        defer { notify_cancel(token) }
        registry.revoke(clientID: "mac1")
        wait(for: [posted], timeout: 2)
    }
}
