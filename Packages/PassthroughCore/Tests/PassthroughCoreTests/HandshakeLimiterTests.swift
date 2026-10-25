import Foundation
import XCTest
import PassthroughCore
@testable import PhoneTransport

final class HandshakeLimiterTests: XCTestCase {
    private let queue = DispatchQueue(label: "limiter-test")

    func testLimitsPerHostAndInAll() {
        queue.sync {
            let limiter = HandshakeLimiter(queue: queue, timeout: 60, maxTotal: 3, maxPerHost: 2, reservedForProven: 0)
            let a1 = limiter.acquire(host: "a") {}, a2 = limiter.acquire(host: "a") {}
            XCTAssertNotNil(a1); XCTAssertNotNil(a2)
            XCTAssertNil(limiter.acquire(host: "a") {}, "a third from one address is refused")
            XCTAssertNotNil(limiter.acquire(host: "b") {})
            XCTAssertNil(limiter.acquire(host: "c") {}, "every slot is taken")
            XCTAssertTrue(a1!.release())
            XCTAssertFalse(a1!.release(), "a slot is freed once")
            XCTAssertEqual(limiter.count, 2)
            XCTAssertNotNil(limiter.acquire(host: "a") {})
        }
    }

    func testIPv6PeersShareTheirSlash64() {
        queue.sync {
            let limiter = HandshakeLimiter(queue: queue, timeout: 60, maxTotal: 16, maxPerHost: 2, reservedForProven: 0)
            let a = limiter.acquire(host: "2001:db8:1:2::1") {}
            let b = limiter.acquire(host: "2001:db8:1:2:aaaa:bbbb:cccc:dddd") {}
            XCTAssertNotNil(a); XCTAssertNotNil(b)
            XCTAssertNil(limiter.acquire(host: "2001:db8:1:2::99%en0") {}, "a third address in the same /64 is refused")
            XCTAssertNotNil(limiter.acquire(host: "2001:db8:1:3::1") {}, "another /64 has its own share")
            XCTAssertTrue(a!.release())
            XCTAssertNotNil(limiter.acquire(host: "2001:db8:1:2::7") {}, "releasing frees the /64's share")
            XCTAssertNotNil(limiter.acquire(host: "192.168.1.5") {})
            XCTAssertNotNil(limiter.acquire(host: "192.168.1.6") {}, "private IPv4 hosts stay counted individually")
        }
    }

    /// ULA and on-link global addresses are counted by /64 too: a stranger
    /// taking many addresses on the link gets one share.
    func testULANeighboursShareTheirSlash64() {
        queue.sync {
            let limiter = HandshakeLimiter(queue: queue, timeout: 60, maxTotal: 16, maxPerHost: 2, reservedForProven: 0)
            XCTAssertNotNil(limiter.acquire(host: "fd00:1:2:3::1%en0") {})
            XCTAssertNotNil(limiter.acquire(host: "fd00:1:2:3::2") {})
            XCTAssertNil(limiter.acquire(host: "fd00:1:2:3::3") {})
        }
    }

    /// Every AWDL or LAN neighbour is in fe80::/64, so link-local peers are
    /// counted by address: a chatty neighbour holding its share leaves the
    /// owner's phone (not yet proven, say after a relaunch) its own.
    func testLinkLocalPeersAreCountedByAddress() {
        queue.sync {
            let limiter = HandshakeLimiter(queue: queue, timeout: 60, maxTotal: 16, maxPerHost: 2, reservedForProven: 0)
            XCTAssertNotNil(limiter.acquire(host: "fe80::1%awdl0") {})
            XCTAssertNotNil(limiter.acquire(host: "fe80::1%awdl0") {})
            XCTAssertNil(limiter.acquire(host: "fe80::1%en0") {}, "one address, whatever the link")
            XCTAssertNotNil(limiter.acquire(host: "fe80::2%awdl0") {}, "another neighbour has its own share")
            XCTAssertNotNil(limiter.acquire(host: "febf::9") {}, "all of fe80::/10")
            XCTAssertEqual(HandshakeLimiter.bucket("fe80::1%awdl0"), HandshakeLimiter.bucket("fe80::1"))
            XCTAssertNotEqual(HandshakeLimiter.bucket("fe80::1"), HandshakeLimiter.bucket("fe80::2"))
            XCTAssertEqual(HandshakeLimiter.bucket("2001:db8::1"), HandshakeLimiter.bucket("2001:db8::2"))
        }
    }

