import XCTest
import CryptoKit
@testable import VPNConfig

final class NordPinningTests: XCTestCase {
    private let host = "us1234.nordvpn.com"
    private let ca = "-----BEGIN CERTIFICATE-----\nMIIBstandin\n-----END CERTIFICATE-----"
    private var caHash: String { SHA256.hash(data: Data(ca.utf8)).map { String(format: "%02x", $0) }.joined() }

    private func profile(ca: String? = nil, pinnedName: String? = nil, certTLS: Bool = true) -> String {
        var lines = ["client", "remote 203.0.113.7 1194"]
        if certTLS { lines.append("remote-cert-tls server") }
        lines.append("verify-x509-name CN=\(pinnedName ?? host)")
        lines.append("<ca>\n\(ca ?? self.ca)\n</ca>")
        return lines.joined(separator: "\n") + "\n"
    }

    private func verify(_ text: String) throws {
        try NordPinning.verify(profileText: text, host: host, expectedCASHA256: caHash)
    }

    func testAcceptsAProfileWithTheRightCAPinningThisServer() {
        XCTAssertNoThrow(try verify(profile()))
    }

    func testRefusesAnotherCA() {
        XCTAssertThrowsError(try verify(profile(ca: "-----BEGIN CERTIFICATE-----\nMIIBother\n-----END CERTIFICATE-----"))) { error in
            XCTAssertEqual(error as? NordPinning.Failure, .wrongCA)
        }
    }

    func testRefusesAProfilePinningAnotherServer() {
        XCTAssertThrowsError(try verify(profile(pinnedName: "us9999.nordvpn.com"))) { error in
            XCTAssertEqual(error as? NordPinning.Failure, .notPinned(host))
        }
    }

    func testRefusesAProfileWithoutServerCertCheck() {
        XCTAssertThrowsError(try verify(profile(certTLS: false))) { error in
            XCTAssertEqual(error as? NordPinning.Failure, .notPinned(host))
        }
    }

    func testRefusesAProfileWithoutACA() {
        // The parser requires an inline CA, so this never gets as far as the pin.
        XCTAssertThrowsError(try verify("client\nremote-cert-tls server\nverify-x509-name CN=\(host)\n")) { error in
            XCTAssertEqual(error as? NordPinning.Failure, .invalidProfile)
        }
    }

    func testAcceptsWindowsLineEndings() {
        XCTAssertNoThrow(try verify(profile().replacingOccurrences(of: "\n", with: "\r\n")))
    }

    // The pin is checked on the parsed profile, which is what openvpn runs, so
    // text that merely contains the right values somewhere is not enough.

    func testRefusesASecondCAAfterNords() {
        let attacker = "-----BEGIN CERTIFICATE-----\nMIIBattacker\n-----END CERTIFICATE-----"
        for tag in ["ca", "CA"] {
            XCTAssertThrowsError(try verify(profile() + "<\(tag)>\n\(attacker)\n</\(tag)>\n"), tag) {
                XCTAssertEqual($0 as? NordPinning.Failure, .invalidProfile)
            }
        }
    }

    func testRefusesASecondServerName() {
        for override in ["verify-x509-name attacker.example", "VERIFY-X509-NAME CN=attacker.example"] {
            XCTAssertThrowsError(try verify(profile() + override + "\n")) { XCTAssertEqual($0 as? NordPinning.Failure, .invalidProfile) }
        }
    }

    func testRefusesALooserServerName() {
        for pinned in ["\(host).evil", "\(host) name-prefix"] {
            XCTAssertThrowsError(try verify(profile(pinnedName: pinned)), pinned)
        }
        let commented = profile().replacingOccurrences(of: "verify-x509-name CN=\(host)", with: "# verify-x509-name CN=\(host)")
        XCTAssertThrowsError(try verify(commented)) { XCTAssertEqual($0 as? NordPinning.Failure, .notPinned(self.host)) }
    }

    func testDefaultsToNordsRootCA() {
        XCTAssertEqual(NordPinning.caSHA256, "0f3e5da3a16471b1885bc1cfbc1965796e0c23b95c4af5beaa75bb4bab629a03")
        XCTAssertThrowsError(try NordPinning.verify(profileText: profile(), host: host))
    }
}
