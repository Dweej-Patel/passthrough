import XCTest
import CryptoKit
@testable import PassthroughCore
@testable import PhoneTransport

final class ShellGrantTests: XCTestCase {
    private struct Rig {
        let registry: PairingRegistry
        /// Stands in for the app's sealing key, published to `registry`.
        let sealing: P256.KeyAgreement.PrivateKey
        let server: ControlServer
        let client: ControlClient
        let events: Locked<[ControlClient.Event]>
        let cleanup: () -> Void
    }

    private func makeRig(sealed: Bool = true, onEvent: @escaping @Sendable (ControlClient.Event) -> Void) throws -> Rig {
        let suite = "\(PassthroughProtocol.identifier).tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let registry = PairingRegistry(defaults: defaults, secrets: InMemorySecrets())
        let sealing = P256.KeyAgreement.PrivateKey()
        if sealed { registry.publishShellSealingKey(sealing.publicKey) }
        let port = freePort()
        let server = ControlServer(port: port, socksPort: 7890, registry: registry, counter: ByteCounter()) {
            DeviceStatus(deviceName: "Test iPhone", hosting: "test")
        }
        try server.start()
        let device = PhoneDevice(id: "test", kind: .iPhone, label: "test", pairingSlot: "t", link: LoopbackLink())
        let events = Locked<[ControlClient.Event]>([])
        let client = ControlClient(device: device, port: port, identity: .init(clientID: "mac1", name: "MacBook", token: nil)) { event in
            events.set(events.get() + [event])
            onEvent(event)
        }
        return Rig(registry: registry, sealing: sealing, server: server, client: client, events: events) {
            client.close(); server.stop(); defaults.removePersistentDomain(forName: suite)
        }
    }

    private let cert = String(repeating: "b", count: 64)

    func testPairThenGrant() throws {
        let welcomed = expectation(description: "welcomed"), paired = expectation(description: "paired"), granted = expectation(description: "granted")
        let rig = try makeRig { event in
            switch event {
            case .welcomed: welcomed.fulfill()
            case .paired: paired.fulfill()
            case .shellGranted: granted.fulfill()
            default: break
            }
        }
        defer { rig.cleanup() }
        rig.client.connect()
        wait(for: [welcomed], timeout: 5)
        let (code, _) = rig.registry.issueCode()
        rig.client.pair(code: code)
        wait(for: [paired], timeout: 5)

        let key = WirelessLink.randomBytes(32)
        rig.client.grantShell(shellKey: key, certificateSHA256: cert, port: 7893, addresses: ["192.168.1.5", "fe80::1"], macName: "MacBook")
        wait(for: [granted], timeout: 5)

        guard case .shellGranted(let phoneID, let grantID) = rig.events.get().last else { return XCTFail() }
        XCTAssertEqual(phoneID, rig.registry.phoneID)
        XCTAssertNil(grantID, "no grant ID sent, none echoed")
        XCTAssertEqual(rig.registry.openedPendingShellKey(clientID: "mac1", with: rig.sealing), key)
        XCTAssertNotEqual(rig.registry.sealedPendingShellKey(clientID: "mac1"), key, "never stored as it came")
        let grant = try XCTUnwrap(rig.registry.clients.first?.shell)
        XCTAssertEqual(grant, ShellGrant(certSHA256: cert, port: 7893, addresses: ["192.168.1.5", "fe80::1"], macName: "MacBook"))
        rig.registry.clearPendingShellKey(clientID: "mac1")
        XCTAssertNil(rig.registry.sealedPendingShellKey(clientID: "mac1"))
    }

    private let irohID = String(repeating: "3f", count: 32)

    private func pairedRig() throws -> (Rig, XCTestExpectation) {
        let welcomed = expectation(description: "welcomed"), paired = expectation(description: "paired"), granted = expectation(description: "granted")
        let rig = try makeRig { event in
            switch event {
            case .welcomed: welcomed.fulfill()
            case .paired: paired.fulfill()
            case .shellGranted: granted.fulfill()
            default: break
            }
        }
        rig.client.connect()
        wait(for: [welcomed], timeout: 5)
        let (code, _) = rig.registry.issueCode()
        rig.client.pair(code: code)
        wait(for: [paired], timeout: 5)
        return (rig, granted)
    }

