#if os(macOS)
import XCTest
import PassthroughCore
@testable import ShellHost

final class ShellAccessStoreTests: XCTestCase {
    private func phone(_ id: String, slot: String = "slot", key: Data = ShellAccessStore.newKey()) -> ShellPhone {
        ShellPhone(phoneID: id, label: "iPhone", pairingSlot: slot, key: key, grantedAt: Date(timeIntervalSince1970: 1))
    }

    func testRecordReplacesByPhone() {
        let store = ShellAccessStore(secrets: InMemorySecrets())
        XCTAssertEqual(ShellAccessStore.newKey().count, 32)
        store.record(phone("a", key: Data(repeating: 1, count: 32)))
        let newer = Data(repeating: 2, count: 32)
        store.record(phone("a", key: newer))
        store.record(phone("b"))
        XCTAssertEqual(store.phones.map(\.phoneID).sorted(), ["a", "b"])
        XCTAssertEqual(store.key(forPhone: "a"), newer)
        XCTAssertNil(store.key(forPhone: "nobody"))
    }

    /// Screen access is off by default, set per phone, and survives the phone
    /// being plugged in again (a re-grant renews the key only).
    func testScreenAccess() {
        let store = ShellAccessStore(secrets: InMemorySecrets())
        store.record(phone("a"))
        store.record(phone("b"))
        XCTAssertFalse(store.screenAllowed(forPhone: "a"))
        XCTAssertTrue(store.setScreenAllowed(true, forPhone: "a"))
        XCTAssertTrue(store.screenAllowed(forPhone: "a"))
        XCTAssertFalse(store.screenAllowed(forPhone: "b"))
        store.record(phone("a"))
        XCTAssertTrue(store.screenAllowed(forPhone: "a"), "kept across a re-grant")
        XCTAssertFalse(store.setScreenAllowed(true, forPhone: "nobody"))
        XCTAssertFalse(store.screenAllowed(forPhone: "nobody"))
        store.revoke(phoneID: "a")
        store.record(phone("a"))
        XCTAssertFalse(store.screenAllowed(forPhone: "a"), "a phone granted again after a revoke starts without it")
    }

    /// The phone ID in a grant answer is the phone's claim: a phone paired
    /// through one slot cannot replace the access of a phone from another.
    func testRecordRefusesAPhoneIDFromAnotherPairing() {
        let store = ShellAccessStore(secrets: InMemorySecrets())
        let key = Data(repeating: 1, count: 32)
        XCTAssertTrue(store.record(phone("b", slot: "android-1", key: key)))
        XCTAssertFalse(store.record(phone("b", slot: "token")))
        XCTAssertEqual(store.candidateKeys(forPhone: "b"), [key])
        XCTAssertEqual(store.phones.map(\.pairingSlot), ["android-1"])
        store.revoke(pairingSlot: "android-1")
        XCTAssertTrue(store.record(phone("b", slot: "token")), "once that pairing is gone the ID is free")
    }

    /// A re-grant keeps the key the phone holds working until it uses the new one.
    func testRegrantKeepsThePreviousKeyUntilTheNewOneIsUsed() {
        let store = ShellAccessStore(secrets: InMemorySecrets())
        let first = Data(repeating: 1, count: 32), second = Data(repeating: 2, count: 32), third = Data(repeating: 3, count: 32)
        store.record(phone("a", key: first))
        XCTAssertEqual(store.candidateKeys(forPhone: "a"), [first])
        store.record(phone("a", key: second))
        XCTAssertEqual(store.candidateKeys(forPhone: "a"), [second, first])
        // Never used, so the phone may still hold only the first: that one stays.
        store.record(phone("a", key: third))
        XCTAssertEqual(store.candidateKeys(forPhone: "a"), [third, first])
        store.confirmCurrentKey(phoneID: "a", proven: third)
        XCTAssertEqual(store.candidateKeys(forPhone: "a"), [third])
        store.record(phone("a", key: first))
        XCTAssertEqual(store.candidateKeys(forPhone: "a"), [first, third])
        XCTAssertEqual(store.candidateKeys(forPhone: "nobody"), [])
    }

