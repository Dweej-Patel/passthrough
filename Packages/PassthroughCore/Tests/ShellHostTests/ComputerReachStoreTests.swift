#if os(macOS)
import XCTest
import PassthroughCore
@testable import ShellHost

/// What this Mac keeps of access to other computers (stage 7 a.5), and the replace rule.
final class ComputerReachStoreTests: XCTestCase {
    private func reachable(_ host: String = "pc-1", cert: String = String(repeating: "a", count: 64), iroh: String? = nil,
                           from: String = "phone") -> ReachableComputer {
        let credential = ShellCredential(macID: host, macName: "Office-PC", certSHA256: cert, shellKey: ShellAccessStore.newKey(),
                                         phoneID: Computers.newID(), port: 7893, addresses: ["192.168.1.9"], irohID: iroh,
                                         hostKind: HostInfo.kindWindows)
        return ReachableComputer(credential: credential, scopes: ["shell"], from: "iPhone", fromPhoneID: from, receivedAt: Date())
    }

    func testANewerOneWithTheSameDetailsReplaces() {
        let store = ComputerReachStore(secrets: InMemorySecrets())
        let first = reachable(iroh: String(repeating: "b", count: 64))
        XCTAssertEqual(store.save(first), .saved(replaced: nil))
        let second = reachable(iroh: String(repeating: "b", count: 64))
        XCTAssertEqual(store.save(second), .saved(replaced: first))
        XCTAssertEqual(store.computers, [second])
    }

    func testDifferentDetailsAreRefusedAndChangeNothing() {
        let store = ComputerReachStore(secrets: InMemorySecrets())
        let kept = reachable()
        XCTAssertEqual(store.save(kept), .saved(replaced: nil))
        XCTAssertEqual(store.save(reachable(cert: String(repeating: "c", count: 64))), .conflict)
        XCTAssertEqual(store.save(reachable(iroh: String(repeating: "d", count: 64))), .conflict)
        XCTAssertEqual(store.computers, [kept])
        // Removed first, it can be handed over again with new details.
        XCTAssertTrue(store.remove(hostID: "pc-1"))
        XCTAssertEqual(store.save(reachable(cert: String(repeating: "c", count: 64))), .saved(replaced: nil))
    }

    func testOnlyUsableAccessIsKept() {
        let store = ComputerReachStore(secrets: InMemorySecrets())
        var pass = reachable()
        pass.credential.phoneID = "viewer.abc"
        XCTAssertEqual(store.save(pass), .notUsable)
        var unscoped = reachable()
        unscoped.scopes = []
        XCTAssertEqual(store.save(unscoped), .notUsable)
    }

    func testRevokingThePhoneForgetsWhatItHandedOver() {
        let store = ComputerReachStore(secrets: InMemorySecrets())
        XCTAssertEqual(store.save(reachable("pc-1")), .saved(replaced: nil))
        XCTAssertEqual(store.save(reachable("pc-2", from: "other")), .saved(replaced: nil))
        let (done, hosts) = store.remove(fromPhones: ["phone"])
        XCTAssertTrue(done)
        XCTAssertEqual(hosts, ["pc-1"])
        XCTAssertEqual(store.computers.map(\.id), ["pc-2"])
        XCTAssertEqual(store.save(reachable("pc-3")), .failed, "nothing from a revoked phone")
        store.allowSender("phone")
        XCTAssertEqual(store.save(reachable("pc-3")), .saved(replaced: nil))
    }

    func testSixteenAndThenRefused() {
        let store = ComputerReachStore(secrets: InMemorySecrets())
        for n in 0..<ComputerReachStore.maxComputers { XCTAssertEqual(store.save(reachable("pc-\(n)")), .saved(replaced: nil)) }
        XCTAssertEqual(store.save(reachable("pc-new")), .failed)
        XCTAssertEqual(store.computers.count, ComputerReachStore.maxComputers)
    }
}
#endif