    func testGrantIDIsEchoed() throws {
        let (rig, granted) = try pairedRig()
        defer { rig.cleanup() }
        let id = String(repeating: "g", count: ControlEnvelope.maxGrantIDLength)
        rig.client.grantShell(shellKey: WirelessLink.randomBytes(32), certificateSHA256: cert, port: 7893, addresses: [], macName: "M", grantID: id)
        wait(for: [granted], timeout: 5)
        guard case .shellGranted(_, let echoed) = rig.events.get().last else { return XCTFail() }
        XCTAssertEqual(echoed, id)
    }

    func testOverlongGrantIDIsNotEchoed() throws {
        let (rig, granted) = try pairedRig()
        defer { rig.cleanup() }
        let id = String(repeating: "g", count: ControlEnvelope.maxGrantIDLength + 1)
        rig.client.grantShell(shellKey: WirelessLink.randomBytes(32), certificateSHA256: cert, port: 7893, addresses: [], macName: "M", grantID: id)
        wait(for: [granted], timeout: 5)
        guard case .shellGranted(_, let echoed) = rig.events.get().last else { return XCTFail() }
        XCTAssertNil(echoed, "the grant is stored; the bad ID is not echoed")
        XCTAssertNotNil(rig.registry.sealedPendingShellKey(clientID: "mac1"))
    }

    func testGrantWithIrohFieldsStoresTokenAsSecret() throws {
        let (rig, granted) = try pairedRig()
        defer { rig.cleanup() }
        rig.client.grantShell(shellKey: WirelessLink.randomBytes(32), certificateSHA256: cert, port: 7893, addresses: ["192.168.1.5"], macName: "MacBook",
                              irohID: irohID, irohRelay: "https://relay.example.com/", relayToken: "tok-secret")
        wait(for: [granted], timeout: 5)
        let client = try XCTUnwrap(rig.registry.clients.first)
        XCTAssertEqual(client.shell, ShellGrant(certSHA256: cert, port: 7893, addresses: ["192.168.1.5"], macName: "MacBook",
                                                irohID: irohID, irohRelay: "https://relay.example.com/"))
        XCTAssertEqual(rig.registry.relayToken(clientID: "mac1"), "tok-secret")
        let json = String(decoding: try JSONEncoder().encode(client), as: UTF8.self)
        XCTAssertFalse(json.contains("tok-secret"))
    }

    func testInvalidIrohFieldsDropOnlyTheIrohInfo() throws {
        let (rig, granted) = try pairedRig()
        defer { rig.cleanup() }
        rig.client.grantShell(shellKey: WirelessLink.randomBytes(32), certificateSHA256: cert, port: 7893, addresses: ["192.168.1.5"], macName: "M",
                              irohID: irohID, irohRelay: "http://relay.example.com/", relayToken: "tok-secret")
        wait(for: [granted], timeout: 5)
        XCTAssertEqual(rig.registry.clients.first?.shell, ShellGrant(certSHA256: cert, port: 7893, addresses: ["192.168.1.5"], macName: "M"))
        XCTAssertNotNil(rig.registry.sealedPendingShellKey(clientID: "mac1"))
        XCTAssertNil(rig.registry.relayToken(clientID: "mac1"))
    }

    func testOldGrantJSONDecodes() throws {
        let json = #"{"certSHA256":"bb","port":7893,"addresses":["10.0.0.1"],"macName":"Old"}"#
        let grant = try JSONDecoder().decode(ShellGrant.self, from: Data(json.utf8))
        XCTAssertNil(grant.irohID)
        XCTAssertNil(grant.irohRelay)
        XCTAssertEqual(grant.macName, "Old")
    }

