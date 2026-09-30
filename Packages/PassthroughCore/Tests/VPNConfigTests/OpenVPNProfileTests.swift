import XCTest
@testable import VPNConfig

/// The OpenVPN allowlist is what stands between an imported file and a root
/// `openvpn` process, so these tests pin down both what it refuses and the
/// exact canonical text it hands on.
final class OpenVPNProfileTests: XCTestCase {
    private let ca = "<ca>\n-----BEGIN CERTIFICATE-----\nMIIBfake\n-----END CERTIFICATE-----\n</ca>"

    private func profile(_ body: String) throws -> OpenVPNProfile {
        try OpenVPNProfile(text: "client\nremote vpn.example.com 1194\n\(body)\n\(ca)\n")
    }

    private func assertForbidden(_ line: String, file: StaticString = #filePath, line l: UInt = #line) {
        XCTAssertThrowsError(try profile(line), "'\(line)' should be refused", file: file, line: l) { error in
            guard case OpenVPNProfile.ProfileError.forbidden = error else {
                return XCTFail("'\(line)' refused as \(error), expected .forbidden", file: file, line: l)
            }
        }
    }

    // MARK: Refused

    func testRefusesScriptHooks() {
        for d in ["up /tmp/x.sh", "down /tmp/x.sh", "route-up /tmp/x", "ipchange /tmp/x", "tls-verify /tmp/x",
                  "auth-user-pass-verify /tmp/x via-env", "learn-address /tmp/x", "client-connect /tmp/x"] {
            assertForbidden(d)
        }
    }

    func testRefusesCodeLoadingAndPrivilegeDirectives() {
        for d in ["plugin /tmp/evil.so", "script-security 2", "config /etc/other.conf", "daemon", "chroot /tmp",
                  "user nobody", "cd /tmp", "setenv-safe X 1", "engine dynamic", "providers legacy"] {
            assertForbidden(d)
        }
    }

    func testRefusesFileWritesAndSockets() {
        for d in ["log /tmp/o.log", "log-append /tmp/o.log", "writepid /tmp/p", "status /tmp/s", "management 127.0.0.1 7505",
                  "management-client", "management-anything-new", "http-proxy 1.2.3.4 8080", "socks-proxy 1.2.3.4",
                  "bind", "local 0.0.0.0", "lport 1194"] {
            assertForbidden(d)
        }
    }

    func testRefusesCompressionAndStaticKeys() {
        for d in ["compress lz4", "allow-compression yes", "secret static.key", "mode server", "server 10.8.0.0 255.255.255.0"] {
            assertForbidden(d)
        }
    }

    func testRefusesDoubleDashAndUppercaseSpellings() {
        assertForbidden("--up /tmp/x.sh")
        assertForbidden("UP /tmp/x.sh")
        assertForbidden("  \tPlugin /tmp/evil.so")
    }

    func testRefusesAuthUserPassWithAFile() {
        assertForbidden("auth-user-pass /etc/passwd")
        XCTAssertNoThrow(try profile("auth-user-pass"))
    }

    func testRefusesUnknownDirectives() {
        XCTAssertThrowsError(try profile("some-future-directive 1")) { error in
            guard case OpenVPNProfile.ProfileError.unsupported("some-future-directive") = error else { return XCTFail("\(error)") }
        }
    }

    func testRefusesWeakCiphersAndDigests() {
        for d in ["cipher BF-CBC", "cipher NONE", "data-ciphers AES-256-GCM:BF-CBC", "auth MD5", "auth none",
                  "tls-version-min 1.0", "remote-cert-tls client", "comp-lzo yes"] {
            XCTAssertThrowsError(try profile(d), "'\(d)' should be refused")
        }
    }

    func testRefusesBadRemoteArguments() {
        for d in ["remote host;rm 1194", "remote vpn.example.com 70000", "remote vpn.example.com 1194 sctp"] {
            XCTAssertThrowsError(try profile(d), "'\(d)' should be refused")
        }
    }

    func testRefusesUnknownAndUnterminatedBlocks() {
        XCTAssertThrowsError(try profile("<connection>\nremote x 1\n</connection>")) { error in
            guard case OpenVPNProfile.ProfileError.badBlock("connection") = error else { return XCTFail("\(error)") }
        }
        XCTAssertThrowsError(try OpenVPNProfile(text: "client\nremote vpn.example.com 1194\n<ca>\nMIIB\n")) { error in
            guard case OpenVPNProfile.ProfileError.badBlock("ca") = error else { return XCTFail("\(error)") }
        }
    }

    func testRequiresInlineCAAndRemote() {
        XCTAssertThrowsError(try OpenVPNProfile(text: "client\nremote vpn.example.com 1194\n")) { error in
            guard case OpenVPNProfile.ProfileError.missing = error else { return XCTFail("\(error)") }
        }
        XCTAssertThrowsError(try OpenVPNProfile(text: "client\n\(ca)\n")) { error in
            guard case OpenVPNProfile.ProfileError.missing = error else { return XCTFail("\(error)") }
        }
    }

    // MARK: Accepted and canonicalised

