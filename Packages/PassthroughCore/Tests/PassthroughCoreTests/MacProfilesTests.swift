import XCTest
@testable import PassthroughCore

final class MacProfilesTests: XCTestCase {
    private func info(_ id: String, running: Bool = true, waiting: String? = nil, title: String? = nil) -> ShellSessionInfo {
        ShellSessionInfo(id: id, title: title ?? id, startedAt: 0, lastOutputAt: 0, running: running, waiting: waiting)
    }

    func testTabMemoryRoundTripAndEmptyRemoves() throws {
        var memory = MacTabMemory()
        let tabs = MacTabs(openTabs: ["a", "b"], active: "b")
        memory.save(tabs, for: "m1")
        XCTAssertEqual(memory.tabs(for: "m1"), tabs)
        XCTAssertEqual(memory.tabs(for: "nope"), MacTabs(openTabs: [], active: nil))
        let decoded = try JSONDecoder().decode(MacTabMemory.self, from: JSONEncoder().encode(memory))
        XCTAssertEqual(decoded, memory)
        memory.save(MacTabs(openTabs: [], active: nil), for: "m1")
        XCTAssertNil(memory.byMac["m1"])
    }

    func testTabMemoryKeepOnly() {
        var memory = MacTabMemory()
        memory.save(MacTabs(openTabs: ["a"], active: "a"), for: "m1")
        memory.save(MacTabs(openTabs: ["b"], active: nil), for: "m2")
        memory.keepOnly(["m2"])
        XCTAssertEqual(Set(memory.byMac.keys), ["m2"])
        memory.forget("m2")
        XCTAssertTrue(memory.byMac.isEmpty)
    }

    func testHiddenPrunedWhenNoLongerListed() {
        var hidden = ShellHiddenSessions()
        hidden.hide("s1", on: "m1")
        hidden.hide("s2", on: "m1")
        hidden.apply(listed: ["s2", "s3"], on: "m1")
        XCTAssertEqual(hidden.byMac["m1"], ["s2"])
        XCTAssertEqual(hidden.visible([info("s2"), info("s3")], on: "m1").map(\.id), ["s3"])
        hidden.apply(listed: [], on: "m1")
        XCTAssertNil(hidden.byMac["m1"])
        hidden.hide("s9", on: "m2")
        hidden.forget("m2")
        XCTAssertTrue(hidden.byMac.isEmpty)
        hidden.hide("s1", on: "m1")
        hidden.hide("s2", on: "m2")
        hidden.keepOnly(["m1"])
        XCTAssertEqual(Set(hidden.byMac.keys), ["m1"])
    }

    func testOnlyFinishedSessionsCanBeRemoved() {
        let hidden = ShellHiddenSessions()
        let list = [info("run"), info("done", running: false)]
        var ended = ShellEndedSessions()
        XCTAssertTrue(hidden.canRemove("done", ended: ended, sessions: list))
        XCTAssertFalse(hidden.canRemove("run", ended: ended, sessions: list))
        XCTAssertFalse(hidden.canRemove("unknown", ended: ended, sessions: list))
        ended.ended("gone", exitStatus: 0)
        XCTAssertTrue(hidden.canRemove("gone", ended: ended, sessions: list))
    }

    func testSelectionKeepsPairedMacWithoutShell() {
        let paired = ["a", "net", "b"]
        let withShell = ["a", "b"]
        XCTAssertEqual(MacProfiles.selection(current: "net", lastUsed: "a", paired: paired, withShell: withShell), "net")
        // Unpaired current falls back to last used (even internet-only), then the first with a shell.
        XCTAssertEqual(MacProfiles.selection(current: "gone", lastUsed: "net", paired: paired, withShell: withShell), "net")
        XCTAssertEqual(MacProfiles.selection(current: "gone", lastUsed: "also-gone", paired: ["net", "b"], withShell: withShell), "b")
        XCTAssertEqual(MacProfiles.selection(current: nil, lastUsed: nil, paired: ["net"], withShell: []), "net")
        XCTAssertNil(MacProfiles.selection(current: "gone", lastUsed: nil, paired: [], withShell: []))
    }

