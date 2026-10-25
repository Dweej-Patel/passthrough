import XCTest
@testable import PassthroughCore

/// Checks the remote shell protocol against the `shell` section of
/// protocol/fixtures.json, the file the Android tests read too.
final class ShellProtocolTests: XCTestCase {
    private func shell() throws -> [String: Any] {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while dir.path != "/" {
            let file = dir.appendingPathComponent("protocol/fixtures.json")
            if FileManager.default.fileExists(atPath: file.path) {
                let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
                return try XCTUnwrap(root["shell"] as? [String: Any])
            }
            dir.deleteLastPathComponent()
        }
        throw XCTSkip("protocol/fixtures.json not found")
    }

    func testConstantsMatchFixtures() throws {
        let s = try shell()
        XCTAssertEqual(s["port"] as? Int, Int(RemoteShell.defaultPort))
        XCTAssertEqual(s["serviceType"] as? String, RemoteShell.serviceType)
        XCTAssertEqual(s["proofLabel"] as? String, RemoteShell.proofLabel)
        XCTAssertEqual(s["maxSessions"] as? Int, RemoteShell.maxSessions)
        XCTAssertEqual(s["scrollbackBytes"] as? Int, RemoteShell.scrollbackBytes)
        XCTAssertEqual(s["outputChunk"] as? Int, RemoteShell.outputChunk)
        XCTAssertEqual(s["lineLimit"] as? Int, RemoteShell.lineLimit)
    }

