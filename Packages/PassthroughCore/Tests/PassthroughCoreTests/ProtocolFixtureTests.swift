import XCTest
import Network
@testable import PassthroughCore

/// Checks this package against protocol/fixtures.json, the same file the
/// Android tests read, so the phone and Mac sides can't drift apart.
final class ProtocolFixtureTests: XCTestCase {
    private func fixtures() throws -> [String: Any] {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while dir.path != "/" {
            let file = dir.appendingPathComponent("protocol/fixtures.json")
            if FileManager.default.fileExists(atPath: file.path) {
                return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
            }
            dir.deleteLastPathComponent()
        }
        throw XCTSkip("protocol/fixtures.json not found")
    }

    func testConstantsMatch() throws {
        let f = try fixtures()
        XCTAssertEqual(f["protocolVersion"] as? Int, PassthroughProtocol.version)
        let ports = try XCTUnwrap(f["ports"] as? [String: Int])
        XCTAssertEqual(ports["socks"], Int(PassthroughProtocol.defaultSOCKSPort))
        XCTAssertEqual(ports["control"], Int(PassthroughProtocol.defaultControlPort))
        XCTAssertEqual(f["pairingCodeLifetimeSeconds"] as? Double, PassthroughProtocol.pairingCodeLifetime)
        let failures = try XCTUnwrap(f["pairingFailures"] as? [String])
        XCTAssertEqual(failures.compactMap(PairingFailure.init(rawValue:)).count, failures.count)
    }

    func testTokensHashAndValidateAlike() throws {
        for t in try XCTUnwrap(fixtures()["tokens"] as? [[String: Any]]) {
            let token = try XCTUnwrap(t["token"] as? String)
            XCTAssertEqual(PairingToken.hash(token), t["sha256"] as? String, token)
            XCTAssertEqual(PairingToken.isWellFormed(token), t["wellFormed"] as? Bool, token)
        }
        XCTAssertTrue(PairingToken.isWellFormed(PairingToken.generate()))
    }

    /// Every field survives a decode and re-encode, and nothing extra (like nulls) is added.
    func testMessagesRoundTrip() throws {
        for m in try XCTUnwrap(fixtures()["messages"] as? [[String: Any]]) {
            let line = try XCTUnwrap(m["line"] as? String)
            var buffer = LineBuffer()
            let framed = try buffer.append(Data((line + "\n").utf8))
            XCTAssertEqual(framed.count, 1)
            let decoded = try ControlEnvelope.decode(framed[0])
            let original = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? NSDictionary
            let reencoded = try JSONSerialization.jsonObject(with: decoded.encodedLine()) as? NSDictionary
            XCTAssertEqual(original, reencoded, line)
        }
    }

    func testFormatsMatch() throws {
        let f = try fixtures()
        for r in try XCTUnwrap(f["rates"] as? [[String: Any]]) {
            let rate = ByteFormat.rate(try XCTUnwrap(r["bytesPerSecond"] as? Double))
            XCTAssertEqual(rate.value, r["value"] as? String)
            XCTAssertEqual(rate.unit, r["unit"] as? String)
        }
        for d in try XCTUnwrap(f["durations"] as? [[String: Any]]) {
            XCTAssertEqual(ByteFormat.duration(try XCTUnwrap(d["seconds"] as? Double)), d["text"] as? String)
        }
    }

    func testDNSRedirectRules() throws {
        let f = try XCTUnwrap(fixtures()["dnsRedirect"] as? [String: Any])
        XCTAssertEqual(f["port"] as? Int, Int(DNSRedirect.port))
        XCTAssertEqual(f["fallback"] as? String, DNSRedirect.fallback)
        for d in try XCTUnwrap(f["destinations"] as? [[String: Any]]) {
            let text = try XCTUnwrap(d["address"] as? String)
            let port = UInt16(try XCTUnwrap(d["port"] as? Int))
            let portBytes = [UInt8(port >> 8), UInt8(port & 0xFF)]
            let raw: Data
            if let v4 = IPv4Address(text) { raw = Data([SOCKS5.AddressType.ipv4]) + v4.rawValue + portBytes }
            else { raw = Data([SOCKS5.AddressType.ipv6]) + (try XCTUnwrap(IPv6Address(text))).rawValue + portBytes }
            let address = try XCTUnwrap(SOCKS5.Address(raw: raw))
            XCTAssertEqual(DNSRedirect.applies(to: address), d["redirect"] as? Bool, "\(text):\(port)")
        }
        for c in try XCTUnwrap(f["serverChoice"] as? [[String: Any]]) {
            XCTAssertEqual(DNSRedirect.server(from: try XCTUnwrap(c["system"] as? [String])), c["chosen"] as? String)
        }
        // Reads the real resolver configuration without crashing; the list depends on the machine.
        _ = DNSRedirect.systemServers()
    }

    func testLocalDestinations() throws {
        let f = try XCTUnwrap(fixtures()["localDestinations"] as? [String: Any])
        func name(_ text: String) -> SOCKS5.Address? {
            SOCKS5.Address(raw: Data([SOCKS5.AddressType.domain, UInt8(text.utf8.count)] + Array(text.utf8) + [1, 187]))
        }
        for d in try XCTUnwrap(f["addresses"] as? [[String: Any]]) {
            let text = try XCTUnwrap(d["ip"] as? String)
            let local = try XCTUnwrap(d["local"] as? Bool)
            let host: NWEndpoint.Host
            let raw: Data
            if let v4 = IPv4Address(text) { host = .ipv4(v4); raw = Data([SOCKS5.AddressType.ipv4]) + v4.rawValue + [1, 187] }
            else {
                let v6 = try XCTUnwrap(IPv6Address(text), text)
                host = .ipv6(v6); raw = Data([SOCKS5.AddressType.ipv6]) + v6.rawValue + [1, 187]
            }
            XCTAssertEqual(try XCTUnwrap(SOCKS5.Address(raw: raw)).isLocalOnly, local, text)
            XCTAssertEqual(try XCTUnwrap(name(text)).isLocalOnly, local, "\(text) as a name")
            // What a name resolved to, as a ready connection reports it.
            XCTAssertEqual(SOCKS5.Address.isLocal(endpoint: .hostPort(host: host, port: 443)), local, "\(text) reached")
        }
        for d in try XCTUnwrap(f["names"] as? [[String: Any]]) {
            let text = try XCTUnwrap(d["name"] as? String)
            XCTAssertEqual(try XCTUnwrap(name(text)).isLocalOnly, d["local"] as? Bool, text)
        }
        XCTAssertFalse(SOCKS5.Address.isLocal(endpoint: nil))
        XCTAssertFalse(SOCKS5.Address.isLocal(endpoint: .hostPort(host: "localhost", port: 80)), "only addresses count once reached")
    }
}
