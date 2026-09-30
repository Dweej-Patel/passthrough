import XCTest
@testable import VPNConfig

final class WireGuardConfigTests: XCTestCase {
    // 32 bytes each, base64.
    private let privateKey = Data(repeating: 1, count: 32).base64EncodedString()
    private let publicKey = Data(repeating: 2, count: 32).base64EncodedString()
    private let presharedKey = Data(repeating: 3, count: 32).base64EncodedString()

    private func config(interface: String = "", peer: String = "", endpoint: String = "vpn.example.com:51820") -> String {
        """
        [Interface]
        PrivateKey = \(privateKey)
        Address = 10.0.0.2/32, fd00::2/128
        \(interface)

        [Peer]
        PublicKey = \(publicKey)
        Endpoint = \(endpoint)
        AllowedIPs = 0.0.0.0/0, ::/0
        \(peer)
        """
    }

    private func assertInvalid(_ text: String, mentioning fragment: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try WireGuardConfig(text: text), file: file, line: line) { error in
            guard case WireGuardConfig.ConfigError.invalid(let why) = error else { return XCTFail("\(error)", file: file, line: line) }
            XCTAssertTrue(why.contains(fragment), "'\(why)' should mention '\(fragment)'", file: file, line: line)
        }
    }

    func testParsesAWgQuickConfig() throws {
        let c = try WireGuardConfig(text: config(
            interface: "DNS = 1.1.1.1, 2606:4700:4700::1111, example.internal\nMTU = 1380\nListenPort = 51000",
            peer: "PresharedKey = \(presharedKey)\nPersistentKeepalive = 25"))
        XCTAssertEqual(c.privateKeyHex, String(repeating: "01", count: 32))
        XCTAssertEqual(c.addresses, ["10.0.0.2/32", "fd00::2/128"])
        XCTAssertEqual(c.dns, ["1.1.1.1", "2606:4700:4700::1111"], "search domains are not resolvers")
        XCTAssertEqual(c.mtu, 1380)
        XCTAssertEqual(c.listenPort, 51000)
        XCTAssertEqual(c.peers.count, 1)
        let peer = c.peers[0]
        XCTAssertEqual(peer.publicKeyHex, String(repeating: "02", count: 32))
        XCTAssertEqual(peer.presharedKeyHex, String(repeating: "03", count: 32))
        XCTAssertEqual(peer.endpointHost, "vpn.example.com")
        XCTAssertEqual(peer.endpointPort, 51820)
        XCTAssertEqual(peer.allowedIPs, ["0.0.0.0/0", "::/0"])
        XCTAssertEqual(peer.keepalive, 25)
        XCTAssertEqual(c.endpoints.map(\.host), ["vpn.example.com"])
    }

    func testIgnoresCommentsCaseAndUnknownKeys() throws {
        let c = try WireGuardConfig(text: config(interface: "# a comment\nPostUp = rm -rf /\nTable = off", peer: "publickey = \(publicKey) # trailing"))
        XCTAssertEqual(c.peers.count, 1)
        XCTAssertEqual(c.addresses.count, 2)
    }

    func testBracketedIPv6Endpoint() throws {
        let c = try WireGuardConfig(text: config(endpoint: "[2001:db8::1]:51820"))
        XCTAssertEqual(c.peers[0].endpointHost, "2001:db8::1")
        XCTAssertEqual(c.peers[0].endpointPort, 51820)
    }

    func testMultiplePeers() throws {
        let second = "[Peer]\nPublicKey = \(presharedKey)\nEndpoint = 198.51.100.1:443\nAllowedIPs = 10.1.0.0/16"
        let c = try WireGuardConfig(text: config() + "\n" + second)
        XCTAssertEqual(c.peers.map(\.endpointPort), [51820, 443])
    }

    func testRejectsBadKeys() {
        assertInvalid(config().replacingOccurrences(of: privateKey, with: "not-base64"), mentioning: "PrivateKey")
        assertInvalid(config().replacingOccurrences(of: publicKey, with: Data(count: 16).base64EncodedString()), mentioning: "PublicKey")
        assertInvalid(config(peer: "PresharedKey = short"), mentioning: "PresharedKey")
    }

    func testRejectsEndpointWithoutPort() {
        assertInvalid(config(endpoint: "vpn.example.com"), mentioning: "host:port")
        assertInvalid(config(endpoint: "vpn.example.com:http"), mentioning: "host:port")
    }

    func testRejectsMissingSections() {
        assertInvalid("[Peer]\nPublicKey = \(publicKey)\nEndpoint = a:1", mentioning: "PrivateKey")
        assertInvalid("[Interface]\nPrivateKey = \(privateKey)\n[Peer]\nPublicKey = \(publicKey)\nEndpoint = a:1", mentioning: "Address")
        assertInvalid("[Interface]\nPrivateKey = \(privateKey)\nAddress = 10.0.0.2/32", mentioning: "[Peer]")
        assertInvalid(config(endpoint: ":51820"), mentioning: "[Peer]")
    }
}