    /// Proven addresses outlive the limiter (an app relaunch) through its
    /// store: a new limiter on the same store keeps their reserved slots.
    func testProvenAddressesSurviveARelaunch() {
        let store = MemoryProvenAddressStore()
        queue.sync {
            let first = HandshakeLimiter(queue: queue, timeout: 60, maxTotal: 2, maxPerHost: 2, reservedForProven: 1, store: store)
            first.proven("192.168.1.5")
            first.proven("fe80::77%awdl0")
            first.proven("relay")
        }
        XCTAssertEqual(Set(store.load().keys), ["192.168.1.5", "fe80::77"])
        queue.sync {
            let relaunched = HandshakeLimiter(queue: queue, timeout: 60, maxTotal: 2, maxPerHost: 2, reservedForProven: 1, store: store)
            XCTAssertTrue(relaunched.isProven("192.168.1.5"))
            XCTAssertTrue(relaunched.isProven("fe80::77"))
            XCTAssertNotNil(relaunched.acquire(host: "192.168.1.9") {})
            XCTAssertNil(relaunched.acquire(host: "192.168.1.10") {}, "the shared slot is taken")
            XCTAssertNotNil(relaunched.acquire(host: "192.168.1.5") {}, "the proven address still has the reserved one")
        }
    }

    /// What is read back drops expired entries, anything but addresses, and
    /// all but the newest `provenLimit`; a date ahead of the clock counts as now.
    func testStoredProvenAddressesAreCheckedOnLoad() {
        let now = Date(timeIntervalSince1970: 100_000_000)
        var table: [String: Date] = [
            "10.0.0.1": now - 60,
            "10.0.0.2": now - HandshakeLimiter.provenFor - 1,
            "relay": now,
            "10.0.0.3": now + 10 * HandshakeLimiter.provenFor,
        ]
        for i in 0..<(HandshakeLimiter.provenLimit + 10) {
            table["10.1.\(i / 256).\(i % 256)"] = now - 3600 - TimeInterval(i)
        }
        let kept = HandshakeLimiter.kept(table, at: now)
        XCTAssertEqual(kept.count, HandshakeLimiter.provenLimit)
        XCTAssertEqual(kept["10.0.0.1"], now - 60)
        XCTAssertNil(kept["10.0.0.2"], "expired")
        XCTAssertNil(kept["relay"])
        XCTAssertEqual(kept["10.0.0.3"], now, "from the future: as of now")
        XCTAssertNotNil(kept["10.1.0.0"])
        XCTAssertNil(kept["10.1.1.9"], "the oldest went past the cap")
    }

    /// An address proven again is written down only once its stored date is
    /// an hour old; a new one at once.
    func testProvenAgainIsNotRewrittenEveryTime() {
        final class Counting: ProvenAddressStore, @unchecked Sendable {
            var saves = 0
            var table: [String: Date] = [:]
            func load() -> [String: Date] { table }
            func save(_ proven: [String: Date]) { saves += 1; table = proven }
        }
        let store = Counting()
        let clock = Locked(Date(timeIntervalSince1970: 1_000_000))
        queue.sync {
            let limiter = HandshakeLimiter(queue: queue, timeout: 60, store: store, now: { clock.get() })
            limiter.proven("192.168.1.5")
            limiter.proven("192.168.1.5")
            XCTAssertEqual(store.saves, 1)
            limiter.proven("192.168.1.6")
            XCTAssertEqual(store.saves, 2)
            clock.set(clock.get() + HandshakeLimiter.resaveInterval)
            limiter.proven("192.168.1.5")
            XCTAssertEqual(store.saves, 3)
            XCTAssertEqual(store.table["192.168.1.5"], clock.get())
        }
    }