    func testCanonicalisesAVendorProfile() throws {
        let text = """
        client
        dev tun
        proto udp
        remote 203.0.113.7 1194
        resolv-retry infinite
        remote-random
        nobind
        tun-mtu 1500
        tun-mtu-extra 32
        mssfix 1450
        persist-key
        persist-tun
        ping 15
        ping-restart 0
        reneg-sec 0
        comp-lzo no
        verify-x509-name CN=us1234.nordvpn.com
        remote-cert-tls server
        auth-user-pass
        verb 3
        pull
        fast-io
        cipher AES-256-CBC
        auth SHA512
        \(ca)
        key-direction 1
        <tls-auth>
        -----BEGIN OpenVPN Static key V1-----
        abcd
        -----END OpenVPN Static key V1-----
        </tls-auth>
        """
        let p = try OpenVPNProfile(text: text)
        XCTAssertEqual(p.canonicalText, """
        client
        proto udp
        remote 203.0.113.7 1194
        remote-random
        tun-mtu 1500
        tun-mtu-extra 32
        mssfix 1450
        reneg-sec 0
        comp-lzo no
        verify-x509-name CN=us1234.nordvpn.com
        remote-cert-tls server
        auth-user-pass
        pull
        cipher AES-256-CBC
        auth SHA512
        <ca>
        -----BEGIN CERTIFICATE-----
        MIIBfake
        -----END CERTIFICATE-----
        </ca>
        key-direction 1
        <tls-auth>
        -----BEGIN OpenVPN Static key V1-----
        abcd
        -----END OpenVPN Static key V1-----
        </tls-auth>

        """)
        XCTAssertEqual(p.endpoints.map(\.host), ["203.0.113.7"])
        XCTAssertEqual(p.endpoints.map(\.port), [1194])
        XCTAssertEqual(p.tunMTU, 1500)
        XCTAssertEqual(p.verifyX509Name, "CN=us1234.nordvpn.com")
        XCTAssertEqual(p.inlineCA, "-----BEGIN CERTIFICATE-----\nMIIBfake\n-----END CERTIFICATE-----")
    }

    func testDropsDirectivesTheHelperOverrides() throws {
        let p = try profile("redirect-gateway def1\ndhcp-option DNS 10.0.0.1\nroute 10.0.0.0 255.0.0.0\nblock-outside-dns\npull-filter ignore x")
        XCTAssertEqual(p.canonicalText.components(separatedBy: "\n").first { $0.hasPrefix("<") }, "<ca>")
        XCTAssertFalse(p.canonicalText.contains("redirect-gateway"))
        XCTAssertFalse(p.canonicalText.contains("dhcp-option"))
        XCTAssertFalse(p.canonicalText.contains("route "))
    }

    func testNormalisesCase() throws {
        let p = try profile("PROTO TCP\ncipher aes-256-gcm\ndata-ciphers aes-256-gcm:chacha20-poly1305")
        XCTAssertTrue(p.canonicalText.contains("proto tcp\n"))
        XCTAssertTrue(p.canonicalText.contains("cipher AES-256-GCM\n"))
        XCTAssertTrue(p.canonicalText.contains("data-ciphers AES-256-GCM:CHACHA20-POLY1305\n"))
    }

    func testDefaultsTheRemotePortAndKeepsItsProtocol() throws {
        let p = try OpenVPNProfile(text: "remote a.example.com\nremote b.example.com 443 TCP\n\(ca)\n")
        XCTAssertEqual(p.endpoints.map(\.port), [1194, 443])
        XCTAssertTrue(p.canonicalText.hasPrefix("remote a.example.com 1194\nremote b.example.com 443 tcp\n"))
    }

    func testAcceptsWindowsLineEndings() throws {
        let p = try OpenVPNProfile(text: "client\r\nremote vpn.example.com 1194\r\n\(ca.replacingOccurrences(of: "\n", with: "\r\n"))\r\n")
        XCTAssertEqual(p.endpoints.count, 1)
        XCTAssertNotNil(p.inlineCA)
    }

    // MARK: Tokeniser (OpenVPN's parse_line rules)

    func testTokenizerSplitsOnWhitespace() {
        XCTAssertEqual(OpenVPNProfile.tokenize("remote  host\t1194"), ["remote", "host", "1194"])
    }

    func testTokenizerHonoursQuotesAndEscapes() {
        XCTAssertEqual(OpenVPNProfile.tokenize(#"verify-x509-name "CN=a b" name"#), ["verify-x509-name", "CN=a b", "name"])
        XCTAssertEqual(OpenVPNProfile.tokenize(#"x 'a\b'"#), ["x", #"a\b"#])
        XCTAssertEqual(OpenVPNProfile.tokenize(#"x a\ b"#), ["x", "a b"])
        XCTAssertEqual(OpenVPNProfile.tokenize(#"x "#), ["x"])
    }

    func testTokenizerStopsAtCommentsOnlyBetweenTokens() {
        XCTAssertEqual(OpenVPNProfile.tokenize("# whole line"), [])
        XCTAssertEqual(OpenVPNProfile.tokenize("; whole line"), [])
        XCTAssertEqual(OpenVPNProfile.tokenize("remote host 1194 # trailing"), ["remote", "host", "1194"])
        XCTAssertEqual(OpenVPNProfile.tokenize("x a#b"), ["x", "a#b"])
    }

    func testACommentCannotHideADirective() {
        // "up" behind a quoted '#' is still a token OpenVPN would read.
        assertForbidden(#""up" /tmp/x.sh"#)
    }
}
