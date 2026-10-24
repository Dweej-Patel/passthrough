import XCTest
import CryptoKit
@testable import PassthroughCore

final class ShellKeySealTests: XCTestCase {
    private let sealing = P256.KeyAgreement.PrivateKey()
    private let key = Data((0..<32).map { UInt8($0) })

    private func open(_ sealed: Data, clientID: String = "mac1", with recipient: P256.KeyAgreement.PrivateKey? = nil) -> Result<Data, ShellKeySeal.OpenError> {
        let recipient = recipient ?? sealing
        return ShellKeySeal.open(sealed, clientID: clientID, recipient: recipient.publicKey) { try recipient.sharedSecretFromKeyAgreement(with: $0) }
    }

    func testRoundTripAndFormat() throws {
        let sealed = try ShellKeySeal.seal(key, to: sealing.publicKey, clientID: "mac1")
        XCTAssertEqual(sealed.count, 1 + 65 + 12 + 32 + 16)
        XCTAssertEqual(sealed.first, ShellKeySeal.version)
        XCTAssertEqual(ShellKeySeal.format(of: sealed), .sealed)
        XCTAssertEqual(try open(sealed).get(), key)
        XCTAssertNil(sealed.range(of: key), "the key never appears as it came")
        // A fresh ephemeral key each time.
        XCTAssertNotEqual(sealed, try ShellKeySeal.seal(key, to: sealing.publicKey, clientID: "mac1"))
    }

    func testTamperedWrongMacOrWrongKeyIsUnreadable() throws {
        let sealed = try ShellKeySeal.seal(key, to: sealing.publicKey, clientID: "mac1")
        for i in [1, 40, 70, sealed.count - 20, sealed.count - 1] {
            var altered = sealed
            altered[i] ^= 0x01
            XCTAssertEqual(open(altered), .failure(.unreadable), "byte \(i)")
        }
        XCTAssertEqual(open(sealed, clientID: "mac2"), .failure(.unreadable), "sealed for another Mac")
        XCTAssertEqual(open(sealed, with: P256.KeyAgreement.PrivateKey()), .failure(.unreadable), "sealed to another key")
        XCTAssertEqual(open(sealed.prefix(sealed.count - 1)), .failure(.unreadable))
        var otherVersion = sealed
        otherVersion[0] = 2
        XCTAssertEqual(ShellKeySeal.format(of: otherVersion), .unknown)
        XCTAssertEqual(open(otherVersion), .failure(.unreadable))
    }

    func testAdoptionDiscardsOldEntriesAndKeepsWhatCantBeOpenedYet() throws {
        let agree = { (peer: P256.KeyAgreement.PublicKey) in try self.sealing.sharedSecretFromKeyAgreement(with: peer) }
        let sealed = try ShellKeySeal.seal(key, to: sealing.publicKey, clientID: "mac1")
        XCTAssertEqual(ShellKeySeal.adopt(sealed, clientID: "mac1", recipient: sealing.publicKey, agree: agree), .key(key))
        // A bare key an older build stored: discarded, the Mac grants again.
        XCTAssertEqual(ShellKeySeal.format(of: key), .plain)
        XCTAssertEqual(ShellKeySeal.adopt(key, clientID: "mac1", recipient: sealing.publicKey, agree: agree), .discard)
        XCTAssertEqual(ShellKeySeal.adopt(Data([1, 2, 3]), clientID: "mac1", recipient: sealing.publicKey, agree: agree), .discard)
        // The sealing key refused (no user presence): kept for the next unlock.
        struct NoPresence: Error {}
        XCTAssertEqual(ShellKeySeal.adopt(sealed, clientID: "mac1", recipient: sealing.publicKey) { _ in throw NoPresence() }, .keep)
    }

    func testRegistryPublishesTheSealingKey() {
        let suite = "\(PassthroughProtocol.identifier).tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let registry = PairingRegistry(defaults: defaults, secrets: InMemorySecrets())
        XCTAssertNil(registry.shellSealingKey)
        registry.publishShellSealingKey(sealing.publicKey)
        // The extension's registry, on the same shared defaults, sees it.
        XCTAssertEqual(PairingRegistry(defaults: defaults).shellSealingKey?.x963Representation, sealing.publicKey.x963Representation)
        registry.publishShellSealingKey(nil)
        XCTAssertNil(registry.shellSealingKey)
    }
}