    /// A confirmation that arrives after the phone was granted again (the
    /// key it proved is no longer the current one) keeps the previous key:
    /// the phone may not have adopted the newer grant yet.
    func testConfirmingAnOlderKeyAfterARegrantKeepsThePreviousKey() {
        let store = ShellAccessStore(secrets: InMemorySecrets())
        let first = Data(repeating: 1, count: 32), second = Data(repeating: 2, count: 32), third = Data(repeating: 3, count: 32)
        store.record(phone("a", key: first))
        store.record(phone("a", key: second))
        // The phone proves `second`; before that is confirmed, it is granted `third`.
        store.record(phone("a", key: third))
        XCTAssertEqual(store.candidateKeys(forPhone: "a"), [third, first])
        store.confirmCurrentKey(phoneID: "a", proven: second)
        XCTAssertEqual(store.candidateKeys(forPhone: "a"), [third, first], "a stale confirmation drops nothing")
        store.confirmCurrentKey(phoneID: "a", proven: third)
        XCTAssertEqual(store.candidateKeys(forPhone: "a"), [third])
    }

    /// With no phone granted, handshakes do not each go to the Keychain: an
    /// empty read stands for `emptyTTL`, and a grant shows at once.
    func testAnEmptyListIsCachedBrieflyAndAGrantShowsAtOnce() {
        let secrets = CountingSecrets()
        let clock = TestClock()
        let store = ShellAccessStore(secrets: secrets, now: { clock.now })
        for _ in 0..<100 {
            XCTAssertEqual(store.candidateKeys(forPhone: "stranger"), [])
            XCTAssertNil(store.key(forPhone: "stranger"))
        }
        XCTAssertEqual(secrets.reads.get(), 1)
        clock.advance(ShellAccessStore.emptyTTL - 0.1)
        XCTAssertEqual(store.phones, [])
        XCTAssertEqual(secrets.reads.get(), 1)
        clock.advance(0.2)
        XCTAssertEqual(store.phones, [])
        XCTAssertEqual(secrets.reads.get(), 2, "an empty answer expires")

        let key = Data(repeating: 7, count: 32)
        XCTAssertTrue(store.record(phone("a", key: key)))
        XCTAssertEqual(store.candidateKeys(forPhone: "a"), [key], "a new grant works at once")
        let readsAfterGrant = secrets.reads.get()
        clock.advance(60)
        XCTAssertEqual(store.candidateKeys(forPhone: "a"), [key])
        XCTAssertEqual(secrets.reads.get(), readsAfterGrant, "a non-empty list is not re-read")

        // Revoking the last phone leaves a known-empty list, not a stale one.
        XCTAssertTrue(store.revoke(phoneID: "a"))
        XCTAssertEqual(store.candidateKeys(forPhone: "a"), [])
    }

    /// A write never trusts a remembered empty read: another writer's phone survives.
    func testAWriteRereadsAnEmptyAnswer() {
        let secrets = CountingSecrets()
        let store = ShellAccessStore(secrets: secrets)
        XCTAssertEqual(store.phones, [])
        ShellAccessStore(secrets: secrets).record(phone("other"))
        store.record(phone("a"))
        XCTAssertEqual(store.phones.map(\.phoneID).sorted(), ["a", "other"])
    }

    func testRevokeDropsBothKeys() {
        let store = ShellAccessStore(secrets: InMemorySecrets())
        store.record(phone("a", slot: "s1"))
        store.record(phone("a", slot: "s1"))
        XCTAssertEqual(store.candidateKeys(forPhone: "a").count, 2)
        store.revoke(phoneID: "a")
        XCTAssertEqual(store.candidateKeys(forPhone: "a"), [])
        store.record(phone("b", slot: "s2"))
        store.record(phone("b", slot: "s2"))
        store.revoke(pairingSlot: "s2")
        XCTAssertEqual(store.candidateKeys(forPhone: "b"), [], "a fresh grant after revoking starts with no previous key")
        store.record(phone("b", slot: "s2"))
        XCTAssertEqual(store.candidateKeys(forPhone: "b").count, 1)
    }

