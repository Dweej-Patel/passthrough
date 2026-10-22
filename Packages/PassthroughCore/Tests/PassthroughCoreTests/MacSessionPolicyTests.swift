import XCTest
@testable import PassthroughCore

final class MacSessionPolicyTests: XCTestCase {
    private let a1 = ShellGrantLedger.contents(certificateSHA256: "cert", port: 7000, macName: "Mac",
                                               irohID: nil, irohRelay: nil, relayToken: nil)
    private let a2 = ShellGrantLedger.contents(certificateSHA256: "cert", port: 7000, macName: "Mac",
                                               irohID: "endpoint", irohRelay: "https://relay", relayToken: nil)

    func testHelperReregistersOncePerSeries() {
        var policy = HelperRecoveryPolicy()
        XCTAssertFalse(policy.shouldReregister(registered: true, responded: true, inUse: false))
        XCTAssertFalse(policy.shouldReregister(registered: false, responded: false, inUse: false))
        XCTAssertTrue(policy.shouldReregister(registered: true, responded: false, inUse: false))
        XCTAssertFalse(policy.shouldReregister(registered: true, responded: false, inUse: false))
        policy.reset()
        XCTAssertTrue(policy.shouldReregister(registered: true, responded: false, inUse: false))
    }

    func testHelperInUseIsNeverReregistered() {
        var policy = HelperRecoveryPolicy()
        XCTAssertFalse(policy.shouldReregister(registered: true, responded: false, inUse: true))
        XCTAssertFalse(policy.attempted, "a refused attempt is not used up")
        XCTAssertTrue(policy.shouldReregister(registered: true, responded: false, inUse: false))
    }

    func testGrantOncePerCableConnection() {
        var ledger = ShellGrantLedger()
        XCTAssertTrue(ledger.shouldGrant(deviceID: "a", contents: a1))
        ledger.sent(deviceID: "a", contents: a1, grantID: "g1")
        XCTAssertFalse(ledger.shouldGrant(deviceID: "a", contents: a1), "no second grant while one is in flight")
        XCTAssertTrue(ledger.confirmed(deviceID: "a", grantID: "g1"))
        XCTAssertFalse(ledger.shouldGrant(deviceID: "a", contents: a1), "tunnel retries don't re-grant")
        XCTAssertTrue(ledger.shouldGrant(deviceID: "b", contents: a1))
        ledger.detached(deviceID: "a")
        XCTAssertTrue(ledger.shouldGrant(deviceID: "a", contents: a1), "a new cable connection grants again")
    }

    func testChangedContentsGrantAgain() {
        var ledger = ShellGrantLedger()
        ledger.sent(deviceID: "a", contents: a1, grantID: "g1")
        ledger.confirmed(deviceID: "a", grantID: "g1")
        XCTAssertNotEqual(a1, a2)
        XCTAssertTrue(ledger.shouldGrant(deviceID: "a", contents: a2), "the iroh endpoint came up")
        ledger.sent(deviceID: "a", contents: a2, grantID: "g2")
        ledger.confirmed(deviceID: "a", grantID: "g2")
        XCTAssertFalse(ledger.shouldGrant(deviceID: "a", contents: a2))
        XCTAssertTrue(ledger.shouldGrant(deviceID: "a", contents: a1), "the endpoint went away again")
    }

    func testNoBackToBackGrants() {
        var ledger = ShellGrantLedger()
        ledger.sent(deviceID: "a", contents: a1, grantID: "g1")
        XCTAssertFalse(ledger.shouldGrant(deviceID: "a", contents: a2), "contents changed mid-flight: wait for the answer")
        XCTAssertFalse(ledger.confirmed(deviceID: "a", grantID: "other"), "an answer to another grant records nothing")
        XCTAssertFalse(ledger.shouldGrant(deviceID: "a", contents: a2))
        XCTAssertTrue(ledger.confirmed(deviceID: "a", grantID: "g1"))
        XCTAssertTrue(ledger.shouldGrant(deviceID: "a", contents: a2), "re-checked after the answer: the new contents go out")
        XCTAssertFalse(ledger.shouldGrant(deviceID: "a", contents: a1))
    }

    func testContentsFingerprintIsUnambiguous() {
        let x = ShellGrantLedger.contents(certificateSHA256: "ab", port: 1, macName: "c", irohID: nil, irohRelay: nil, relayToken: nil)
        let y = ShellGrantLedger.contents(certificateSHA256: "a", port: 1, macName: "bc", irohID: nil, irohRelay: nil, relayToken: nil)
        XCTAssertNotEqual(x, y)
        let t1 = ShellGrantLedger.contents(certificateSHA256: "c", port: 1, macName: "m", irohID: "i", irohRelay: "r", relayToken: "t1")
        let t2 = ShellGrantLedger.contents(certificateSHA256: "c", port: 1, macName: "m", irohID: "i", irohRelay: "r", relayToken: "t2")
        XCTAssertNotEqual(t1, t2, "a new relay token is a new grant")
    }