    func testProofMatchesFixture() throws {
        for p in try XCTUnwrap(shell()["proofs"] as? [[String: String]]) {
            let key = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(p["shellKey"])))
            let nonce = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(p["nonce"])))
            let mac = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(p["mac"])))
            XCTAssertEqual(RemoteShell.proof(shellKey: key, nonce: nonce), mac)
            XCTAssertTrue(RemoteShell.proofIsValid(mac, shellKey: key, nonce: nonce))
            var flipped = mac
            flipped[0] ^= 1
            XCTAssertFalse(RemoteShell.proofIsValid(flipped, shellKey: key, nonce: nonce))
        }
    }

    /// Every field survives a decode and re-encode, and nothing extra (like nulls) is added.
    func testShellMessagesRoundTrip() throws {
        let messages = try XCTUnwrap(shell()["messages"] as? [[String: Any]])
        XCTAssertGreaterThanOrEqual(messages.count, 23)
        for m in messages {
            let line = try XCTUnwrap(m["line"] as? String)
            let decoded = try ShellEnvelope.decode(Data(line.utf8))
            let original = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? NSDictionary
            let reencoded = try JSONSerialization.jsonObject(with: decoded.encodedLine()) as? NSDictionary
            XCTAssertEqual(original, reencoded, line)
        }
    }

    func testHelloAndMacInfoFields() throws {
        let messages = try XCTUnwrap(shell()["messages"] as? [[String: Any]])
        let lines = messages.compactMap { $0["line"] as? String }
        let hello = try ShellEnvelope.decode(Data(try XCTUnwrap(lines.first { $0.contains("\"hello\"") }).utf8))
        XCTAssertEqual(hello.t, ShellEnvelope.hello)
        let info = try ShellEnvelope.decode(Data(try XCTUnwrap(lines.first { $0.contains("\"macInfo\"") }).utf8))
        XCTAssertEqual(info.t, ShellEnvelope.macInfo)
        XCTAssertTrue(IrohInfo.isValidID(try XCTUnwrap(info.irohID)))
        XCTAssertEqual(info.irohRelay, "https://relay.example.com/")
        XCTAssertEqual(info.relayToken, "relay-token-123")
        XCTAssertEqual(info.addresses, ["192.168.1.20", "100.101.102.103"])
    }

    /// The Mac's state and a phone's requests to change it; absent fields stay absent.
    func testMacStateAndControlFields() throws {
        let messages = try XCTUnwrap(shell()["messages"] as? [[String: Any]])
        let lines = try messages.compactMap { $0["line"] as? String }.map { try ShellEnvelope.decode(Data($0.utf8)) }
        let states = lines.filter { $0.t == ShellEnvelope.macState }.compactMap(\.state)
        XCTAssertEqual(states.first, MacState(awake: true, battery: 0.64, charging: false, minutesLeft: 190, batteryFloor: 0.2, hot: false,
                                              vpn: MacState.vpnOn, vpnName: "NordVPN Germany", killSwitch: true, control: true))
        XCTAssertEqual(states.last, MacState(awake: false, awakeStopped: "battery", battery: 0.19, charging: false, batteryFloor: 0.2, control: false))
        XCTAssertEqual(lines.first { $0.t == ShellEnvelope.setAwake }?.on, false)
        XCTAssertEqual(lines.first { $0.t == ShellEnvelope.setVPN }?.on, true)
        XCTAssertTrue(lines.contains { $0.t == ShellEnvelope.error && $0.reason == ShellError.notAllowed.rawValue })
    }

    func testEventListFields() throws {
        let messages = try XCTUnwrap(shell()["messages"] as? [[String: Any]])
        let lines = try messages.compactMap { $0["line"] as? String }.map { try ShellEnvelope.decode(Data($0.utf8)) }
        XCTAssertEqual(lines.first { $0.t == ShellEnvelope.events }?.since, 1_758_060_000)
        let list = try XCTUnwrap(lines.first { $0.t == ShellEnvelope.eventList })
        XCTAssertEqual(list.events?.map(\.kind), ["vpn", "shell", "vpn"])
        XCTAssertEqual(list.events?.last?.warning, true)
        XCTAssertNil(list.events?.first?.warning)
        XCTAssertEqual(list.events?[1].session, "3F2B8C1A-7D4E-4A55-9C0B-1E6F2A9D8B34")
        XCTAssertEqual(list.battery, [BatterySample(t: 1_758_059_900, level: 0.64), BatterySample(t: 1_758_060_300, level: 0.62, charging: true)])
    }

    /// A replay's sizes: the entry's starting size, and a size on the transcript line it applies from.
    func testReplaySizeFields() throws {
        let messages = try XCTUnwrap(shell()["messages"] as? [[String: Any]])
        let lines = try messages.compactMap { $0["line"] as? String }.map { try ShellEnvelope.decode(Data($0.utf8)) }
        let entry = try XCTUnwrap(lines.filter { $0.t == ShellEnvelope.historyList }.flatMap { $0.history ?? [] }.first { $0.cols != nil })
        XCTAssertEqual(entry.cols, 48)
        XCTAssertEqual(entry.rows, 20)
        let pieces = lines.filter { $0.t == ShellEnvelope.transcriptData }
        XCTAssertTrue(pieces.contains { $0.cols == nil && $0.rows == nil }, "an older Mac's: just output")
        var collector = ShellReplay.Collector()
        for p in pieces where p.cols != nil {
            collector.add(try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(p.data))), cols: p.cols, rows: p.rows)
        }
        XCTAssertEqual(collector.chunks, [
            .resize(cols: 48, rows: 20), .output(try XCTUnwrap(Data(base64Encoded: "JCBscw0K"))), .resize(cols: 100, rows: 30),
        ])
    }

    func testIrohValidation() {
        let id = String(repeating: "ab", count: 32)
        XCTAssertTrue(IrohInfo.isValidID(id))
        XCTAssertFalse(IrohInfo.isValidID(String(id.dropLast())))
        XCTAssertFalse(IrohInfo.isValidID(id.uppercased()))
        XCTAssertFalse(IrohInfo.isValidID("g" + id.dropFirst()))
        XCTAssertTrue(IrohInfo.isValidRelay("https://relay.example.com/"))
        XCTAssertFalse(IrohInfo.isValidRelay("http://relay.example.com/"))
        XCTAssertFalse(IrohInfo.isValidRelay("https://"))
        XCTAssertFalse(IrohInfo.isValidRelay("https://a.example.com/" + String(repeating: "x", count: 256)))
        XCTAssertTrue(IrohInfo.isValidToken(String(repeating: "t", count: 512)))
        XCTAssertFalse(IrohInfo.isValidToken(String(repeating: "t", count: 513)))
        XCTAssertTrue(IrohInfo.isValidToken(String(repeating: "é", count: 256)))
        XCTAssertFalse(IrohInfo.isValidToken(String(repeating: "é", count: 257)), "limits count UTF-8 bytes")
        XCTAssertFalse(IrohInfo.areValid(id: nil, relay: "https://r.example.com/", token: "t"), "relay or token without an id")
    }

    func testAddressPolicy() throws {
        for a in try XCTUnwrap(shell()["addresses"] as? [[String: Any]]) {
            let host = try XCTUnwrap(a["host"] as? String)
            XCTAssertEqual(ShellAddressPolicy.isAllowed(host), a["allowed"] as? Bool, host)
        }
    }

    func testAdvertisableOrdersTailscaleLast() {
        XCTAssertEqual(ShellAddressPolicy.advertisable(["100.101.1.2", "192.168.1.5", "127.0.0.1", "fe80::1%en0"]),
                       ["192.168.1.5", "100.101.1.2"])
    }

    private func lanAddress(_ address: String, _ interface: String = "en0") -> ShellAddressPolicy.LocalAddress {
        .init(address: address, interface: interface, isPointToPoint: false)
    }

    private func tunnelAddress(_ address: String, _ interface: String = "utun4") -> ShellAddressPolicy.LocalAddress {
        .init(address: address, interface: interface, isPointToPoint: true)
    }

    /// 100.64.0.0/10 is carrier NAT space too: a peer from it gets in only
    /// while the Mac is on an overlay (Tailscale, NetBird, Headscale) itself,
    /// and only through its overlay address.
    func testOverlayPeersNeedTheMacOnAnOverlay() {
        let lan = [lanAddress("192.168.1.5"), lanAddress("fe80::1%en0")]
        XCTAssertFalse(ShellAddressPolicy.isAllowedPeer("100.101.1.2", localAddresses: lan, onLinkPrefixes: []))
        XCTAssertFalse(ShellAddressPolicy.isAllowedPeer("fd7a:115c:a1e0::5", localAddresses: lan, onLinkPrefixes: []))
        XCTAssertTrue(ShellAddressPolicy.isAllowedPeer("192.168.1.9", localAddresses: lan, onLinkPrefixes: []))
        XCTAssertTrue(ShellAddressPolicy.isAllowedPeer("fd00::9", localAddresses: lan, onLinkPrefixes: []), "other ULAs are unchanged")
        XCTAssertFalse(ShellAddressPolicy.isAllowedPeer("8.8.8.8", localAddresses: lan, onLinkPrefixes: []))
        let tailnet = lan + [tunnelAddress("100.90.0.1")]
        XCTAssertTrue(ShellAddressPolicy.isAllowedPeer("100.101.1.2", localAddresses: tailnet, onLinkPrefixes: []))
        XCTAssertFalse(ShellAddressPolicy.isAllowedPeer("fd7a:115c:a1e0::5", localAddresses: tailnet, onLinkPrefixes: []),
                       "an IPv4 overlay address does not admit IPv6 overlay peers")
        XCTAssertTrue(ShellAddressPolicy.isAllowedPeer("fd7a:115c:a1e0::5", localAddresses: lan + [tunnelAddress("fd7a:115c:a1e0::1")],
                                                       onLinkPrefixes: []))
        let prefixes = ShellAddressPolicy.onLinkPrefixes(of: ["2001:db8:1:2::10"])
        XCTAssertTrue(ShellAddressPolicy.isAllowedPeer("2001:db8:1:2::99", localAddresses: lan, onLinkPrefixes: prefixes))

        XCTAssertTrue(ShellAddressPolicy.arrivedOnItsNetwork(peer: "100.101.1.2", local: "100.90.0.1", localAddresses: tailnet))
        XCTAssertFalse(ShellAddressPolicy.arrivedOnItsNetwork(peer: "100.101.1.2", local: "192.168.1.5", localAddresses: tailnet),
                       "an overlay source on the LAN interface")
        XCTAssertFalse(ShellAddressPolicy.arrivedOnItsNetwork(peer: "100.101.1.2", local: nil, localAddresses: tailnet),
                       "an overlay peer whose arrival is unknown is refused")
        XCTAssertTrue(ShellAddressPolicy.arrivedOnItsNetwork(peer: "192.168.1.9", local: "192.168.1.5", localAddresses: lan))
        XCTAssertTrue(ShellAddressPolicy.arrivedOnItsNetwork(peer: "192.168.1.9", local: nil, localAddresses: lan),
                      "other peers do not need it")
    }

    /// A carrier-grade NAT address on Wi-Fi or Ethernet is the carrier's
    /// network: it admits no overlay-range peer, and nothing that arrives on
    /// it counts as arriving on the overlay, even while a tunnel is also up.
    func testCarrierNATAddressesAreNotAnOverlay() {
        let cgnat = [lanAddress("100.72.3.4", "en0"), lanAddress("192.168.1.5")]
        XCTAssertFalse(ShellAddressPolicy.isAllowedPeer("100.72.9.9", localAddresses: cgnat, onLinkPrefixes: []))
        XCTAssertFalse(ShellAddressPolicy.isAllowedPeer("100.72.9.9", localAddresses: [tunnelAddress("100.72.3.4", "en0")], onLinkPrefixes: []),
                       "point-to-point but not a utun")
        XCTAssertFalse(ShellAddressPolicy.isAllowedPeer("100.72.9.9", localAddresses: [lanAddress("100.72.3.4", "utun3")], onLinkPrefixes: []),
                       "a utun that is not point-to-point")
        XCTAssertFalse(ShellAddressPolicy.isAllowedPeer("100.72.9.9", localAddresses: [tunnelAddress("10.8.0.2")], onLinkPrefixes: []),
                       "a VPN tunnel outside the overlay range")
        let both = cgnat + [tunnelAddress("100.90.0.1")]
        XCTAssertTrue(ShellAddressPolicy.isAllowedPeer("100.101.1.2", localAddresses: both, onLinkPrefixes: []))
        XCTAssertTrue(ShellAddressPolicy.arrivedOnItsNetwork(peer: "100.101.1.2", local: "100.90.0.1", localAddresses: both))
        XCTAssertFalse(ShellAddressPolicy.arrivedOnItsNetwork(peer: "100.72.9.9", local: "100.72.3.4", localAddresses: both),
                       "arrived on the carrier's address, not the tunnel's")
        XCTAssertTrue(ShellAddressPolicy.arrivedOnItsNetwork(peer: "fd7a:115c:a1e0::5", local: "fd7a:115c:a1e0::1%utun4",
                                                             localAddresses: [tunnelAddress("fd7a:115c:a1e0::1")]))
    }

    func testErrorReasonsAreWireStrings() {
        XCTAssertEqual(ShellError.notAuthorized.rawValue, "not_authorized")
        XCTAssertEqual(ShellError.tooManySessions.rawValue, "too_many_sessions")
        XCTAssertEqual(ShellError.noSuchSession.rawValue, "no_such_session")
        XCTAssertEqual(ShellError.badRequest.rawValue, "bad_request")
    }

    /// A global IPv6 peer is let in only from a /64 the Mac has an address in.
    func testGlobalIPv6PeerOnlyFromTheMacsOwnPrefix() {
        let prefixes = ShellAddressPolicy.onLinkPrefixes(of: ["2001:db8:1:2::10", "fe80::1%en0", "192.168.1.5", "fd00::5"])
        XCTAssertEqual(prefixes.count, 1, "only global addresses give prefixes")
        XCTAssertTrue(ShellAddressPolicy.isAllowed("2001:db8:1:2:aaaa:bbbb:cccc:dddd", onLinkPrefixes: prefixes))
        XCTAssertTrue(ShellAddressPolicy.isAllowed("2001:db8:1:2::99%en0", onLinkPrefixes: prefixes))
        XCTAssertFalse(ShellAddressPolicy.isAllowed("2001:db8:1:3::10", onLinkPrefixes: prefixes))
        XCTAssertFalse(ShellAddressPolicy.isAllowed("2a00:1450::1", onLinkPrefixes: prefixes))
        XCTAssertFalse(ShellAddressPolicy.isAllowed("2001:db8:1:2::10", onLinkPrefixes: []))
        XCTAssertFalse(ShellAddressPolicy.isAllowed("8.8.8.8", onLinkPrefixes: prefixes))
        XCTAssertTrue(ShellAddressPolicy.isAllowed("192.168.1.9", onLinkPrefixes: prefixes))
        XCTAssertFalse(ShellAddressPolicy.isAllowed("2001:db8:1:2::10"), "the plain policy is unchanged")
        XCTAssertEqual(ShellAddressPolicy.advertisable(["2001:db8:1:2::10"]), [], "global addresses are never advertised")
    }
}
