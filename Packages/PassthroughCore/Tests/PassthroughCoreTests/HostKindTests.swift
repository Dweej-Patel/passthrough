import XCTest
@testable import PassthroughCore

/// Where the phone keeps what kind of computer each paired one is.
final class HostKindTests: XCTestCase {
    private var suite = ""
    private var defaults: UserDefaults!
    private var registry: PairingRegistry!

    override func setUp() {
        suite = "\(PassthroughProtocol.identifier).tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        registry = PairingRegistry(defaults: defaults, secrets: InMemorySecrets())
    }

    override func tearDown() { defaults.removePersistentDomain(forName: suite) }

    private func pair(_ id: String) {
        let code = registry.issueCode().code
        guard case .success = registry.pair(code: code, clientID: id, name: id) else { return XCTFail("pairing failed") }
    }

    func testNoteHostKindRecordsOnceAndOnlyKnownKinds() {
        pair("pc1")
        XCTAssertNil(registry.clients.first?.hostKind)
        XCTAssertTrue(registry.noteHostKind(clientID: "pc1", kind: "windows"))
        XCTAssertEqual(registry.clients.first?.hostKind, "windows")
        XCTAssertFalse(registry.noteHostKind(clientID: "pc1", kind: "windows"), "unchanged")
        XCTAssertFalse(registry.noteHostKind(clientID: "pc1", kind: "toaster"), "a kind this build doesn't know")
        XCTAssertFalse(registry.noteHostKind(clientID: "pc1", kind: nil))
        XCTAssertFalse(registry.noteHostKind(clientID: "nobody", kind: "windows"), "not paired")
        XCTAssertEqual(registry.clients.first?.hostKind, "windows")
    }

    func testNoteHostKindLeavesIPadsAlone() {
        _ = registry.addClient(id: "pad", name: "iPad", kind: .ipad, certificateSHA256: String(repeating: "a", count: 64), linkKey: Data(count: 32))
        XCTAssertFalse(registry.noteHostKind(clientID: "pad", kind: "windows"))
        XCTAssertNil(registry.clients.first { $0.id == "pad" }?.hostKind)
    }

    /// A record saved before kinds were kept decodes, and is a Mac.
    func testOldPairedClientJSONIsAMac() throws {
        let json = #"[{"id":"m1","name":"MacBook","tokenHash":"abc","pairedAt":0}]"#
        let clients = try JSONDecoder().decode([PairedClient].self, from: Data(json.utf8))
        XCTAssertNil(clients[0].hostKind)
        XCTAssertEqual(Hosts.kind(live: nil, stored: clients[0].hostKind), .mac)
    }

    func testCredentialCarriesTheKind() {
        var client = PairedClient(id: "pc1", name: "Office-PC", tokenHash: "", pairedAt: Date())
        client.shell = ShellGrant(certSHA256: String(repeating: "b", count: 64), port: 7893, addresses: [], macName: "Office-PC", hostKind: "windows")
        let built = ShellCredentials.build(clients: [client], phoneID: "p", key: { _ in Data(count: 32) }, manualAddress: { _ in nil })
        XCTAssertEqual(built.first?.hostKind, "windows")
        client.hostKind = "mac"
        XCTAssertEqual(ShellCredentials.build(clients: [client], phoneID: "p", key: { _ in Data(count: 32) }, manualAddress: { _ in nil }).first?.hostKind,
                       "mac", "the registry's record beats the grant's")
    }

    func testConnectedPCsAreNotOnlineThroughThePhone() {
        let stats = ProviderStats(rx: 0, tx: 0, active: 0, totalConnections: 0,
                                  macs: [ConnectedMac(id: "m", name: "Mac", since: Date()),
                                         ConnectedMac(id: "p", name: "PC", since: Date(), hostKind: "windows"),
                                         ConnectedMac(id: "i", name: "iPad", since: Date(), kind: .ipad)],
                                  startedAt: nil)
        XCTAssertEqual(stats.connectedMacs.map(\.id), ["m"])
        XCTAssertEqual(stats.connectedPCs.map(\.id), ["p"])
        XCTAssertEqual(stats.connectedComputers.map(\.id), ["m", "p"])
    }

    /// `open` without a shell is the line it always was; with one it names it.
    func testOpenLine() throws {
        var m = ShellEnvelope(t: ShellEnvelope.open)
        m.cols = 80; m.rows = 24; m.ref = 1
        let plain = try JSONSerialization.jsonObject(with: JSONEncoder().encode(m)) as? [String: Any]
        XCTAssertEqual(Set(try XCTUnwrap(plain).keys), ["t", "cols", "rows", "ref"])
        m.shell = "wsl:Ubuntu"
        let named = try JSONSerialization.jsonObject(with: JSONEncoder().encode(m)) as? [String: Any]
        XCTAssertEqual(named?["shell"] as? String, "wsl:Ubuntu")
    }
}