    func testUnansweredGrantIsRetriedOnNextChannel() {
        var ledger = ShellGrantLedger()
        ledger.sent(deviceID: "a", contents: a1, grantID: "g1")
        ledger.channelClosed(deviceID: "a")
        XCTAssertTrue(ledger.shouldGrant(deviceID: "a", contents: a1))
        XCTAssertFalse(ledger.confirmed(deviceID: "a", grantID: "g1"), "a late answer from the closed channel records nothing")
    }

    func testResetGrantsAgain() {
        var ledger = ShellGrantLedger()
        ledger.sent(deviceID: "a", contents: a1, grantID: "g1")
        ledger.confirmed(deviceID: "a", grantID: "g1")
        ledger.reset()
        XCTAssertTrue(ledger.shouldGrant(deviceID: "a", contents: a1), "forgetting the pairing hands out a key again")
    }

    func testRevokeHoldsOnlyThatDevice() {
        var ledger = ShellGrantLedger()
        ledger.sent(deviceID: "a", contents: a1, grantID: "g1")
        ledger.revoked(deviceID: "a")
        XCTAssertFalse(ledger.confirmed(deviceID: "a", grantID: "g1"), "a late answer for the revoked phone records nothing")
        XCTAssertFalse(ledger.shouldGrant(deviceID: "a", contents: a1), "no key right after revoking")
        XCTAssertFalse(ledger.shouldGrant(deviceID: "a", contents: a2), "not even when the contents change")
        XCTAssertTrue(ledger.isHeld(deviceID: "a"))
        XCTAssertTrue(ledger.shouldGrant(deviceID: "b", contents: a1), "other phones are not held")
        ledger.channelOpened(deviceID: "b")
        XCTAssertTrue(ledger.isHeld(deviceID: "a"), "another phone's channel doesn't lift the hold")
        ledger.channelOpened(deviceID: "a")
        XCTAssertTrue(ledger.shouldGrant(deviceID: "a", contents: a1), "a new channel (re-plug) grants again")
    }

    func testPairingLiftsRevokeHold() {
        var ledger = ShellGrantLedger()
        ledger.revoked(deviceID: "a")
        ledger.paired(deviceID: "a")
        XCTAssertTrue(ledger.shouldGrant(deviceID: "a", contents: a1), "a phone pairing anew gets its grant")
        ledger.revoked(deviceID: "a")
        ledger.detached(deviceID: "a")
        XCTAssertTrue(ledger.shouldGrant(deviceID: "a", contents: a1))
    }

    func testUnansweredGrantExpires() {
        var ledger = ShellGrantLedger()
        ledger.sent(deviceID: "a", contents: a1, grantID: "g1")
        XCTAssertFalse(ledger.shouldGrant(deviceID: "a", contents: a2))
        let t0 = Date()
        XCTAssertEqual(ledger.expired(deviceID: "a", grantID: "other", now: t0), .stale, "only the grant still in flight expires")
        XCTAssertEqual(ledger.expired(deviceID: "a", grantID: "g1", now: t0), .retry(after: 15, firstTimeout: true))
        XCTAssertTrue(ledger.shouldGrant(deviceID: "a", contents: a2, now: t0), "a lost grant no longer blocks other contents")
        XCTAssertFalse(ledger.shouldGrant(deviceID: "a", contents: a1, now: t0), "the same contents wait out the backoff")
        XCTAssertTrue(ledger.shouldGrant(deviceID: "a", contents: a1, now: t0 + 15), "nothing was recorded as granted")
        XCTAssertFalse(ledger.confirmed(deviceID: "a", grantID: "g1"), "a very late answer records nothing")
        ledger.sent(deviceID: "a", contents: a1, grantID: "g2")
        ledger.confirmed(deviceID: "a", grantID: "g2")
        XCTAssertEqual(ledger.expired(deviceID: "a", grantID: "g2"), .stale, "an answered grant does not expire")
        XCTAssertFalse(ledger.shouldGrant(deviceID: "a", contents: a1))
        XCTAssertEqual(ShellGrantLedger.answerTimeout, 15)
    }

    /// Sends a grant of `contents` and lets it time out at `now`.
    private func timeOut(_ ledger: inout ShellGrantLedger, _ id: String, contents: String, now: Date) -> ShellGrantLedger.Expiry {
        ledger.sent(deviceID: "a", contents: contents, grantID: id)
        return ledger.expired(deviceID: "a", grantID: id, now: now)
    }

