import Foundation
import XCTest
@testable import PhoneTransport

final class HandshakeLimiterTests: XCTestCase {
    private let queue = DispatchQueue(label: "limiter-test")

    func testLimitsPerHostAndInAll() {
        queue.sync {
            let limiter = HandshakeLimiter(queue: queue, timeout: 60, maxTotal: 3, maxPerHost: 2)
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
            let limiter = HandshakeLimiter(queue: queue, timeout: 60, maxTotal: 16, maxPerHost: 2)
            let a = limiter.acquire(host: "2001:db8:1:2::1") {}
            let b = limiter.acquire(host: "2001:db8:1:2:aaaa:bbbb:cccc:dddd") {}
            XCTAssertNotNil(a); XCTAssertNotNil(b)
            XCTAssertNil(limiter.acquire(host: "2001:db8:1:2::99%en0") {}, "a third address in the same /64 is refused")
            XCTAssertNotNil(limiter.acquire(host: "2001:db8:1:3::1") {}, "another /64 has its own share")
            XCTAssertTrue(a!.release())
            XCTAssertNotNil(limiter.acquire(host: "2001:db8:1:2::7") {}, "releasing frees the /64's share")
            XCTAssertNotNil(limiter.acquire(host: "192.168.1.5") {})
            XCTAssertNotNil(limiter.acquire(host: "192.168.1.6") {}, "IPv4 hosts stay counted individually")
        }
    }

    /// Neighbours share a /64 with every other phone on the link, so each
    /// address keeps its own share: link-local (AWDL), ULA, and global
    /// addresses in a /64 the Mac is on itself.
    func testNeighboursAreCountedPerAddress() {
        queue.sync {
            let onLink: Set<Data> = [Data([0x20, 0x01, 0x0d, 0xb8, 0, 1, 0, 2])]
            let limiter = HandshakeLimiter(queue: queue, timeout: 60, maxTotal: 16, maxPerHost: 2, onLinkPrefixes: { onLink })
            for host in ["fe80::1%awdl0", "fe80::2%awdl0", "fe80::3%en0", "fd00:1:2:3::1", "fd00:1:2:3::2",
                         "2001:db8:1:2::1", "2001:db8:1:2::2", "2001:db8:1:2::3"] {
                XCTAssertNotNil(limiter.acquire(host: host) {}, host)
            }
            XCTAssertNotNil(limiter.acquire(host: "fe80::1%awdl0") {})
            XCTAssertNil(limiter.acquire(host: "fe80::1%en0") {}, "one address still gets only its share")
            XCTAssertNotNil(limiter.acquire(host: "2001:db8:9:9::1") {})
            XCTAssertNotNil(limiter.acquire(host: "2001:db8:9:9::2") {})
            XCTAssertNil(limiter.acquire(host: "2001:db8:9:9::3") {}, "a /64 beyond the Mac's links is still counted as one")
        }
    }

    func testTimeoutFreesTheSlotOnce() {
        let limiter = queue.sync { HandshakeLimiter(queue: queue, timeout: 0.1, maxTotal: 1, maxPerHost: 1) }
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