    func testUpdateShellInfoKeepsKeyAndCert() {
        let suite = "\(PassthroughProtocol.identifier).tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let secrets = InMemorySecrets()
        let registry = PairingRegistry(defaults: defaults, secrets: secrets)
        let sealing = P256.KeyAgreement.PrivateKey()
        registry.publishShellSealingKey(sealing.publicKey)
        let (code, _) = registry.issueCode()
        guard case .success = registry.pair(code: code, clientID: "mac1", name: "m") else { return XCTFail("pairing failed") }
        let key = WirelessLink.randomBytes(32)
        // No grant yet: nothing to update.
        XCTAssertFalse(registry.updateShellInfo(clientID: "mac1", irohID: irohID, irohRelay: nil, relayToken: nil, addresses: nil))
        XCTAssertTrue(registry.grantShell(clientID: "mac1", grant: ShellGrant(certSHA256: cert, port: 7893, addresses: ["10.0.0.1"], macName: "m"), shellKey: key))

        let many = (0..<20).map { "10.0.0.\($0)" }
        XCTAssertTrue(registry.updateShellInfo(clientID: "mac1", irohID: irohID, irohRelay: "https://r.example.com/", relayToken: "tk", addresses: many))
        var grant = registry.clients.first?.shell
        XCTAssertEqual(grant?.irohID, irohID)
        XCTAssertEqual(grant?.irohRelay, "https://r.example.com/")
        XCTAssertEqual(grant?.addresses.count, 16)
        XCTAssertEqual(grant?.certSHA256, cert)
        XCTAssertEqual(registry.openedPendingShellKey(clientID: "mac1", with: sealing), key)
        XCTAssertEqual(registry.relayToken(clientID: "mac1"), "tk")

        // Invalid iroh details change nothing about the stored ones, but valid addresses still apply.
        XCTAssertTrue(registry.updateShellInfo(clientID: "mac1", irohID: "nope", irohRelay: nil, relayToken: "x", addresses: ["10.9.9.9"]))
        XCTAssertEqual(registry.relayToken(clientID: "mac1"), "tk")
        XCTAssertEqual(registry.clients.first?.shell?.irohID, irohID)
        XCTAssertEqual(registry.clients.first?.shell?.addresses, ["10.9.9.9"])
        // An absent token clears the stored one; absent addresses keep them.
        XCTAssertTrue(registry.updateShellInfo(clientID: "mac1", irohID: irohID, irohRelay: nil, relayToken: nil, addresses: nil))
        grant = registry.clients.first?.shell
        XCTAssertNil(grant?.irohRelay)
        XCTAssertEqual(grant?.addresses, ["10.9.9.9"])
        XCTAssertNil(registry.relayToken(clientID: "mac1"))
        // No id: the Mac has no iroh; stored details go and a token alone is never stored.
        XCTAssertTrue(registry.updateShellInfo(clientID: "mac1", irohID: irohID, irohRelay: "https://r.example.com/", relayToken: "tk", addresses: nil))
        XCTAssertTrue(registry.updateShellInfo(clientID: "mac1", irohID: nil, irohRelay: "https://r.example.com/", relayToken: "tk", addresses: nil))
        XCTAssertNil(registry.clients.first?.shell?.irohID)
        XCTAssertNil(registry.clients.first?.shell?.irohRelay)
        XCTAssertNil(registry.relayToken(clientID: "mac1"))

        XCTAssertTrue(registry.updateShellInfo(clientID: "mac1", irohID: irohID, irohRelay: nil, relayToken: "tk2", addresses: nil))
        registry.revokeAll()
        XCTAssertNil(secrets.read("shell.relayToken.mac1"))
        XCTAssertTrue(registry.updateShellInfo(clientID: "mac1", irohID: irohID, irohRelay: nil, relayToken: nil, addresses: nil) == false)
        XCTAssertTrue(registry.clients.isEmpty)
    }

    func testRevokeAllDeletesRelayTokens() {
        let suite = "\(PassthroughProtocol.identifier).tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let secrets = InMemorySecrets()
        let registry = PairingRegistry(defaults: defaults, secrets: secrets)
        let sealing = P256.KeyAgreement.PrivateKey()
        registry.publishShellSealingKey(sealing.publicKey)
        for id in ["a", "b"] {
            let (code, _) = registry.issueCode()
            guard case .success = registry.pair(code: code, clientID: id, name: id) else { return XCTFail("pairing failed") }
            XCTAssertTrue(registry.grantShell(clientID: id, grant: ShellGrant(certSHA256: cert, port: 7893, addresses: [], macName: id, irohID: irohID),
                                              shellKey: WirelessLink.randomBytes(32), relayToken: "tok-" + id))
        }
        XCTAssertEqual(registry.relayToken(clientID: "a"), "tok-a")
        registry.revokeAll()
        XCTAssertNil(secrets.read("shell.relayToken.a"))
        XCTAssertNil(secrets.read("shell.relayToken.b"))
    }

