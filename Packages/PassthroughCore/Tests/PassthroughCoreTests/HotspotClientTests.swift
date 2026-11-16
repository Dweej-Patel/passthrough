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

    /// Passthrough turned off on the phone shows on the iPad at once (a link
    /// that merely drops is held for a resume instead).
    func testTurningPassthroughOffOnThePhoneShowsAtOnce() async throws {
        let client = try await connect(try pairIPad())
        _ = try await waitFor("online") { client.status.phase == .online ? true : nil }
        control.sayGoodbye()
        let waiting = try await waitFor("waiting", timeout: 3) { client.status.phase == .waiting ? client.status : nil }
        XCTAssertEqual(waiting.message, "Passthrough was turned off on Test iPhone.")
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

    /// Pairing an iPad again only replaces its pairing once the iPad has taken
    /// the new token: an attempt that fails leaves the old one working.
    func testAFailedRepairLeavesTheEarlierPairingWorking() throws {
        let phone = try pairIPad()
        let attempt = try XCTUnwrap(registry.prepareClient(id: clientID, name: "iPad", kind: .ipad,
                                                           certificateSHA256: identity.fingerprint, linkKey: WirelessLink.randomBytes(32)))
        XCTAssertTrue(registry.verifySOCKS(clientID: clientID, password: ControlAuth.socksPassword(token: phone.token)),
                      "nothing changes before the commit")
        XCTAssertTrue(registry.commit(attempt))
        XCTAssertFalse(registry.verifySOCKS(clientID: clientID, password: ControlAuth.socksPassword(token: phone.token)))
        XCTAssertTrue(registry.verifySOCKS(clientID: clientID, password: ControlAuth.socksPassword(token: attempt.token)))
        XCTAssertEqual(registry.clients.count, 1)
    }

    /// A scanned code naming a Mac's ID never replaces the Mac.
    func testAnIPadCodeNeverReplacesAMac() throws {
        let macToken = try XCTUnwrap(registry.addClient(id: "mac-1", name: "Mac", kind: .mac,
                                                        certificateSHA256: identity.fingerprint, linkKey: linkKey))
        XCTAssertNil(registry.prepareClient(id: "mac-1", name: "iPad", kind: .ipad, certificateSHA256: identity.fingerprint, linkKey: linkKey))
        XCTAssertNil(registry.addClient(id: "mac-1", name: "iPad", kind: .ipad, certificateSHA256: identity.fingerprint, linkKey: linkKey))
        XCTAssertTrue(registry.verifySOCKS(clientID: "mac-1", password: ControlAuth.socksPassword(token: macToken)))
        XCTAssertFalse(registry.clients.contains(where: \.isIPad))
    }

    /// Pairing the iPad with another iPhone ends the first iPhone's link at once.
    func testPairingAnotherIPhoneDropsTheOldLink() async throws {
        let phone = try pairIPad()
        let upstream = Locked<UpstreamPhone?>(phone)
        let identity = self.identity!
        let client = HotspotClient(clientID: clientID, name: "iPad", identity: { identity }, upstream: { upstream.get() },
                                   localPort: freePort(), socksPort: socksPort, controlPort: controlPort)
        self.client = client
        try client.start()
        let port = try await waitFor("the iPad listens") { client.listenerPort }
        let registry = self.registry!
        let dialer = WirelessDialer(allowedPorts: [socksPort, controlPort]) { registry.linkCredentials() }
        self.dialer = dialer
        dialer.dial(.hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!),
                    credential: try XCTUnwrap(registry.linkCredentials().first), peerToPeer: false)
        _ = try await waitFor("online") { client.status.phase == .online ? true : nil }

        upstream.set(UpstreamPhone(phoneID: "another-phone", name: "Other iPhone", token: PairingToken.generate(),
                                   linkKey: WirelessLink.randomBytes(32)))
        client.credentialsChanged()
        XCTAssertEqual(client.status.phase, .waiting)
        XCTAssertEqual(client.status.phoneName, "Other iPhone")
        let localPort = client.localPort
        let closed: Bool = await Task.detached {
            let c = TestClient(port: localPort)
            defer { c.close() }
            c.send([5, 1, 2])
            return c.read(2, timeout: 3).isEmpty
        }.value
        XCTAssertTrue(closed, "no stream goes out through the old iPhone")
    }

}

