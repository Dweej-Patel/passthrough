import XCTest
import Network
@testable import PassthroughCore

final class ShellCredentialsTests: XCTestCase {
    private func client(_ id: String, shell: ShellGrant?) -> PairedClient {
        var c = PairedClient(id: id, name: id, tokenHash: "", pairedAt: Date())
        c.shell = shell
        return c
    }

    private let grant = ShellGrant(certSHA256: "ab", port: 7022, addresses: ["192.168.1.2", "100.64.0.1"], macName: "Studio")

    func testBuildsOnlyForGrantedMacsWithKeys() {
        let clients = [client("a", shell: grant), client("b", shell: nil), client("c", shell: grant)]
        let creds = ShellCredentials.build(clients: clients, phoneID: "phone",
                                           key: { $0 == "a" ? Data([1]) : nil }, manualAddress: { _ in nil })
        XCTAssertEqual(creds, [ShellCredential(macID: "a", macName: "Studio", certSHA256: "ab", shellKey: Data([1]),
                                               phoneID: "phone", port: 7022, addresses: ["192.168.1.2", "100.64.0.1"])])
    }

    func testCarriesIrohDetailsAndRelayToken() {
        let id = String(repeating: "ab", count: 32)
        let iroh = ShellGrant(certSHA256: "ab", port: 7022, addresses: [], macName: "Studio", irohID: id, irohRelay: "https://r.example.com/")
        let creds = ShellCredentials.build(clients: [client("a", shell: iroh), client("b", shell: grant)], phoneID: "phone",
                                           key: { _ in Data([1]) }, manualAddress: { _ in nil }, relayToken: { _ in "tok" })
        XCTAssertEqual(creds[0].irohID, id)
        XCTAssertEqual(creds[0].irohRelay, "https://r.example.com/")
        XCTAssertEqual(creds[0].relayToken, "tok")
        XCTAssertNil(creds[1].irohID)
        XCTAssertNil(creds[1].relayToken)
    }

    func testManualAddressComesFirstWithoutRepeats() {
        XCTAssertEqual(ShellCredentials.addresses(granted: ["10.0.0.2", "100.64.0.1"], manual: " 100.64.0.1 "), ["100.64.0.1", "10.0.0.2"])
        XCTAssertEqual(ShellCredentials.addresses(granted: ["10.0.0.2"], manual: "studio.tailnet.ts.net"), ["studio.tailnet.ts.net", "10.0.0.2"])
        XCTAssertEqual(ShellCredentials.addresses(granted: ["10.0.0.2"], manual: "   "), ["10.0.0.2"])
        XCTAssertEqual(ShellCredentials.addresses(granted: ["10.0.0.2"], manual: nil), ["10.0.0.2"])
    }

    private func service(_ name: String) -> NWEndpoint {
        .service(name: name, type: RemoteShell.serviceType, domain: "local.", interface: nil)
    }

    func testDiscoveredPrefersTheMacsName() {
        let results = [service("Other"), service("Studio")]
        XCTAssertEqual(ShellCredentials.discovered(among: results, macName: "Studio", shellMacCount: 2), service("Studio"))
    }

    func testDiscoveredFallsBackOnlyWhenUnambiguous() {
        XCTAssertEqual(ShellCredentials.discovered(among: [service("Studio (2)")], macName: "Studio", shellMacCount: 1), service("Studio (2)"))
        XCTAssertNil(ShellCredentials.discovered(among: [service("Studio (2)")], macName: "Studio", shellMacCount: 2))
        XCTAssertNil(ShellCredentials.discovered(among: [service("A"), service("B")], macName: "Studio", shellMacCount: 1))
        XCTAssertNil(ShellCredentials.discovered(among: [], macName: "Studio", shellMacCount: 1))
    }

    func testPrintingNeverShowsSecrets() {
        let key = Data(repeating: 0xAB, count: 32)
        let credential = ShellCredential(macID: "a", macName: "Studio", certSHA256: "ab", shellKey: key, phoneID: "phone",
                                         port: 7022, addresses: ["192.168.1.2"], irohID: "id", irohRelay: "https://r.example.com/",
                                         relayToken: "super-secret-token")
        var dumped = ""
        dump(credential, to: &dumped)
        for text in [String(describing: credential), String(reflecting: credential), "\(credential)", dumped] {
            XCTAssertFalse(text.contains("super-secret-token"), text)
            XCTAssertFalse(text.contains(key.base64EncodedString()), text)
            XCTAssertFalse(text.lowercased().contains("abababab"), text)
            XCTAssertFalse(text.contains("32 bytes"), text)
            XCTAssertTrue(text.contains("<redacted>"), text)
        }
    }
}
