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

    /// Link-local (AWDL), ULA and on-link global addresses are counted by
    /// /64 too: a stranger taking many addresses on the link gets one share.
    func testNeighboursShareTheirSlash64() {
        queue.sync {
            let limiter = HandshakeLimiter(queue: queue, timeout: 60, maxTotal: 16, maxPerHost: 2, reservedForProven: 0)
            for prefix in ["fe80::", "fd00:1:2:3::"] {
                XCTAssertNotNil(limiter.acquire(host: prefix + "1%awdl0") {})
                XCTAssertNotNil(limiter.acquire(host: prefix + "2%en0") {})
                XCTAssertNil(limiter.acquire(host: prefix + "3") {}, prefix)
            }
        }
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