    func testGrantRequiresAuthentication() throws {
        let welcomed = expectation(description: "welcomed")
        let rig = try makeRig { if case .welcomed = $0 { welcomed.fulfill() } }
        defer { rig.cleanup() }
        rig.client.connect()
        wait(for: [welcomed], timeout: 5)
        rig.client.grantShell(shellKey: WirelessLink.randomBytes(32), certificateSHA256: cert, port: 7893, addresses: [], macName: "MacBook")
        // A ping round trip later the grant has been seen (and ignored).
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertFalse(rig.events.get().contains { if case .shellGranted = $0 { return true } else { return false } })
        XCTAssertNil(rig.registry.sealedPendingShellKey(clientID: "mac1"))
    }

    func testBadKeyIsIgnored() throws {
        let welcomed = expectation(description: "welcomed"), paired = expectation(description: "paired"), granted = expectation(description: "granted")
        let rig = try makeRig { event in
            switch event {
            case .welcomed: welcomed.fulfill()
            case .paired: paired.fulfill()
            case .shellGranted: granted.fulfill()
            default: break
            }
        }
        defer { rig.cleanup() }
        rig.client.connect()
        wait(for: [welcomed], timeout: 5)
        let (code, _) = rig.registry.issueCode()
        rig.client.pair(code: code)
        wait(for: [paired], timeout: 5)

        rig.client.grantShell(shellKey: Data(repeating: 1, count: 16), certificateSHA256: cert, port: 7893, addresses: [], macName: "M")
        rig.client.grantShell(shellKey: WirelessLink.randomBytes(32), certificateSHA256: "zz" + String(repeating: "b", count: 62), port: 7893, addresses: [], macName: "M")
        // Fullwidth digits are hex digits to Character.isHexDigit, but not ASCII hex.
        let fullwidth = String(repeating: "\u{FF10}", count: 2) + String(cert.dropFirst(2))
        XCTAssertTrue(fullwidth.allSatisfy(\.isHexDigit))
        rig.client.grantShell(shellKey: WirelessLink.randomBytes(32), certificateSHA256: fullwidth, port: 7893, addresses: [], macName: "M")
        rig.client.grantShell(shellKey: WirelessLink.randomBytes(32), certificateSHA256: cert, port: 0, addresses: [], macName: "M")
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertNil(rig.registry.sealedPendingShellKey(clientID: "mac1"))
        XCTAssertNil(rig.registry.clients.first?.shell)

        // A valid grant afterwards still works: the channel survived.
        rig.client.grantShell(shellKey: WirelessLink.randomBytes(32), certificateSHA256: cert, port: 7893, addresses: [], macName: "M")
        wait(for: [granted], timeout: 5)
    }

    func testRevokeDeletesShellGrant() {
        let suite = "\(PassthroughProtocol.identifier).tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let secrets = InMemorySecrets()
        let registry = PairingRegistry(defaults: defaults, secrets: secrets)
        let sealing = P256.KeyAgreement.PrivateKey()
        registry.publishShellSealingKey(sealing.publicKey)
        for id in ["mac1", "mac2"] {
            let (code, _) = registry.issueCode()
            guard case .success = registry.pair(code: code, clientID: id, name: id) else { return XCTFail("pairing failed") }
            XCTAssertTrue(registry.grantShell(clientID: id, grant: ShellGrant(certSHA256: cert, port: 7893, addresses: [], macName: id), shellKey: WirelessLink.randomBytes(32)))
        }
        XCTAssertFalse(registry.grantShell(clientID: "unknown", grant: ShellGrant(certSHA256: cert, port: 7893, addresses: [], macName: "x"), shellKey: WirelessLink.randomBytes(32)))
        XCTAssertNil(secrets.read("shell.pending.unknown"))

        registry.revoke(clientID: "mac1")
        XCTAssertNil(registry.sealedPendingShellKey(clientID: "mac1"))
        XCTAssertNotNil(registry.sealedPendingShellKey(clientID: "mac2"))
        registry.revokeAll()
        XCTAssertNil(registry.sealedPendingShellKey(clientID: "mac2"))
        XCTAssertTrue(registry.clients.isEmpty)
    }