    /// Lists stored before `previousKey` existed still load.
    func testDecodesAListWithoutPreviousKey() throws {
        let secrets = InMemorySecrets()
        let key = Data(repeating: 7, count: 32)
        let json = #"[{"phoneID":"a","label":"iPhone","pairingSlot":"s","key":"\#(key.base64EncodedString())","grantedAt":1}]"#
        secrets.write(Data(json.utf8), account: "shell.phones")
        let store = ShellAccessStore(secrets: secrets)
        XCTAssertEqual(store.phones.map(\.phoneID), ["a"])
        XCTAssertNil(store.phones.first?.previousKey)
        XCTAssertEqual(store.candidateKeys(forPhone: "a"), [key])
    }

    func testRevokeBySlot() {
        let store = ShellAccessStore(secrets: InMemorySecrets())
        store.record(phone("a", slot: "s1"))
        store.record(phone("b", slot: "s1"))
        store.record(phone("c", slot: "s2"))
        store.revoke(pairingSlot: "s1")
        XCTAssertEqual(store.phones.map(\.phoneID), ["c"])
        store.revoke(phoneID: "c")
        XCTAssertTrue(store.phones.isEmpty)
        XCTAssertNil(store.key(forPhone: "c"))
    }

    func testPersistsAcrossInstances() {
        let secrets = InMemorySecrets()
        let key = ShellAccessStore.newKey()
        ShellAccessStore(secrets: secrets).record(phone("a", key: key))
        let again = ShellAccessStore(secrets: secrets)
        XCTAssertEqual(again.phones.map(\.phoneID), ["a"])
        XCTAssertEqual(again.key(forPhone: "a"), key)
    }

    /// Reads work, writes are refused (a keychain that went read-only).
    private final class ReadOnlySecrets: SecretStore, @unchecked Sendable {
        let inner: InMemorySecrets
        init(_ inner: InMemorySecrets) { self.inner = inner }
        func read(_ account: String) -> Data? { inner.read(account) }
        func write(_ data: Data, account: String) -> Bool { false }
        func delete(_ account: String) { inner.delete(account) }
    }

    /// Counts reads, to show the list is answered from memory.
    private final class CountingSecrets: SecretStore, @unchecked Sendable {
        let inner = InMemorySecrets()
        let reads = Locked(0)
        func read(_ account: String) -> Data? { reads.set(reads.get() + 1); return inner.read(account) }
        func write(_ data: Data, account: String) -> Bool { inner.write(data, account: account) }
        func delete(_ account: String) { inner.delete(account) }
    }

    /// The store is read once; lookups after that, and after the store's own
    /// writes, come from memory and see every write.
    func testLookupsAreAnsweredFromMemory() {
        let secrets = CountingSecrets()
        let store = ShellAccessStore(secrets: secrets)
        let first = Data(repeating: 1, count: 32), second = Data(repeating: 2, count: 32)
        store.record(phone("a", key: first))
        XCTAssertEqual(secrets.reads.get(), 1)
        for _ in 0..<10 { XCTAssertEqual(store.candidateKeys(forPhone: "a"), [first]) }
        store.record(phone("a", key: second))
        XCTAssertEqual(store.candidateKeys(forPhone: "a"), [second, first])
        store.confirmCurrentKey(phoneID: "a", proven: second)
        XCTAssertEqual(store.candidateKeys(forPhone: "a"), [second])
        store.revoke(phoneID: "a")
        XCTAssertEqual(store.candidateKeys(forPhone: "a"), [])
        XCTAssertEqual(secrets.reads.get(), 1, "no lookup went back to the store")
        XCTAssertEqual(ShellAccessStore(secrets: secrets.inner).phones, [], "what is in memory was written through")
    }

    func testRecordReportsWriteFailure() {
        let store = ShellAccessStore(secrets: ReadOnlySecrets(InMemorySecrets()))
        XCTAssertFalse(store.record(phone("a")))
        XCTAssertNil(store.key(forPhone: "a"))
        XCTAssertTrue(ShellAccessStore(secrets: InMemorySecrets()).record(phone("a")))
    }

    func testFailedRevokeFailsClosed() {
        let secrets = InMemorySecrets()
        ShellAccessStore(secrets: secrets).record(phone("a", slot: "s1"))
        ShellAccessStore(secrets: secrets).record(phone("b", slot: "s2"))
        let store = ShellAccessStore(secrets: ReadOnlySecrets(secrets))
        XCTAssertNotNil(store.key(forPhone: "a"))
        XCTAssertTrue(store.revoke(phoneID: "a"), "the list was deleted, so no key remains")
        XCTAssertNil(store.key(forPhone: "a"), "a revoked key must not survive a failed rewrite")
        XCTAssertNil(secrets.read("shell.phones"))
    }

