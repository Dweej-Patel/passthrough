import XCTest
import Network
@testable import PassthroughCore
@testable import PhoneTransport
import TestSupport

/// An iPad's "Internet through iPhone" over loopback: the phone's SOCKS and
/// control servers with the iPad added as a client, the phone's dialer
/// reaching the iPad's `HotspotClient`, and a SOCKS stream through the iPad's
/// loopback port coming out of the phone.
@available(macOS 15, *)
@MainActor
final class HotspotClientTests: XCTestCase {
    private var registry: PairingRegistry!
    private var socks: SOCKS5Server!
    private var control: ControlServer!
    private var dialer: WirelessDialer?
    private var client: HotspotClient?
    private var identity: MacIdentity!
    private let linkKey = WirelessLink.randomBytes(32)
    private let clientID = "ipad-\(UUID().uuidString.prefix(8))"
    private var socksPort: UInt16 = 0
    private var controlPort: UInt16 = 0

    override func setUp() async throws {
        identity = try (try? makeTestIdentity()) ?? makeTestIdentity()
        registry = PairingRegistry(defaults: UserDefaults(suiteName: "hotspot-test-\(UUID().uuidString)")!, secrets: InMemorySecrets())
        socksPort = freePort()
        controlPort = freePort()
        var config = SOCKS5Server.Configuration()
        config.port = socksPort
        config.refuseLocalDestinations = false   // the echo server is on loopback
        let registry = self.registry!
        socks = SOCKS5Server(configuration: config) { user, password in registry.verifySOCKS(clientID: user, password: password) }
        try socks.start()
        control = ControlServer(port: controlPort, socksPort: socksPort, registry: registry, counter: socks.counter) {
            DeviceStatus(deviceName: "Test iPhone", radio: "5G", battery: 0.8, hosting: "background", ipv6: false)
        }
        try control.start()
    }

    override func tearDown() async throws {
        client?.stop()
        dialer?.stop()
        control?.stop()
        socks?.stop()
    }

    /// Adds the iPad on the phone (as an introduction or a scan would) and returns what the iPad keeps.
    private func pairIPad() throws -> UpstreamPhone {
        let token = try XCTUnwrap(registry.addClient(id: clientID, name: "iPad", kind: .ipad,
                                                     certificateSHA256: identity.fingerprint, linkKey: linkKey))
        return UpstreamPhone(phoneID: registry.phoneID, name: "Test iPhone", token: token, linkKey: linkKey)
    }

    /// Starts the iPad's client and has the phone dial it.
    private func connect(_ phone: UpstreamPhone) async throws -> HotspotClient {
        let identity = self.identity!
        let client = HotspotClient(clientID: clientID, name: "iPad", identity: { identity }, upstream: { phone },
                                   localPort: freePort(), socksPort: socksPort, controlPort: controlPort)
        self.client = client
        try client.start()
        let port = try await waitFor("the iPad listens") { client.listenerPort }
        let registry = self.registry!
        let dialer = WirelessDialer(allowedPorts: [socksPort, controlPort]) { registry.linkCredentials() }
        self.dialer = dialer
        let credential = try XCTUnwrap(registry.linkCredentials().first)
        XCTAssertEqual(credential.hotspotOnly, true, "an iPad is dialed over the hotspot only")
        dialer.dial(.hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!), credential: credential, peerToPeer: false)
        return client
    }

    private func waitFor<T>(_ what: String, timeout: TimeInterval = 10, _ value: () -> T?) async throws -> T {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let value = value() { return value }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("timed out waiting for \(what)")
        throw CancellationError()
    }

    func testIPadReachesTheInternetThroughThePhone() async throws {
        let phone = try pairIPad()
        let client = try await connect(phone)
        let online = try await waitFor("the iPad online") { client.status.phase == .online && client.status.radio != nil ? client.status : nil }
        XCTAssertEqual(online.phoneName, "Test iPhone")
        XCTAssertEqual(online.radio, "5G")
        XCTAssertEqual(control.connectedMacs.first?.kind, .ipad, "the phone sees an iPad in its list")

        // What the iPad's tun2socks does: SOCKS5 with its client ID and the
        // password from its token, to the loopback forwarder.
        let echo = try EchoServer()
        let localPort = client.localPort
        let user = clientID
        let password = ControlAuth.socksPassword(token: phone.token)
        let payload = Data((0..<50_000).map { UInt8($0 % 251) })
        let echoed: Data = try await Task.detached {
            let c = TestClient(port: localPort)
            defer { c.close() }
            c.send([5, 1, 2])
            guard Array(c.read(2)) == [5, 2] else { return Data() }
            c.send([1, UInt8(user.utf8.count)] + Array(user.utf8) + [UInt8(password.utf8.count)] + Array(password.utf8))
            guard Array(c.read(2)) == [1, 0] else { return Data() }
            c.send([5, 1, 0, 1, 127, 0, 0, 1, UInt8(echo.port >> 8), UInt8(echo.port & 0xFF)])
            guard Array(c.read(10).prefix(2)) == [5, 0] else { return Data() }
            c.send(payload)
            return c.read(payload.count)
        }.value
        XCTAssertEqual(echoed, payload, "a stream through the iPad's port comes out of the phone")
        XCTAssertGreaterThanOrEqual(client.counters.tx, Int64(payload.count))
    }

    func testAPairingThePhoneNoLongerHasIsRefused() async throws {
        var phone = try pairIPad()
        phone.token = PairingToken.generate()   // not the token the phone issued
        let client = try await connect(phone)
        let refused = try await waitFor("refused") { client.status.phase == .refused ? client.status : nil }
        XCTAssertNotNil(refused.message)
    }

    func testWithoutALinkStreamsFailAtOnce() async throws {
        let client = HotspotClient(clientID: clientID, name: "iPad", identity: { [identity] in identity! }, upstream: { nil },
                                   localPort: freePort(), socksPort: socksPort, controlPort: controlPort)
        self.client = client
        try client.start()
        let localPort = client.localPort
        let closedQuickly: Bool = await Task.detached {
            let c = TestClient(port: localPort)
            defer { c.close() }
            c.send([5, 1, 2])
            let start = Date()
            let reply = c.read(2, timeout: 3)
            return reply.isEmpty && Date().timeIntervalSince(start) < 2
        }.value
        XCTAssertTrue(closedQuickly, "the guard: nothing waits for a link that isn't there")
        XCTAssertEqual(client.status.phase, .waiting)
    }

}