    /// The file store reads back what it wrote, keeps it 0600, and treats a
    /// missing or damaged file as empty.
    func testFileStoreRoundTripsPrivately() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ProvenStore-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("proven.json")
        let store = FileProvenAddressStore(url: url)
        XCTAssertEqual(store.load(), [:])
        let table = ["192.168.1.5": Date(timeIntervalSince1970: 1_000_000), "fe80::77": Date(timeIntervalSince1970: 2_000_000)]
        store.save(table)
        XCTAssertEqual(store.load(), table, "load waits for the write")
        XCTAssertEqual(FileProvenAddressStore(url: url).load(), table)
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
        let folderMode = try FileManager.default.attributesOfItem(atPath: folder.path)[.posixPermissions] as? Int
        XCTAssertEqual(folderMode, 0o700)
        store.save([:])
        XCTAssertEqual(store.load(), [:])
        try Data("not json".utf8).write(to: url)
        XCTAssertEqual(store.load(), [:])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), ["proven.json"], "no temporary files left")
    }

    /// Public IPv4 peers are counted by /24; private, Tailscale and
    /// link-local ones by address.
    func testPublicIPv4PeersShareTheirSlash24() {
        queue.sync {
            let limiter = HandshakeLimiter(queue: queue, timeout: 60, maxTotal: 16, maxPerHost: 2, reservedForProven: 0)
            XCTAssertNotNil(limiter.acquire(host: "203.0.113.5") {})
            XCTAssertNotNil(limiter.acquire(host: "203.0.113.200") {})
            XCTAssertNil(limiter.acquire(host: "203.0.113.9") {}, "a third address in the /24")
            XCTAssertNotNil(limiter.acquire(host: "203.0.114.9") {})
            for host in ["10.0.0.1", "10.0.0.2", "172.16.0.1", "172.16.0.2", "100.100.1.1", "100.100.1.2", "169.254.1.1", "169.254.1.2"] {
                XCTAssertNotNil(limiter.acquire(host: host) {}, host)
            }
        }
    }

    /// Strangers holding every shared slot cannot lock out an address that
    /// proved itself: four slots are kept for those, and a proven address
    /// is counted on its own rather than in its crowded /64.
    func testProvenAddressesKeepReservedSlots() {
        queue.sync {
            let limiter = HandshakeLimiter(queue: queue, timeout: 60)
            limiter.proven("fe80::77%awdl0")
            limiter.proven("relay")   // not an address: never remembered
            var held: [HandshakeLimiter.Slot] = []
            for i in 0..<20 {
                if let slot = limiter.acquire(host: "192.168.1.\(i + 10)", onTimeout: {}) { held.append(slot) }
            }
            XCTAssertEqual(held.count, 12, "strangers get the shared slots only")
            XCTAssertNil(limiter.acquire(host: "192.168.1.99") {})
            XCTAssertNil(limiter.acquire(host: "relay", maxForHost: 8) {})
            XCTAssertNotNil(limiter.acquire(host: "fe80::77%en0") {}, "the proven address uses a reserved slot")
            XCTAssertNotNil(limiter.acquire(host: "fe80::77") {})
            XCTAssertNil(limiter.acquire(host: "fe80::77") {}, "still two at once from one address")
            XCTAssertEqual(limiter.count, 14)
        }
    }

    func testProvenAddressesAreForgottenAfterThirtyDays() {
        let clock = Locked(Date(timeIntervalSince1970: 1_000_000))
        queue.sync {
            let limiter = HandshakeLimiter(queue: queue, timeout: 60, maxTotal: 2, maxPerHost: 2, reservedForProven: 1,
                                           now: { clock.get() })
            limiter.proven("192.168.1.5")
            XCTAssertTrue(limiter.isProven("192.168.1.5"))
            clock.set(clock.get() + HandshakeLimiter.provenFor - 1)
            XCTAssertTrue(limiter.isProven("192.168.1.5"))
            clock.set(clock.get() + 2)
            XCTAssertFalse(limiter.isProven("192.168.1.5"))
            XCTAssertNotNil(limiter.acquire(host: "192.168.1.5") {})
            XCTAssertNil(limiter.acquire(host: "192.168.1.5") {}, "unproven again: the reserved slot is not for it")
        }
    }

    func testTimeoutFreesTheSlotOnce() {
        let limiter = queue.sync { HandshakeLimiter(queue: queue, timeout: 0.1, maxTotal: 1, maxPerHost: 1, reservedForProven: 0) }
        let timedOut = expectation(description: "timed out")
        let released = expectation(description: "not timed out")
        released.isInverted = true
        queue.sync {
            let slot = limiter.acquire(host: "a") { timedOut.fulfill() }
            XCTAssertNotNil(slot)
            XCTAssertNil(limiter.acquire(host: "b") {})
        }
        wait(for: [timedOut], timeout: 2)
        queue.sync {
            XCTAssertEqual(limiter.count, 0)
            let slot = limiter.acquire(host: "b") { released.fulfill() }
            XCTAssertTrue(slot?.release() == true, "released before the timeout")
        }
        wait(for: [released], timeout: 0.3)
    }
}