    func testFailedRevokeBySlotFailsClosed() {
        let secrets = InMemorySecrets()
        ShellAccessStore(secrets: secrets).record(phone("a", slot: "s1"))
        let store = ShellAccessStore(secrets: ReadOnlySecrets(secrets))
        XCTAssertTrue(store.revoke(pairingSlot: "s1"))
        XCTAssertNil(store.key(forPhone: "a"))
    }

    /// Holds every write (and delete) until released, then fails the write.
    private final class StalledSecrets: SecretStore, @unchecked Sendable {
        let inner: InMemorySecrets
        let writing = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        init(_ inner: InMemorySecrets) { self.inner = inner }
        func read(_ account: String) -> Data? { inner.read(account) }
        func write(_ data: Data, account: String) -> Bool { writing.signal(); release.wait(); return false }
        func delete(_ account: String) {}   // cannot delete either
    }

    /// A revoked phone is refused at once, while the write is still stalled,
    /// and stays refused when the write and the fallback delete both fail.
    func testRevokeTakesEffectInMemoryBeforeTheWrite() {
        let inner = InMemorySecrets()
        ShellAccessStore(secrets: inner).record(phone("a", slot: "s1"))
        ShellAccessStore(secrets: inner).record(phone("b", slot: "s2"))
        let secrets = StalledSecrets(inner)
        let store = ShellAccessStore(secrets: secrets)
        XCTAssertNotNil(store.key(forPhone: "a"))
        let finished = expectation(description: "revoke returned")
        let result = Locked(true)
        DispatchQueue.global().async {
            result.set(store.revoke(phoneID: "a"))
            finished.fulfill()
        }
        XCTAssertEqual(secrets.writing.wait(timeout: .now() + 5), .success)
        XCTAssertNil(store.key(forPhone: "a"), "refused while the write is in flight")
        XCTAssertNotNil(store.key(forPhone: "b"), "other phones are unaffected")
        secrets.release.signal()
        wait(for: [finished], timeout: 5)
        XCTAssertFalse(result.get(), "the key may still be stored: not a success")
        XCTAssertNil(store.key(forPhone: "a"), "still refused after the write failed")
    }

    /// The store cannot tell "nothing stored" from "unreadable", so an empty
    /// read is remembered only briefly: a list another writer stores is seen
    /// once `emptyTTL` has passed.
    func testEmptyReadIsCachedOnlyBriefly() {
        let secrets = CountingSecrets()
        let clock = TestClock()
        let store = ShellAccessStore(secrets: secrets, now: { clock.now })
        XCTAssertTrue(store.phones.isEmpty)
        XCTAssertTrue(store.phones.isEmpty)
        XCTAssertEqual(secrets.reads.get(), 1)
        ShellAccessStore(secrets: secrets.inner).record(phone("a"))
        clock.advance(ShellAccessStore.emptyTTL)
        XCTAssertEqual(store.phones.map(\.phoneID), ["a"])
    }

    func testCorruptStoreIsNotOverwritten() {
        let secrets = InMemorySecrets()
        let junk = Data("not json".utf8)
        secrets.write(junk, account: "shell.phones")
        let store = ShellAccessStore(secrets: secrets)
        XCTAssertFalse(store.record(phone("a")))
        XCTAssertEqual(secrets.read("shell.phones"), junk, "record must not clobber what it cannot read")
        XCTAssertNil(store.key(forPhone: "a"))
    }

    func testRevokeOnCorruptStoreLeavesNoKey() {
        let secrets = InMemorySecrets()
        secrets.write(Data("not json".utf8), account: "shell.phones")
        let store = ShellAccessStore(secrets: secrets)
        XCTAssertTrue(store.revoke(phoneID: "a"))
        XCTAssertNil(secrets.read("shell.phones"))
        XCTAssertTrue(store.record(phone("b")), "a deleted store starts fresh")
    }
}
private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var time = Date(timeIntervalSince1970: 1_000)
    var now: Date { lock.lock(); defer { lock.unlock() }; return time }
    func advance(_ seconds: TimeInterval) { lock.lock(); time += seconds; lock.unlock() }
}
#endif