    func testKeyFactsPerMac() {
        let facts = ShellKeyFacts(granting: ["locked", "missing"], locked: ["locked"])
        // A Mac that granted the shell but whose key can't be read: plug in to renew.
        XCTAssertTrue(facts.keyUnavailable(for: "locked"))
        XCTAssertTrue(facts.keyUnavailable(for: "missing"))
        // A Mac that never granted the shell: internet only.
        XCTAssertFalse(facts.keyUnavailable(for: "internetOnly"))
        // Nothing selected: any grant without a key is worth recovering.
        XCTAssertTrue(facts.keyUnavailable(for: nil))
        XCTAssertFalse(ShellKeyFacts().keyUnavailable(for: nil))
        XCTAssertFalse(ShellKeyFacts().keyUnavailable(for: "a"))
    }

    func testStatusPrecedence() {
        let asking = info("a", waiting: "Edit?", title: "claude")
        let plain = info("b")
        let when = Date(timeIntervalSince1970: 100)
        XCTAssertEqual(MacProfiles.status(sessions: [plain, asking], reachable: true, lastHeard: when, hasShell: true),
                       .asking(title: "claude", question: "Edit?"))
        XCTAssertEqual(MacProfiles.status(sessions: [asking], reachable: true, lastHeard: when, hasShell: false), .noShell)
        XCTAssertEqual(MacProfiles.status(sessions: [plain, info("c", running: false)], reachable: true, lastHeard: nil, hasShell: true),
                       .connected(shells: 1))
        XCTAssertEqual(MacProfiles.status(sessions: nil, reachable: true, lastHeard: nil, hasShell: true), .connected(shells: 0))
        XCTAssertEqual(MacProfiles.status(sessions: nil, reachable: false, lastHeard: when, hasShell: true), .lastHeard(when))
        XCTAssertEqual(MacProfiles.status(sessions: nil, reachable: false, lastHeard: nil, hasShell: true), .connecting)
    }

