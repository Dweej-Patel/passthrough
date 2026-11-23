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

    /// A device's status renames its access (an iPad granted while it still
    /// called itself "iPhone"), keeping its key; same name or empty, nothing changes.
    func testRelabelFollowsTheDevicesName() {
        let store = ShellAccessStore(secrets: InMemorySecrets())
        let key = Data(repeating: 3, count: 32)
        store.record(phone("ipad", slot: "token.ipad.X", key: key))
        store.record(phone("phone", slot: "token.iphone.Y"))
        XCTAssertTrue(store.relabel(pairingSlot: "token.ipad.X", label: "iPad"))
        XCTAssertEqual(store.phones.first { $0.phoneID == "ipad" }?.label, "iPad")
        XCTAssertEqual(store.phones.first { $0.phoneID == "phone" }?.label, "iPhone", "only that device")
        XCTAssertEqual(store.key(forPhone: "ipad"), key)
        XCTAssertFalse(store.relabel(pairingSlot: "token.ipad.X", label: "iPad"), "already so")
        XCTAssertFalse(store.relabel(pairingSlot: "token.ipad.X", label: ""))
        XCTAssertFalse(store.relabel(pairingSlot: "nobody", label: "x"))
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

    /// Keep awake and the VPN: on unless the owner turns it off, kept across a re-grant.
    func testControlAccess() {
        let store = ShellAccessStore(secrets: InMemorySecrets())
        store.record(phone("a"))
        store.record(phone("b"))
        XCTAssertTrue(store.controlAllowed(forPhone: "a"), "on by default")
        XCTAssertTrue(store.setControlAllowed(false, forPhone: "a"))
        XCTAssertFalse(store.controlAllowed(forPhone: "a"))
        XCTAssertTrue(store.controlAllowed(forPhone: "b"))
        store.record(phone("a"))
        XCTAssertFalse(store.controlAllowed(forPhone: "a"), "kept across a re-grant")
        XCTAssertFalse(store.controlAllowed(forPhone: "nobody"), "an unknown phone may change nothing")
        XCTAssertFalse(store.setControlAllowed(true, forPhone: "nobody"))
    }

    /// As the screen: a failed "off" still holds in memory, and is written with the next write.
    func testControlOffHoldsWhenTheWriteFails() {
        let secrets = FlakySecrets()
        let store = ShellAccessStore(secrets: secrets)
        store.record(phone("a"))
        store.record(phone("b"))
        secrets.failing.set(true)
        XCTAssertFalse(store.setControlAllowed(false, forPhone: "a"), "the failure is reported")
        XCTAssertFalse(store.controlAllowed(forPhone: "a"), "but it is off at once")
        XCTAssertFalse(store.record(phone("b")), "another write fails, so the list is read from the store again")
        XCTAssertFalse(store.controlAllowed(forPhone: "a"), "the store still says on; memory says off")
        secrets.failing.set(false)
        XCTAssertTrue(store.record(phone("b")))
        XCTAssertFalse(ShellAccessStore(secrets: secrets.inner).controlAllowed(forPhone: "a"), "written with the next write")
        XCTAssertTrue(ShellAccessStore(secrets: secrets.inner).controlAllowed(forPhone: "b"))
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

    /// An iPhone's pairing moved out of the slot every iPhone once shared:
    /// its access moves with it, keeping its keys and Screen switch, so the
    /// next grant renews it instead of being refused.
    func testMoveFollowsAPairingToItsNewSlot() {
        let store = ShellAccessStore(secrets: InMemorySecrets())
        let key = Data(repeating: 1, count: 32)
        XCTAssertTrue(store.record(phone("a", slot: "token", key: key)))
        XCTAssertTrue(store.record(phone("b", slot: "token")))
        XCTAssertTrue(store.setScreenAllowed(true, forPhone: "a"))
        XCTAssertFalse(store.record(phone("a", slot: "token.iphone.A")), "refused before the move")
        XCTAssertFalse(store.move(phoneID: "a", fromSlot: "other", toSlot: "token.iphone.A"), "only from the slot it was granted through")
        XCTAssertTrue(store.move(phoneID: "a", fromSlot: "token", toSlot: "token.iphone.A"))
        XCTAssertEqual(store.phones.first { $0.phoneID == "a" }?.pairingSlot, "token.iphone.A")
        XCTAssertEqual(store.phones.first { $0.phoneID == "b" }?.pairingSlot, "token", "other phones stay put")
        XCTAssertEqual(store.candidateKeys(forPhone: "a"), [key])
        XCTAssertTrue(store.screenAllowed(forPhone: "a"))
        XCTAssertTrue(store.record(phone("a", slot: "token.iphone.A")))
        XCTAssertFalse(store.move(phoneID: "nobody", fromSlot: "token", toSlot: "x"))
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

    /// Counts reads of the store, to show the list is answered from memory.
    /// Each reads the phones' item, then the passes' item: counted once.
    private final class CountingSecrets: SecretStore, @unchecked Sendable {
        let inner = InMemorySecrets()
        let reads = Locked(0)
        func read(_ account: String) -> Data? { if account == "shell.phones" { reads.set(reads.get() + 1) }; return inner.read(account) }
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

    /// Writes (and deletes) fail while `failing` is set.
    private final class FlakySecrets: SecretStore, @unchecked Sendable {
        let inner = InMemorySecrets()
        let failing = Locked(false)
        func read(_ account: String) -> Data? { inner.read(account) }
        func write(_ data: Data, account: String) -> Bool { failing.get() ? false : inner.write(data, account: account) }
        func delete(_ account: String) { if !failing.get() { inner.delete(account) } }
    }

    /// Turning Screen off holds even when the Keychain write fails, and
    /// through later failed writes that make the store read again; the next
    /// write that works stores it.
    func testScreenOffHoldsWhenTheWriteFails() {
        let secrets = FlakySecrets()
        let store = ShellAccessStore(secrets: secrets)
        store.record(phone("a"))
        store.record(phone("b"))
        XCTAssertTrue(store.setScreenAllowed(true, forPhone: "a"))
        XCTAssertTrue(store.setScreenAllowed(true, forPhone: "b"))
        secrets.failing.set(true)
        XCTAssertFalse(store.setScreenAllowed(false, forPhone: "a"), "the failure is reported")
        XCTAssertFalse(store.screenAllowed(forPhone: "a"), "but the screen is off at once")
        XCTAssertTrue(store.screenAllowed(forPhone: "b"))
        XCTAssertFalse(store.record(phone("b")), "another write fails, so the list is read from the store again")
        XCTAssertFalse(store.screenAllowed(forPhone: "a"), "the store still says on; memory says off")
        XCTAssertFalse(store.setScreenAllowed(true, forPhone: "a"), "a failed allow changes nothing")
        XCTAssertFalse(store.screenAllowed(forPhone: "a"))
        secrets.failing.set(false)
        store.confirmCurrentKey(phoneID: "b", proven: Data(repeating: 9, count: 32))   // writes nothing
        XCTAssertTrue(store.record(phone("b")))
        XCTAssertFalse(ShellAccessStore(secrets: secrets.inner).screenAllowed(forPhone: "a"), "written with the next write")
        XCTAssertTrue(ShellAccessStore(secrets: secrets.inner).screenAllowed(forPhone: "b"))
    }

    /// A revoke whose write and fallback delete both fail stays in force
    /// through later reads of the store, until a write succeeds.
    func testFailedRevokeSurvivesARereadOfTheStore() {
        let secrets = FlakySecrets()
        let store = ShellAccessStore(secrets: secrets)
        store.record(phone("a", slot: "s1"))
        store.record(phone("b", slot: "s2"))
        secrets.failing.set(true)
        XCTAssertFalse(store.revoke(phoneID: "a"))
        XCTAssertFalse(store.record(phone("b", slot: "s2")), "forces the next lookup to read the store")
        XCTAssertEqual(store.candidateKeys(forPhone: "a"), [], "the store still holds a; memory does not")
        XCTAssertFalse(store.candidateKeys(forPhone: "b").isEmpty)
        secrets.failing.set(false)
        XCTAssertTrue(store.record(phone("c", slot: "s3")))
        XCTAssertEqual(ShellAccessStore(secrets: secrets.inner).phones.map(\.phoneID).sorted(), ["b", "c"])
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
    // MARK: Screen passes

    private func granter(_ store: ShellAccessStore, screen: Bool = true) {
        store.record(phone("phone", slot: "token.iphone.A"))
        store.setScreenAllowed(screen, forPhone: "phone")
    }

    func testAScreenPassIsScreenOnlyAndGoesWithItsPhone() throws {
        let store = ShellAccessStore(secrets: InMemorySecrets())
        granter(store)
        let granted = try store.grantViewer(by: "phone", name: "Studio", viewer: "mac-2").get()
        XCTAssertTrue(granted.id.hasPrefix(ScreenPass.idPrefix))
        XCTAssertEqual(granted.key.count, 32)
        XCTAssertEqual(store.candidateKeys(forPhone: granted.id), [granted.key])
        let pass = try XCTUnwrap(store.phones.first { $0.phoneID == granted.id })
        XCTAssertTrue(pass.isScreenOnly && pass.screenAllowed)
        XCTAssertFalse(pass.controlAllowed)
        XCTAssertEqual(pass.pairingSlot, "token.iphone.A")
        XCTAssertTrue(store.isScreenOnly(granted.id))
        XCTAssertFalse(store.isScreenOnly("phone"))

        // Renaming the phone leaves the pass its own name; moving its pairing moves the pass.
        store.relabel(pairingSlot: "token.iphone.A", label: "New iPhone")
        XCTAssertEqual(store.phones.first { $0.phoneID == granted.id }?.label, "Studio")
        XCTAssertTrue(store.move(phoneID: "phone", fromSlot: "token.iphone.A", toSlot: "token.iphone.B"))
        XCTAssertEqual(store.phones.first { $0.phoneID == granted.id }?.pairingSlot, "token.iphone.B")

        // Removing the phone removes what it granted.
        store.record(phone("other", slot: "token.iphone.C"))
        XCTAssertTrue(store.revoke(phoneID: "phone"))
        XCTAssertEqual(store.phones.map(\.phoneID), ["other"])
    }

    func testOnlyAPhoneAllowedTheScreenMayShareIt() {
        let store = ShellAccessStore(secrets: InMemorySecrets())
        granter(store, screen: false)
        guard case .failure(.screenNotAllowed) = store.grantViewer(by: "phone", name: "Studio", viewer: "mac-2") else { return XCTFail() }
        guard case .failure(.notAuthorized) = store.grantViewer(by: "stranger", name: "Studio", viewer: "mac-2") else { return XCTFail() }
        guard case .failure(.badRequest) = store.grantViewer(by: "phone", name: " ", viewer: "mac-2") else { return XCTFail() }
    }

    func testAPassCannotGrantPasses() throws {
        let store = ShellAccessStore(secrets: InMemorySecrets())
        granter(store)
        let granted = try store.grantViewer(by: "phone", name: "Studio", viewer: "mac-2").get()
        guard case .failure(.notAuthorized) = store.grantViewer(by: granted.id, name: "Other", viewer: "mac-3") else { return XCTFail() }
    }

    /// A pass's id is the Mac's to mint: a phone grant can't use one, nor
    /// replace a pass (which would make its key, held by another Mac, a phone's).
    func testAPhoneGrantCannotTakeAPasssId() throws {
        let store = ShellAccessStore(secrets: InMemorySecrets())
        granter(store)
        let granted = try store.grantViewer(by: "phone", name: "Studio", viewer: "mac-2").get()
        XCTAssertFalse(store.record(phone(granted.id, slot: "token.iphone.A")), "the granter's own slot")
        XCTAssertFalse(store.record(phone("viewer.made-up", slot: "token.iphone.A")))
        let pass = try XCTUnwrap(store.phones.first { $0.phoneID == granted.id })
        XCTAssertTrue(pass.isScreenOnly)
        XCTAssertEqual(store.candidateKeys(forPhone: granted.id), [granted.key])
    }

    /// Screen-only fails closed: a pass's id is screen-only even once its entry is gone.
    func testAPasssIdIsScreenOnlyEvenWhenUnknown() {
        let store = ShellAccessStore(secrets: InMemorySecrets())
        XCTAssertTrue(store.isScreenOnly("viewer.gone"))
        XCTAssertFalse(store.isScreenOnly("phone"))
    }

    /// A pass sees the screen only while the phone that granted it may, even
    /// when turning that phone's Screen off can't be saved.
    func testAPassSeesTheScreenOnlyWhileItsPhoneMay() throws {
        let secrets = FlakySecrets()
        let store = ShellAccessStore(secrets: secrets)
        granter(store)
        let granted = try store.grantViewer(by: "phone", name: "Studio", viewer: "mac-2").get()
        XCTAssertTrue(store.screenAllowed(forPhone: granted.id))
        secrets.failing.set(true)
        store.setScreenAllowed(false, forPhone: "phone")
        XCTAssertFalse(store.screenAllowed(forPhone: granted.id), "off in memory though unsaved")
        secrets.failing.set(false)
        store.setScreenAllowed(true, forPhone: "phone")
        XCTAssertTrue(store.screenAllowed(forPhone: granted.id))
        XCTAssertEqual(store.viewers(grantedBy: "phone"), [granted.id])
    }

    /// Forgetting a pairing removes the phone's passes too, and says which went.
    func testForgettingAPairingRemovesItsPasses() throws {
        let store = ShellAccessStore(secrets: InMemorySecrets())
        granter(store)
        let granted = try store.grantViewer(by: "phone", name: "Studio", viewer: "mac-2").get()
        store.record(phone("other", slot: "token.iphone.C"))
        let (done, removed) = store.revokeReporting(pairingSlot: "token.iphone.A")
        XCTAssertTrue(done)
        XCTAssertEqual(Set(removed.map(\.phoneID)), ["phone", granted.id])
        XCTAssertTrue(store.candidateKeys(forPhone: granted.id).isEmpty)
        XCTAssertEqual(store.phones.map(\.phoneID), ["other"])
    }

    /// A revoke that can't be saved still keeps the passes out.
    func testAnUnsavedRevokeKeepsThePassesOut() throws {
        let secrets = FlakySecrets()
        let store = ShellAccessStore(secrets: secrets)
        granter(store)
        let granted = try store.grantViewer(by: "phone", name: "Studio", viewer: "mac-2").get()
        secrets.failing.set(true)
        let (_, removed) = store.revokeReporting(phoneID: "phone")
        XCTAssertEqual(Set(removed.map(\.phoneID)), ["phone", granted.id])
        XCTAssertTrue(store.candidateKeys(forPhone: granted.id).isEmpty)
        XCTAssertFalse(store.screenAllowed(forPhone: granted.id))
    }

    /// A phone takes back only a pass it granted.
    func testOnlyItsPhoneTakesAPassBack() throws {
        let store = ShellAccessStore(secrets: InMemorySecrets())
        granter(store)
        store.record(phone("other", slot: "token.iphone.C"))
        let granted = try store.grantViewer(by: "phone", name: "Studio", viewer: "mac-2").get()
        XCTAssertTrue(store.revokeViewer(granted.id, grantedBy: "other").removed.isEmpty)
        XCTAssertTrue(store.revokeViewer("other", grantedBy: "phone").removed.isEmpty, "only passes")
        XCTAssertEqual(store.revokeViewer(granted.id, grantedBy: "phone").removed.map(\.phoneID), [granted.id])
        XCTAssertTrue(store.candidateKeys(forPhone: granted.id).isEmpty)
        XCTAssertNotNil(store.key(forPhone: "phone"))
    }

    /// Taking back a pass that isn't the phone's touches nothing, even when the store can't be written.
    func testAStrangersRevokeNeverWipesTheStore() throws {
        let secrets = FlakySecrets()
        let store = ShellAccessStore(secrets: secrets)
        granter(store)
        store.record(phone("other", slot: "token.iphone.C"))
        let granted = try store.grantViewer(by: "phone", name: "Studio", viewer: "mac-2").get()
        secrets.failing.set(true)
        XCTAssertTrue(store.revokeViewer(granted.id, grantedBy: "other").removed.isEmpty)
        XCTAssertTrue(store.revokeViewer("viewer.nobody", grantedBy: "phone").removed.isEmpty)
        secrets.failing.set(false)
        XCTAssertEqual(Set(store.phones.map(\.phoneID)), ["phone", "other", granted.id])
    }

    /// A new pass for the same Mac replaces the old one only once that Mac
    /// uses it: until then the old one works, so a failed hand-over (the new
    /// one taken back) leaves the viewer its working pass.
    func testAPassForTheSameMacReplacesTheOldOneOnceUsed() throws {
        let store = ShellAccessStore(secrets: InMemorySecrets())
        granter(store)
        let first = try store.grantViewer(by: "phone", name: "Studio", viewer: "mac-2").get()
        let second = try store.grantViewer(by: "phone", name: "Studio", viewer: "mac-2").get()
        XCTAssertEqual(second.replaced, [], "kept while the hand-over may still fail")
        XCTAssertEqual(store.candidateKeys(forPhone: first.id), [first.key])

        // The hand-over failed: the phone takes the new one back, and the old one still works.
        XCTAssertEqual(store.revokeViewer(second.id, grantedBy: "phone").removed.map(\.phoneID), [second.id])
        XCTAssertTrue(store.screenAllowed(forPhone: first.id))

        // Shared again, and this time the Mac connects with it: the old one goes.
        let third = try store.grantViewer(by: "phone", name: "Studio", viewer: "mac-2").get()
        XCTAssertEqual(store.supersede(by: first.id), [], "an older pass in use removes nothing newer")
        XCTAssertEqual(store.supersede(by: third.id).map(\.phoneID), [first.id])
        XCTAssertTrue(store.candidateKeys(forPhone: first.id).isEmpty)
        XCTAssertEqual(store.candidateKeys(forPhone: third.id), [third.key])
        XCTAssertEqual(store.supersede(by: third.id), [], "nothing left to remove")
    }

    /// Only the newest earlier pass for a Mac is kept, and a phone has at most `maxPerGranter`.
    func testEarlierPassesForAMacAndAPhonesPassesAreCapped() throws {
        let store = ShellAccessStore(secrets: InMemorySecrets())
        granter(store)
        let first = try store.grantViewer(by: "phone", name: "Studio", viewer: "mac-2").get()
        let second = try store.grantViewer(by: "phone", name: "Studio", viewer: "mac-2").get()
        let third = try store.grantViewer(by: "phone", name: "Studio", viewer: "mac-2").get()
        XCTAssertEqual(third.replaced, [first.id])
        XCTAssertEqual(Set(store.viewers(grantedBy: "phone")), [second.id, third.id])
        for n in 0..<ScreenPass.maxPerGranter { _ = try store.grantViewer(by: "phone", name: "Mac \(n)", viewer: "m\(n)").get() }
        XCTAssertEqual(store.phones.filter { $0.grantedBy == "phone" }.count, ScreenPass.maxPerGranter)
    }

    // MARK: Passes apart from the phones

    private static let phonesItem = "shell.phones", passesItem = "shell.screenPasses"

    private func stored(_ secrets: SecretStore, _ account: String) -> [ShellPhone]? {
        secrets.read(account).flatMap { try? JSONDecoder().decode([ShellPhone].self, from: $0) }
    }

    /// A build from before passes reads only the phones' item: no pass is
    /// ever in it, so it can't take one (whose key another Mac holds) for a phone.
    func testPassesAreKeptApartFromThePhones() throws {
        let secrets = InMemorySecrets()
        let store = ShellAccessStore(secrets: secrets)
        granter(store)
        let granted = try store.grantViewer(by: "phone", name: "Studio", viewer: "mac-2").get()
        XCTAssertEqual(stored(secrets, Self.phonesItem)?.map(\.phoneID), ["phone"])
        XCTAssertEqual(stored(secrets, Self.passesItem)?.map(\.phoneID), [granted.id])
        // Every later write keeps it that way.
        store.record(phone("other", slot: "token.iphone.C"))
        store.setControlAllowed(false, forPhone: "phone")
        store.relabel(pairingSlot: "token.iphone.A", label: "New iPhone")
        XCTAssertFalse(stored(secrets, Self.phonesItem)?.contains { ScreenPass.isViewerID($0.phoneID) } ?? true)
        // And a new instance reads both.
        let again = ShellAccessStore(secrets: secrets)
        XCTAssertEqual(again.candidateKeys(forPhone: granted.id), [granted.key])
        XCTAssertTrue(again.screenAllowed(forPhone: granted.id))
        // Removing the last pass removes its item.
        XCTAssertFalse(again.revokeViewer(granted.id, grantedBy: "phone").removed.isEmpty)
        XCTAssertNil(secrets.read(Self.passesItem))
    }

    /// A Mac whose phones never share a screen never gets a passes item, and
    /// its phones' item is written as before.
    func testPhonesAloneNeverWriteThePassesItem() throws {
        let secrets = InMemorySecrets()
        let store = ShellAccessStore(secrets: secrets)
        let a = phone("a", slot: "s1")
        store.record(a)
        store.setScreenAllowed(true, forPhone: "a")
        store.setScreenAllowed(false, forPhone: "a")
        store.setControlAllowed(false, forPhone: "a")
        store.revoke(phoneID: "a")
        store.record(a)
        XCTAssertNil(secrets.read(Self.passesItem))
        XCTAssertEqual(stored(secrets, Self.phonesItem), [a], "a fresh grant, stored as a phone always was")
    }

    /// Passes stored among the phones (before they had their own item) are
    /// never taken for phones: left out, and the next write drops them.
    func testPassesStoredAmongThePhonesAreLeftOut() throws {
        let secrets = InMemorySecrets()
        var granter = phone("phone", slot: "token.iphone.A")
        granter.screen = true
        let legacy = ShellPhone(phoneID: "viewer.old", label: "Studio", pairingSlot: "token.iphone.A", key: ShellAccessStore.newKey(),
                                grantedAt: Date(), screen: true, control: false, screenOnly: true, grantedBy: "phone", viewerOf: "mac-2")
        secrets.write(try JSONEncoder().encode([granter, legacy]), account: Self.phonesItem)
        let store = ShellAccessStore(secrets: secrets)
        XCTAssertEqual(store.phones.map(\.phoneID), ["phone"])
        XCTAssertTrue(store.candidateKeys(forPhone: "viewer.old").isEmpty)
        XCTAssertNotNil(store.key(forPhone: "phone"), "the phone keeps its access")
        // The next write, even one that changes no phone, rewrites the phones' item without it.
        _ = try store.grantViewer(by: "phone", name: "Studio", viewer: "mac-2").get()
        XCTAssertEqual(stored(secrets, Self.phonesItem)?.map(\.phoneID), ["phone"])
    }

    /// A pass whose phone is gone (its item outlived the phones') never comes back with a phone of that id.
    func testAPassWithoutItsPhoneIsDropped() throws {
        let secrets = InMemorySecrets()
        let orphan = ShellPhone(phoneID: "viewer.old", label: "Studio", pairingSlot: "token.iphone.A", key: ShellAccessStore.newKey(),
                                grantedAt: Date(), screen: true, control: false, screenOnly: true, grantedBy: "phone", viewerOf: "mac-2")
        secrets.write(try JSONEncoder().encode([orphan]), account: Self.passesItem)
        let store = ShellAccessStore(secrets: secrets)
        XCTAssertTrue(store.phones.isEmpty)
        granter(store)   // the same phone id, granted again
        XCTAssertNil(secrets.read(Self.passesItem), "the first write tidied it away")
        XCTAssertTrue(ShellAccessStore(secrets: secrets).candidateKeys(forPhone: "viewer.old").isEmpty)
    }

    /// Fails writes (and deletes) to one item only.
    private final class OneItemFails: SecretStore, @unchecked Sendable {
        let inner = InMemorySecrets()
        let failing = Locked<String?>(nil)
        func read(_ account: String) -> Data? { inner.read(account) }
        func write(_ data: Data, account: String) -> Bool { failing.get() == account ? false : inner.write(data, account: account) }
        func delete(_ account: String) { if failing.get() != account { inner.delete(account) } }
    }

    /// Taking back a pass that can't be saved never wipes the phones: only
    /// the passes' item goes, and the pass stays out in memory either way.
    func testAPassThatCantBeRemovedNeverCostsThePhonesTheirAccess() throws {
        let secrets = OneItemFails()
        let store = ShellAccessStore(secrets: secrets)
        granter(store)
        store.record(phone("other", slot: "token.iphone.C"))
        let granted = try store.grantViewer(by: "phone", name: "Studio", viewer: "mac-2").get()
        secrets.failing.set(Self.passesItem)
        let (done, removed) = store.revokeViewer(granted.id, grantedBy: "phone")
        XCTAssertFalse(done, "its item couldn't be rewritten or deleted")
        XCTAssertEqual(removed.map(\.phoneID), [granted.id])
        XCTAssertTrue(store.candidateKeys(forPhone: granted.id).isEmpty, "out in memory")
        XCTAssertEqual(Set(stored(secrets, Self.phonesItem)?.map(\.phoneID) ?? []), ["phone", "other"], "the phones are untouched")
        XCTAssertNotNil(store.key(forPhone: "phone"))
        XCTAssertNotNil(store.key(forPhone: "other"))

        // Once the item can be written again, the next write leaves the pass out of it.
        secrets.failing.set(nil)
        let next = try store.grantViewer(by: "phone", name: "Lab", viewer: "mac-3").get()
        XCTAssertEqual(stored(secrets, Self.passesItem)?.map(\.phoneID), [next.id])
        XCTAssertTrue(ShellAccessStore(secrets: secrets.inner).candidateKeys(forPhone: granted.id).isEmpty)
    }

    // MARK: Computers (stage 7 a.2)

    private static let computersItem = "shell.computers"
    private let identityKey = Data([0x04] + [UInt8](repeating: 7, count: 64))

    /// A phone the owner lets share (and see the screen, unless told otherwise).
    private func sharer(_ store: ShellAccessStore, screen: Bool = true) {
        granter(store, screen: screen)
        XCTAssertTrue(store.setShareAllowed(true, forPhone: "phone"))
    }

    private func grant(_ store: ShellAccessStore, viewer: String = "mac-2", scopes: Set<String> = ["shell", "screen"])
        -> Result<(id: String, key: Data, scopes: [String], replaced: [String]), ShellError> {
        store.grantComputer(by: "phone", name: "Office-PC", viewer: viewer, kind: "windows", identityKey: identityKey, scopes: scopes)
    }

    func testAComputerIsKeptApartAndGoesWithItsPhone() throws {
        let secrets = InMemorySecrets()
        let store = ShellAccessStore(secrets: secrets)
        sharer(store)
        let granted = try grant(store).get()
        XCTAssertTrue(Computers.isComputerID(granted.id))
        XCTAssertEqual(granted.key.count, 32)
        XCTAssertEqual(granted.scopes, ["shell", "screen"])
        XCTAssertEqual(store.candidateKeys(forPhone: granted.id), [granted.key])
        XCTAssertEqual(store.computerKey(granted.id), identityKey)
        XCTAssertEqual(store.scopes(of: granted.id), ["shell", "screen"])
        XCTAssertTrue(store.screenAllowed(forPhone: granted.id))
        XCTAssertFalse(store.controlAllowed(forPhone: granted.id))
        XCTAssertFalse(store.isScreenOnly(granted.id))
        // Its own item: a build from before reads it neither as a phone nor as a pass.
        XCTAssertEqual(stored(secrets, Self.phonesItem)?.map(\.phoneID), ["phone"])
        XCTAssertNil(secrets.read(Self.passesItem))
        XCTAssertEqual(stored(secrets, Self.computersItem)?.map(\.phoneID), [granted.id])
        XCTAssertEqual(ShellAccessStore(secrets: secrets).computerKey(granted.id), identityKey, "read back")

        // Renaming the phone leaves the computer its name; nothing can claim its id.
        store.relabel(pairingSlot: "token.iphone.A", label: "New iPhone")
        XCTAssertEqual(store.phones.first { $0.phoneID == granted.id }?.label, "Office-PC")
        XCTAssertFalse(store.record(phone(granted.id, slot: "token.iphone.A")))

        // Removing the phone removes it, and its item.
        let (done, removed) = store.revokeReporting(phoneID: "phone")
        XCTAssertTrue(done)
        XCTAssertEqual(Set(removed.map(\.phoneID)), ["phone", granted.id])
        XCTAssertNil(store.computerKey(granted.id))
        XCTAssertTrue(store.scopes(of: granted.id).isEmpty)
        XCTAssertNil(secrets.read(Self.computersItem))
    }

    func testOnlyAPhoneThatMayShareGivesAComputerAccess() throws {
        let store = ShellAccessStore(secrets: InMemorySecrets())
        granter(store, screen: false)
        guard case .failure(.notAllowed) = grant(store) else { return XCTFail("the switch is off") }
        XCTAssertTrue(store.setShareAllowed(true, forPhone: "phone"))
        XCTAssertTrue(store.shareAllowed(forPhone: "phone"))
        guard case .failure(.screenNotAllowed) = grant(store) else { return XCTFail("the phone can't see the screen itself") }
        XCTAssertEqual(try grant(store, scopes: ["shell"]).get().scopes, ["shell"])
        guard case .failure(.badRequest) = grant(store, scopes: []) else { return XCTFail() }
        guard case .failure(.badRequest) = grant(store, scopes: ["files"]) else { return XCTFail() }
        guard case .failure(.badRequest) = store.grantComputer(by: "phone", name: "PC", viewer: "v", kind: nil,
                                                                identityKey: Data(repeating: 4, count: 33), scopes: ["shell"]) else { return XCTFail() }
        guard case .failure(.notAuthorized) = store.grantComputer(by: "stranger", name: "PC", viewer: "v", kind: nil,
                                                                   identityKey: identityKey, scopes: ["shell"]) else { return XCTFail() }
        // No onward grant: a computer can't give access, nor a pass.
        let computer = try grant(store, viewer: "mac-3", scopes: ["shell"]).get()
        guard case .failure(.notAuthorized) = store.grantComputer(by: computer.id, name: "PC", viewer: "v", kind: nil,
                                                                   identityKey: identityKey, scopes: ["shell"]) else { return XCTFail() }
        XCTAssertFalse(store.setShareAllowed(true, forPhone: computer.id))
        // Turning the switch off stops new grants and removes nothing.
        XCTAssertTrue(store.setShareAllowed(false, forPhone: "phone"))
        guard case .failure(.notAllowed) = grant(store, viewer: "mac-4", scopes: ["shell"]) else { return XCTFail() }
        XCTAssertEqual(store.scopes(of: computer.id), ["shell"])
    }

    func testEightComputersAPhoneAndThenRefused() throws {
        let store = ShellAccessStore(secrets: InMemorySecrets())
        sharer(store)
        var first: String?
        for n in 0..<Computers.maxPerGranter {
            let id = try grant(store, viewer: "m\(n)", scopes: ["shell"]).get().id
            if first == nil { first = id }
        }
        guard case .failure(.tooManyComputers) = grant(store, viewer: "m-new", scopes: ["shell"]) else { return XCTFail() }
        XCTAssertNotNil(store.computerKey(try XCTUnwrap(first)), "refused, never the oldest dropped")
        // Granting one of them again replaces it, and doesn't count: the earlier grant still works
        // until the new one is used, but it is neither listed nor counted meanwhile.
        let again = try grant(store, viewer: "m0", scopes: ["shell"]).get()
        XCTAssertEqual(again.replaced, [])
        XCTAssertNotNil(store.computerKey(try XCTUnwrap(first)))
        XCTAssertEqual(store.waitingComputerIDs, [try XCTUnwrap(first)])
        XCTAssertEqual(store.computers(grantedBy: "phone").count, Computers.maxPerGranter)
        XCTAssertFalse(store.computers(grantedBy: "phone").contains { $0.phoneID == first })
        XCTAssertNotNil(try? grant(store, viewer: "m1", scopes: ["shell"]).get(), "another one again, while the first waits")
        guard case .failure(.tooManyComputers) = grant(store, viewer: "m-new", scopes: ["shell"]) else { return XCTFail() }
        XCTAssertEqual(store.retireComputers(supersededBy: again.id).map(\.phoneID), [try XCTUnwrap(first)])
        XCTAssertNil(store.computerKey(try XCTUnwrap(first)))
        // A pass never pushes a computer out.
        let computers = store.phones.filter(\.isComputer).count
        for n in 0..<(ScreenPass.maxPerGranter + 1) { _ = try store.grantViewer(by: "phone", name: "Mac \(n)", viewer: "m\(n)").get() }
        XCTAssertEqual(store.phones.filter(\.isComputer).count, computers)
    }

    /// Sharing a computer again keeps the grant it has until it uses the new one: the hand-over to it may still fail.
    func testAnEarlierGrantStaysUntilTheNewOneIsUsed() throws {
        let secrets = InMemorySecrets()
        let store = ShellAccessStore(secrets: secrets)
        sharer(store)
        let a = try grant(store).get()
        let b = try grant(store).get()
        XCTAssertEqual(b.replaced, [], "kept, not replaced at grant time")
        XCTAssertEqual(store.computerKey(a.id), identityKey)
        XCTAssertEqual(store.scopes(of: a.id), ["shell", "screen"])
        XCTAssertEqual(store.candidateKeys(forPhone: a.id), [a.key])
        XCTAssertEqual(store.waitingComputerIDs, [a.id])
        XCTAssertEqual(store.computers(grantedBy: "phone").map(\.phoneID), [b.id], "one row a computer")
        XCTAssertEqual(Set(store.sameComputer(as: b.id)), [a.id, b.id])
        XCTAssertEqual(ShellAccessStore(secrets: secrets).waitingComputerIDs, [a.id], "kept across a relaunch")

        // The old grant connecting again retires nothing: only a newer one stands for it.
        XCTAssertTrue(store.retireComputers(supersededBy: a.id).isEmpty)
        XCTAssertTrue(store.retireComputers(supersededBy: "computer.nothing").isEmpty)

        // A third grant before either was used: only the newest earlier one is kept, as for passes.
        let c = try grant(store).get()
        XCTAssertEqual(c.replaced, [a.id])
        XCTAssertNil(store.computerKey(a.id))
        XCTAssertEqual(store.waitingComputerIDs, [b.id])

        // Used: the earlier one goes, and only for that computer.
        let other = try grant(store, viewer: "mac-3", scopes: ["shell"]).get()
        XCTAssertEqual(store.retireComputers(supersededBy: c.id).map(\.phoneID), [b.id])
        XCTAssertNil(store.computerKey(b.id))
        XCTAssertTrue(store.waitingComputerIDs.isEmpty)
        XCTAssertNotNil(store.computerKey(other.id))
        XCTAssertEqual(stored(secrets, Self.computersItem)?.map(\.phoneID), [c.id, other.id])
        XCTAssertTrue(store.retireComputers(supersededBy: c.id).isEmpty, "nothing left to retire")
    }

    /// The phone takes the new grant back (it couldn't hand it over): the one the computer has keeps working.
    func testTakingBackTheNewGrantLeavesTheEarlierOne() throws {
        let store = ShellAccessStore(secrets: InMemorySecrets())
        sharer(store)
        let a = try grant(store).get()
        let b = try grant(store).get()
        XCTAssertEqual(store.revokeComputer(b.id, grantedBy: "phone").removed.map(\.phoneID), [b.id])
        XCTAssertEqual(store.computerKey(a.id), identityKey)
        XCTAssertTrue(store.waitingComputerIDs.isEmpty)
        XCTAssertEqual(store.computers(grantedBy: "phone").map(\.phoneID), [a.id], "listed again, so it can be taken back too")
    }

    /// The owner sees one computer and takes it all away, a grant still waiting to be retired included.
    func testTheOwnerRevokesAComputersWaitingGrantToo() throws {
        let store = ShellAccessStore(secrets: InMemorySecrets())
        sharer(store)
        let a = try grant(store).get()
        let b = try grant(store).get()
        let other = try grant(store, viewer: "mac-3", scopes: ["shell"]).get()
        XCTAssertEqual(Set(store.revokeComputer(b.id).removed.map(\.phoneID)), [a.id, b.id])
        XCTAssertNil(store.computerKey(a.id))
        XCTAssertNil(store.computerKey(b.id))
        XCTAssertNotNil(store.computerKey(other.id))
    }

    /// Names are stored as they're shown: one line, no tabs, bidi or zero-width marks.
    func testGrantedNamesAreStoredClean() throws {
        let store = ShellAccessStore(secrets: InMemorySecrets())
        sharer(store)
        let computer = try store.grantComputer(by: "phone", name: "Office\tPC\u{202E}", viewer: "mac-2", kind: nil,
                                               identityKey: identityKey, scopes: ["shell"]).get()
        XCTAssertEqual(store.phones.first { $0.phoneID == computer.id }?.label, "Office PC")
        let pass = try store.grantViewer(by: "phone", name: "\u{200B}Lab Mac\u{200F}", viewer: "mac-3").get()
        XCTAssertEqual(store.phones.first { $0.phoneID == pass.id }?.label, "Lab Mac")
        // Nothing left once cleaned: refused, as an empty name is.
        guard case .failure(.badRequest) = store.grantComputer(by: "phone", name: "\u{200B}\u{200F}", viewer: "mac-4", kind: nil,
                                                                identityKey: identityKey, scopes: ["shell"]) else { return XCTFail() }
        guard case .failure(.badRequest) = store.grantViewer(by: "phone", name: "\u{200B}", viewer: "mac-5") else { return XCTFail() }
    }

    /// A computer may see the screen only while the phone that gave it access may.
    func testAComputersScreenFollowsItsPhone() throws {
        let store = ShellAccessStore(secrets: InMemorySecrets())
        sharer(store)
        let granted = try grant(store).get()
        XCTAssertTrue(store.setScreenAllowed(false, forPhone: "phone"))
        XCTAssertEqual(store.scopes(of: granted.id), ["shell"])
        XCTAssertFalse(store.screenAllowed(forPhone: granted.id))
        XCTAssertTrue(store.viewers(grantedBy: "phone").contains(granted.id), "so its views end with the phone's")
    }

    func testOnlyItsPhoneTakesAComputerBack() throws {
        let store = ShellAccessStore(secrets: InMemorySecrets())
        sharer(store)
        store.record(phone("other", slot: "token.iphone.C"))
        let granted = try grant(store).get()
        XCTAssertTrue(store.revokeComputer(granted.id, grantedBy: "other").removed.isEmpty)
        XCTAssertTrue(store.revokeComputer("computer.nothing", grantedBy: "phone").removed.isEmpty)
        XCTAssertEqual(store.revokeComputer(granted.id, grantedBy: "phone").removed.map(\.phoneID), [granted.id])
        XCTAssertNil(store.computerKey(granted.id))
        XCTAssertNotNil(store.key(forPhone: "phone"))
    }

    /// The owner takes a computer back whichever phone gave it; only that computer goes.
    func testTheOwnerTakesAComputerBack() throws {
        let store = ShellAccessStore(secrets: InMemorySecrets())
        sharer(store)
        let granted = try grant(store).get()
        XCTAssertTrue(store.revokeComputer("computer.nothing").removed.isEmpty)
        XCTAssertTrue(store.revokeComputer("phone").removed.isEmpty, "never a phone, by this path")
        XCTAssertEqual(store.revokeComputer(granted.id).removed.map(\.phoneID), [granted.id])
        XCTAssertNil(store.computerKey(granted.id))
        XCTAssertNotNil(store.key(forPhone: "phone"))
        XCTAssertTrue(store.computers(grantedBy: "phone").isEmpty)
    }

    /// Turning sharing off holds in memory when it can't be saved, and the switch survives a re-grant.
    func testShareOffHoldsWhenTheWriteFails() throws {
        let secrets = OneItemFails()
        let store = ShellAccessStore(secrets: secrets)
        sharer(store)
        store.record(phone("phone", slot: "token.iphone.A"))
        XCTAssertTrue(store.shareAllowed(forPhone: "phone"), "kept across a re-grant")
        secrets.failing.set(Self.phonesItem)
        XCTAssertFalse(store.setShareAllowed(false, forPhone: "phone"))
        XCTAssertFalse(store.shareAllowed(forPhone: "phone"))
        guard case .failure(.notAllowed) = grant(store, scopes: ["shell"]) else { return XCTFail() }
    }

    /// A computer whose phone is gone, or that was stored among the phones, is never used.
    func testAComputerWithoutItsPhoneIsDropped() throws {
        let secrets = InMemorySecrets()
        let orphan = ShellPhone(phoneID: Computers.newID(), label: "Office-PC", pairingSlot: "token.iphone.A", key: ShellAccessStore.newKey(),
                                grantedAt: Date(), control: false, grantedBy: "phone", viewerOf: "mac-2", identityKey: identityKey, shell: true)
        secrets.write(try JSONEncoder().encode([orphan]), account: Self.computersItem)
        secrets.write(try JSONEncoder().encode([phone("other", slot: "token.iphone.C"), orphan]), account: Self.phonesItem)
        let store = ShellAccessStore(secrets: secrets)
        XCTAssertNil(store.computerKey(orphan.phoneID))
        XCTAssertEqual(store.phones.map(\.phoneID), ["other"], "not taken for a phone either")
    }
}
private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var time = Date(timeIntervalSince1970: 1_000)
    var now: Date { lock.lock(); defer { lock.unlock() }; return time }
    func advance(_ seconds: TimeInterval) { lock.lock(); time += seconds; lock.unlock() }

}
#endif