/// Telling the iPhone's Personal Hotspot from other networks, from what the
/// iPad sees (`WirelessLink.onPhoneHotspot`, `leftPhoneHotspot`).
final class HotspotDetectionTests: XCTestCase {
    typealias Facts = WirelessLink.WiFiFacts
    /// What an iPad saw on an IPv6-only iPhone hotspot (iOS 27, a carrier without IPv4).
    let ipv6Hotspot: [(interface: String, address: String, isIPv4: Bool)] = [
        ("en0", "fe80::8ac:39d1:216:5ce8%en0", false), ("en0", "2607:fb90:fe00:c951:c8d:cec2:7936:c680", false),
        ("en0", "192.0.0.2", true), ("en1", "169.254.96.51", true),
    ]
    let homeWiFi: [(interface: String, address: String, isIPv4: Bool)] = [("en0", "192.168.1.23", true), ("en0", "fe80::1%en0", false)]
    let phoneLinkLocal = "fe80::74d5:e8ff:fea7:5164"

    func testCostlyWiFiIsTheHotspot() {
        XCTAssertTrue(WirelessLink.onPhoneHotspot(wifi: Facts(up: true, expensive: true, gateways: []), dnsServers: [],
                                                  knownHotspotDNS: [], addresses: ipv6Hotspot))
    }

    func testAnIPv6OnlyHotspotIsKnownByItsLearnedDNS() {
        let wifi = Facts(up: true, expensive: false, gateways: [phoneLinkLocal + "%en0"])
        XCTAssertFalse(WirelessLink.onPhoneHotspot(wifi: wifi, dnsServers: [phoneLinkLocal], knownHotspotDNS: [], addresses: ipv6Hotspot),
                       "nothing about it says hotspot until it's learned")
        XCTAssertTrue(WirelessLink.onPhoneHotspot(wifi: wifi, dnsServers: [phoneLinkLocal], knownHotspotDNS: [phoneLinkLocal], addresses: ipv6Hotspot))
        XCTAssertTrue(WirelessLink.onPhoneHotspot(wifi: wifi, dnsServers: [], knownHotspotDNS: [phoneLinkLocal], addresses: ipv6Hotspot),
                      "by its router, with the tunnel's DNS in the way")
    }

    func testAnIPv4HotspotIsKnownByItsAddressOrDNS() {
        XCTAssertTrue(WirelessLink.onPhoneHotspot(wifi: nil, dnsServers: [], knownHotspotDNS: [], addresses: [("en0", "172.20.10.4", true)]))
        XCTAssertTrue(WirelessLink.onPhoneHotspot(wifi: nil, dnsServers: ["172.20.10.1"], knownHotspotDNS: [], addresses: []))
    }

    func testHomeWiFiIsNotTheHotspot() {
        let wifi = Facts(up: true, expensive: false, gateways: ["192.168.1.1"])
        XCTAssertFalse(WirelessLink.onPhoneHotspot(wifi: wifi, dnsServers: ["192.168.1.1"], knownHotspotDNS: [phoneLinkLocal], addresses: homeWiFi))
        XCTAssertTrue(WirelessLink.leftPhoneHotspot(wifi: wifi, knownHotspotDNS: [phoneLinkLocal], addresses: homeWiFi))
    }

    /// The CLAT address (192.0.0.2) an IPv6-only hotspot gives is no sign of another network.
    func testStayingOnAnIPv6OnlyHotspotIsNotLeaving() {
        XCTAssertFalse(WirelessLink.leftPhoneHotspot(wifi: Facts(up: true, expensive: true, gateways: [phoneLinkLocal]),
                                                     knownHotspotDNS: [], addresses: ipv6Hotspot))
        XCTAssertFalse(WirelessLink.leftPhoneHotspot(wifi: Facts(up: true, expensive: false, gateways: [phoneLinkLocal]),
                                                     knownHotspotDNS: [phoneLinkLocal], addresses: ipv6Hotspot))
    }

    func testWiFiDownIsLeaving() {
        XCTAssertTrue(WirelessLink.leftPhoneHotspot(wifi: Facts(up: false, expensive: false, gateways: []), knownHotspotDNS: [], addresses: []))
    }

    func testLearnedDNSDropsScopesAndTheTunnelsOwn() {
        let defaults = UserDefaults(suiteName: "hotspot-dns-\(UUID().uuidString)")!
        XCTAssertTrue(HotspotTunnel.rememberHotspotDNS([phoneLinkLocal + "%en0", HotspotTunnel.dnsAddress], in: defaults))
        XCTAssertEqual(HotspotTunnel.knownHotspotDNS(defaults), [phoneLinkLocal])
        XCTAssertFalse(HotspotTunnel.rememberHotspotDNS([phoneLinkLocal], in: defaults), "nothing new")
    }
}
