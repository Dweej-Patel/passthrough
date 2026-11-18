#if os(macOS)
import XCTest
import PassthroughCore
@testable import ShellHost

final class ScreenPassStoreTests: XCTestCase {
    private func pass(_ macID: String, at seconds: TimeInterval = 1, phoneID: String = "viewer.1") -> ReceivedScreenPass {
        ReceivedScreenPass(credential: ShellCredential(macID: macID, macName: "Studio", certSHA256: String(repeating: "b", count: 64),
                                                       shellKey: Data(repeating: 7, count: 32), phoneID: phoneID, port: 7893,
                                                       addresses: []),
                           from: "iPhone", receivedAt: Date(timeIntervalSince1970: seconds))
    }

    func testOnePassPerMacNewestFirst() {
        let store = ScreenPassStore(secrets: InMemorySecrets())
        XCTAssertTrue(store.save(pass("a", at: 1)).saved)
        XCTAssertTrue(store.save(pass("b", at: 2)).saved)
        let again = store.save(pass("a", at: 3, phoneID: "viewer.2"))
        XCTAssertTrue(again.saved)
        XCTAssertEqual(again.replaced?.credential.phoneID, "viewer.1")
        XCTAssertEqual(store.passes.map(\.id), ["a", "b"])
        XCTAssertEqual(store.pass(for: "a")?.credential.phoneID, "viewer.2")
        XCTAssertTrue(store.remove(macID: "a"))
        XCTAssertEqual(store.passes.map(\.id), ["b"])
        XCTAssertTrue(store.remove(macID: "b"))
        XCTAssertTrue(store.passes.isEmpty)
    }

    func testAnUnusablePassIsNotKept() {
        let store = ScreenPassStore(secrets: InMemorySecrets())
        XCTAssertFalse(store.save(pass("a", phoneID: "phone-1")).saved, "not a viewer's id")
        var short = pass("a")
        short.credential.shellKey = Data(count: 8)
        XCTAssertFalse(store.save(short).saved)
        XCTAssertTrue(store.passes.isEmpty)
    }

    /// What can't be read is never written over; removing drops it whole.
    func testAnUnreadableStoreIsNotOverwritten() {
        let secrets = InMemorySecrets()
        secrets.write(Data("not json".utf8), account: ScreenPassStore.account)
        let store = ScreenPassStore(secrets: secrets)
        XCTAssertFalse(store.save(pass("a")).saved)
        XCTAssertEqual(secrets.read(ScreenPassStore.account), Data("not json".utf8))
        XCTAssertTrue(store.remove(macID: "a"))
        XCTAssertNil(secrets.read(ScreenPassStore.account))
    }

    /// A phone that lost access here takes the passes it handed over with it.
    func testPassesGoWithThePhoneThatHandedThemOver() {
        let store = ScreenPassStore(secrets: InMemorySecrets())
        var fromA = pass("m1"); fromA.fromPhoneID = "phone-a"
        var fromB = pass("m2"); fromB.fromPhoneID = "phone-b"
        store.save(fromA); store.save(fromB)
        let result = store.remove(fromPhones: ["phone-a"])
        XCTAssertTrue(result.done)
        XCTAssertEqual(result.macIDs, ["m1"])
        XCTAssertEqual(store.passes.map(\.id), ["m2"])
    }

    /// A removal that can't be saved still keeps the pass out; a new pass for that Mac brings it back.
    func testARemovalThatCantBeSavedStillHolds() {
        let secrets = FailingSecrets()
        let store = ScreenPassStore(secrets: secrets)
        store.save(pass("a"))
        secrets.failing = true
        XCTAssertFalse(store.remove(macID: "a"))
        XCTAssertNil(store.pass(for: "a"), "out in memory")
        secrets.failing = false
        XCTAssertTrue(store.save(pass("a", at: 5, phoneID: "viewer.9")).saved)
        XCTAssertEqual(store.pass(for: "a")?.credential.phoneID, "viewer.9")
    }

    /// A phone revoked here hands over nothing more, even a save already on its way, until it's granted again.
    func testARevokedPhoneHandsOverNothing() {
        let store = ScreenPassStore(secrets: InMemorySecrets())
        store.remove(fromPhones: ["phone-a"])
        var late = pass("m1"); late.fromPhoneID = "phone-a"
        XCTAssertFalse(store.save(late).saved)
        store.allowSender("phone-a")
        XCTAssertTrue(store.save(late).saved)
    }

    private final class FailingSecrets: SecretStore, @unchecked Sendable {
        private let inner = InMemorySecrets()
        var failing = false
        func read(_ account: String) -> Data? { inner.read(account) }
        func write(_ data: Data, account: String) -> Bool { failing ? false : inner.write(data, account: account) }
        func delete(_ account: String) { if !failing { inner.delete(account) } }
    }

    func testTheOldestGoesPastTheLimit() {
        let store = ScreenPassStore(secrets: InMemorySecrets())
        for n in 0...ScreenPassStore.maxPasses { store.save(pass("m\(n)", at: TimeInterval(n))) }
        XCTAssertEqual(store.passes.count, ScreenPassStore.maxPasses)
        XCTAssertNil(store.pass(for: "m0"))
    }
}
#endif