    func testStorageFailureDoesNotRecordGrant() {
        final class Refusing: SecretStore, @unchecked Sendable {
            func read(_ account: String) -> Data? { nil }
            func write(_ data: Data, account: String) -> Bool { false }
            func delete(_ account: String) {}
        }
        let suite = "\(PassthroughProtocol.identifier).tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let registry = PairingRegistry(defaults: defaults, secrets: Refusing())
        registry.publishShellSealingKey(P256.KeyAgreement.PrivateKey().publicKey)
        let (code, _) = registry.issueCode()
        guard case .success = registry.pair(code: code, clientID: "mac1", name: "M") else { return XCTFail("pairing failed") }
        XCTAssertFalse(registry.grantShell(clientID: "mac1", grant: ShellGrant(certSHA256: cert, port: 7893, addresses: [], macName: "M"), shellKey: WirelessLink.randomBytes(32)))
        XCTAssertNil(registry.clients.first?.shell)
    }

    /// Before the app has published its sealing key, a grant is neither stored
    /// nor answered: the key is never kept unsealed, and the Mac grants again later.
    func testGrantWithoutSealingKeyIsNotStoredOrAnswered() throws {
        let welcomed = expectation(description: "welcomed"), paired = expectation(description: "paired"), granted = expectation(description: "granted")
        let rig = try makeRig(sealed: false) { event in
            switch event {
            case .welcomed: welcomed.fulfill()
            case .paired: paired.fulfill()
            case .shellGranted: granted.fulfill()
            default: break
            }
        }
        defer { rig.cleanup() }
        rig.client.connect()
        wait(for: [welcomed], timeout: 5)
        let (code, _) = rig.registry.issueCode()
        rig.client.pair(code: code)
        wait(for: [paired], timeout: 5)

        rig.client.grantShell(shellKey: WirelessLink.randomBytes(32), certificateSHA256: cert, port: 7893, addresses: [], macName: "M")
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertFalse(rig.events.get().contains { if case .shellGranted = $0 { return true } else { return false } })
        XCTAssertNil(rig.registry.sealedPendingShellKey(clientID: "mac1"))
        XCTAssertNil(rig.registry.clients.first?.shell)
        XCTAssertFalse(rig.registry.grantShell(clientID: "mac1", grant: ShellGrant(certSHA256: cert, port: 7893, addresses: [], macName: "M"),
                                               shellKey: WirelessLink.randomBytes(32)))

        // Once the app has opened and published its key, the Mac's next grant lands.
        rig.registry.publishShellSealingKey(rig.sealing.publicKey)
        let key = WirelessLink.randomBytes(32)
        rig.client.grantShell(shellKey: key, certificateSHA256: cert, port: 7893, addresses: [], macName: "M")
        wait(for: [granted], timeout: 5)
        XCTAssertEqual(rig.registry.openedPendingShellKey(clientID: "mac1", with: rig.sealing), key)
    }

    /// Paired Macs saved before shell grants existed must still load.
    func testOldPairedClientStillDecodes() throws {
        let json = #"[{"id":"mac1","name":"M","tokenHash":"h","pairedAt":0,"linkCertificate":"abc"}]"#
        let list = try JSONDecoder().decode([PairedClient].self, from: Data(json.utf8))
        XCTAssertEqual(list.first?.id, "mac1")
        XCTAssertNil(list.first?.shell)
        let roundTrip = try JSONDecoder().decode([PairedClient].self, from: JSONEncoder().encode(list))
        XCTAssertEqual(roundTrip, list)
    }
}

extension PairingRegistry {
    /// What the app would open from `clientID`'s pending entry with its sealing key.
    func openedPendingShellKey(clientID: String, with sealing: P256.KeyAgreement.PrivateKey) -> Data? {
        guard let stored = sealedPendingShellKey(clientID: clientID) else { return nil }
        return try? ShellKeySeal.open(stored, clientID: clientID, recipient: sealing.publicKey) {
            try sealing.sharedSecretFromKeyAgreement(with: $0)
        }.get()
    }
}
