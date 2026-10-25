import XCTest
import PassthroughCore
@testable import ShellHost

final class MacEventLogTests: XCTestCase {
    private let clock = Locked(Date(timeIntervalSince1970: 1_800_000_000))
    private func advance(_ seconds: TimeInterval) { clock.set(clock.get() + seconds) }
    private func log(file: URL? = nil) -> MacEventLog {
        let clock = self.clock
        return MacEventLog(file: file, now: { clock.get() }, saveDelay: 0)
    }

    func testEventsSinceAreOldestFirst() {
        let log = log()
        log.record("awake", "Keep awake on")
        advance(60)
        let since = clock.get().timeIntervalSince1970
        log.record("shell", "npm run build finished", detail: "exit 0 · 34 min", session: "s1")
        advance(60)
        log.record("vpn", "VPN dropped", warning: true)
        XCTAssertEqual(log.since(0).events.map(\.title), ["Keep awake on", "npm run build finished", "VPN dropped"])
        XCTAssertEqual(log.since(since).events.map(\.kind), ["shell", "vpn"])
        XCTAssertEqual(log.since(since).events.last?.warning, true)
        XCTAssertNil(log.since(since).events.first?.warning, "absent rather than false")
    }

    func testOlderThanAWeekIsDropped() {
        let log = log()
        log.record("awake", "old")
        advance(MacEvent.kept + 1)
        log.record("awake", "new")
        XCTAssertEqual(log.since(0).events.map(\.title), ["new"])
    }

    /// One sample per interval, but plugging in or unplugging always counts; the line starts just before `since`.
    func testBatterySamples() {
        let log = log()
        log.sample(level: 0.64, charging: false)
        advance(60)
        log.sample(level: 0.63, charging: false)        // too soon
        advance(60)
        log.sample(level: 0.62, charging: true)         // plugged in
        advance(BatterySample.interval)
        let since = clock.get().timeIntervalSince1970
        log.sample(level: 0.70, charging: true)
        XCTAssertEqual(log.since(0).battery.map(\.level), [0.64, 0.62, 0.70])
        XCTAssertEqual(log.since(since).battery.map(\.level), [0.62, 0.70], "the sample before `since` starts the line")
        XCTAssertEqual(log.since(0).battery.map(\.charging), [nil, true, true])
    }

    func testSavedAndReadBack() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("MacEventLogTests-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: file) }
        let first = log(file: file)
        first.record("sleep", "Mac slept")
        first.sample(level: 0.5, charging: false)
        first.flush()
        let second = log(file: file)
        XCTAssertEqual(second.since(0).events.map(\.title), ["Mac slept"])
        XCTAssertEqual(second.since(0).battery.map(\.level), [0.5])
    }
}