    func testUnansweredGrantsBackOffThenRetrySlowly() {
        var ledger = ShellGrantLedger()
        var now = Date()
        var outcomes: [ShellGrantLedger.Expiry] = []
        for i in 0..<7 {
            XCTAssertTrue(ledger.shouldGrant(deviceID: "a", contents: a1, now: now), "grant \(i)")
            let expiry = timeOut(&ledger, "g\(i)", contents: a1, now: now)
            outcomes.append(expiry)
            if case .retry(let delay, _) = expiry {
                XCTAssertFalse(ledger.shouldGrant(deviceID: "a", contents: a1, now: now + delay - 1), "still waiting after grant \(i)")
                now += delay
            }
        }
        XCTAssertEqual(outcomes, [.retry(after: 15, firstTimeout: true), .retry(after: 30, firstTimeout: false),
                                  .retry(after: 60, firstTimeout: false), .retry(after: 120, firstTimeout: false),
                                  .retry(after: 600, firstTimeout: false), .retry(after: 600, firstTimeout: false), .retry(after: 600, firstTimeout: false)])
        XCTAssertEqual(ShellGrantLedger.slowRetryDelay, 600)
        XCTAssertTrue(ledger.shouldGrant(deviceID: "b", contents: a1, now: now), "other phones are unaffected")
    }

    func testSlowRetriesEndOnChannelPairingContentsOrAnswer() {
        func slowRetrying() -> ShellGrantLedger {
            var ledger = ShellGrantLedger()
            var now = Date()
            for i in 0..<5 {
                if case .retry(let delay, _) = timeOut(&ledger, "g\(i)", contents: a1, now: now) { now += delay }
            }
            XCTAssertFalse(ledger.shouldGrant(deviceID: "a", contents: a1, now: Date()), "waiting the slow retry out")
            return ledger
        }
        var ledger = slowRetrying()
        ledger.channelOpened(deviceID: "a")
        XCTAssertTrue(ledger.shouldGrant(deviceID: "a", contents: a1), "a new channel starts afresh")
        XCTAssertEqual(timeOut(&ledger, "n", contents: a1, now: Date()), .retry(after: 15, firstTimeout: true))

        ledger = slowRetrying()
        ledger.paired(deviceID: "a")
        XCTAssertTrue(ledger.shouldGrant(deviceID: "a", contents: a1), "pairing anew starts afresh")

        ledger = slowRetrying()
        ledger.detached(deviceID: "a")
        XCTAssertTrue(ledger.shouldGrant(deviceID: "a", contents: a1), "re-plugging starts afresh")

        ledger = slowRetrying()
        XCTAssertTrue(ledger.shouldGrant(deviceID: "a", contents: a2), "new contents go out")
        XCTAssertEqual(timeOut(&ledger, "c", contents: a2, now: Date()), .retry(after: 15, firstTimeout: true), "with a new streak")

        // An answer ends the streak: the next run of timeouts starts at 15 s again.
        ledger = ShellGrantLedger()
        _ = timeOut(&ledger, "x1", contents: a1, now: Date())
        _ = timeOut(&ledger, "x2", contents: a1, now: Date() + 15)
        ledger.sent(deviceID: "a", contents: a1, grantID: "x3")
        XCTAssertTrue(ledger.confirmed(deviceID: "a", grantID: "x3"))
        XCTAssertEqual(timeOut(&ledger, "y", contents: a1, now: Date()), .retry(after: 15, firstTimeout: true))
    }

    func testAnswerAttribution() {
        XCTAssertTrue(ShellGrantLedger.answerMatches(echoedGrantID: "g2", inFlightGrantID: "g2"))
        XCTAssertFalse(ShellGrantLedger.answerMatches(echoedGrantID: "g1", inFlightGrantID: "g2"), "a late answer to an expired grant")
        XCTAssertFalse(ShellGrantLedger.answerMatches(echoedGrantID: "", inFlightGrantID: "g2"))
        XCTAssertTrue(ShellGrantLedger.answerMatches(echoedGrantID: nil, inFlightGrantID: "g2"), "older phones echo no ID")
    }

    func testShellChannelBackoff() {
        var backoff = ShellChannelBackoff()
        let delays = (0..<6).map { _ in backoff.failed() }
        XCTAssertEqual(delays.map(\.delay), [10, 20, 40, 80, 120, 120])
        XCTAssertEqual(delays.map(\.log), [true, false, false, false, false, false])
        backoff.succeeded()
        let next = backoff.failed()
        XCTAssertEqual(next.delay, 10)
        XCTAssertTrue(next.log)
    }
}