    func testStatusText() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(MacProfiles.statusText(.connected(shells: 0), now: now), "Connected")
        XCTAssertEqual(MacProfiles.statusText(.connected(shells: 1), now: now), "Connected · 1 shell open")
        XCTAssertEqual(MacProfiles.statusText(.connected(shells: 3), now: now), "Connected · 3 shells open")
        XCTAssertEqual(MacProfiles.statusText(.asking(title: "claude", question: "Edit?"), now: now), "claude is asking a question")
        XCTAssertTrue(MacProfiles.statusText(.lastHeard(now.addingTimeInterval(-7200)), now: now).hasPrefix("Last heard "))
        XCTAssertEqual(MacProfiles.statusText(.noShell, now: now), "Paired, no Remote shell")
        XCTAssertEqual(MacProfiles.statusText(.connecting, now: now), "Connecting…")
    }

    func testInitial() {
        XCTAssertEqual(MacProfiles.initial("Work MacBook"), "W")
        XCTAssertEqual(MacProfiles.initial("  mini"), "M")
        XCTAssertEqual(MacProfiles.initial(""), "?")
        XCTAssertEqual(MacProfiles.initial("   "), "?")
    }

    func testInitialIsTheFirstGraphemeUppercased() {
        XCTAssertEqual(MacProfiles.initial("\u{E9}t\u{E9} mac"), "\u{C9}")
        XCTAssertEqual(MacProfiles.initial("e\u{301}tude"), "E\u{301}")
        XCTAssertEqual(MacProfiles.initial("\u{1F469}\u{200D}\u{1F4BB} Studio"), "\u{1F469}\u{200D}\u{1F4BB}")
    }

    /// Hard-coded: the Kotlin port asserts the same numbers.
    func testColorIndexVectors() {
        XCTAssertEqual(MacProfiles.colorIndex(macID: "mac-A", paletteCount: 6), 4)
        XCTAssertEqual(MacProfiles.colorIndex(macID: "mac-B", paletteCount: 6), 5)
        XCTAssertEqual(MacProfiles.colorIndex(macID: "0F3C9E2A-1111-4222-8333-444455556666", paletteCount: 6), 1)
    }

    func testReopen() {
        XCTAssertEqual(MacProfiles.reopen(lastUsed: "b", available: ["a", "b"]), "b")
        XCTAssertEqual(MacProfiles.reopen(lastUsed: "gone", available: ["a", "b"]), "a")
        XCTAssertEqual(MacProfiles.reopen(lastUsed: nil, available: ["a", "b"]), "a")
        XCTAssertNil(MacProfiles.reopen(lastUsed: "a", available: []))
    }

    func testWatched() {
        let candidates = ["c1", "c2", "c3", "c4", "c5", "c6"]
        let recency = ["c3": 30.0, "c2": 20.0, "c5": 15.0, "c4": 10.0]
        XCTAssertEqual(MacProfiles.watched(candidates: candidates, selected: "c1", recency: recency, pinned: ["c6"]),
                       ["c6", "c3", "c2", "c5", "c4"])
        XCTAssertEqual(MacProfiles.watched(candidates: candidates, selected: "c1", recency: recency, pinned: ["c6"], limit: 2),
                       ["c6", "c3", "c2"])
        // Selected never appears, even pinned; ties keep candidate order.
        XCTAssertEqual(MacProfiles.watched(candidates: candidates, selected: "c6", recency: [:], pinned: ["c6"], limit: 2),
                       ["c1", "c2"])
    }

    func testWatchedIgnoresPinnedNotInCandidates() {
        XCTAssertEqual(MacProfiles.watched(candidates: ["c1", "c2", "c3"], selected: "c1", recency: ["c3": 2, "c2": 1], pinned: ["gone"]),
                       ["c3", "c2"])
    }
    func testRecencyTakesTheLaterOfHeardAndSelected() {
        XCTAssertEqual(MacProfiles.recency(lastHeard: ["a": 10, "b": 50], lastSelected: ["a": 40, "c": 5]),
                       ["a": 40, "b": 50, "c": 5])
    }

    private func credential(_ id: String, key: UInt8 = 1, addresses: [String] = ["10.0.0.1"]) -> ShellCredential {
        ShellCredential(macID: id, macName: id, certSHA256: "cert", shellKey: Data([key]), phoneID: "phone", port: 7, addresses: addresses)
    }

    func testWatchChanges() {
        let a = credential("a"), b = credential("b"), c = credential("c")
        // Nothing running: dial everything wanted, in order.
        var changes = MacProfiles.watchChanges(running: [:], wanted: [b, a])
        XCTAssertEqual(changes.stop, [])
        XCTAssertEqual(changes.start.map(\.macID), ["b", "a"])
        // Same set: nothing to do.
        changes = MacProfiles.watchChanges(running: ["a": a, "b": b], wanted: [a, b])
        XCTAssertEqual(changes.stop, [])
        XCTAssertEqual(changes.start, [])
        // b no longer watched, c new.
        changes = MacProfiles.watchChanges(running: ["a": a, "b": b], wanted: [a, c])
        XCTAssertEqual(changes.stop, ["b"])
        XCTAssertEqual(changes.start.map(\.macID), ["c"])
        // a's key or addresses changed: redial it.
        let newKey = credential("a", key: 2), moved = credential("a", addresses: ["10.0.0.2"])
        changes = MacProfiles.watchChanges(running: ["a": a], wanted: [newKey])
        XCTAssertEqual(changes.stop, ["a"])
        XCTAssertEqual(changes.start, [newKey])
        changes = MacProfiles.watchChanges(running: ["a": a], wanted: [moved])
        XCTAssertEqual(changes.stop, ["a"])
        XCTAssertEqual(changes.start, [moved])
        // Nothing wanted: stop all.
        changes = MacProfiles.watchChanges(running: ["a": a, "b": b], wanted: [])
        XCTAssertEqual(changes.stop, ["a", "b"])
        XCTAssertEqual(changes.start, [])
    }

    func testAdoptedMacPrefersUniqueNameMatch() {
        let paired = [(id: "a", name: "Studio"), (id: "b", name: "Laptop")]
        XCTAssertEqual(MacProfiles.adoptedMac(activityMacName: "Laptop", paired: paired, selected: "a"), "b")
    }

    func testAdoptedMacDuplicateNamesFallBackToSelected() {
        let paired = [(id: "a", name: "Mac"), (id: "b", name: "Mac")]
        XCTAssertEqual(MacProfiles.adoptedMac(activityMacName: "Mac", paired: paired, selected: "b"), "b")
    }

    func testAdoptedMacNoMatchFallsBackToSelected() {
        let paired = [(id: "a", name: "Studio")]
        XCTAssertEqual(MacProfiles.adoptedMac(activityMacName: "Gone", paired: paired, selected: "a"), "a")
        XCTAssertNil(MacProfiles.adoptedMac(activityMacName: "Gone", paired: paired, selected: nil))
    }
}
