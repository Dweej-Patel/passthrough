#if os(macOS)
import Foundation
import Network
import XCTest
import PassthroughCore
import PhoneTransport
import ScreenClient
import TestSupport
@testable import ShellHost

/// The remote shell end to end over loopback: TLS 1.3 pinned to a test
/// identity, the shell-key challenge, and a real `/bin/sh` behind it.
@available(macOS 15, *)
final class ShellListenerTests: XCTestCase {
    private var identity: MacIdentity!
    private var directory: URL!
    private var store: TranscriptStore!
    private var manager: ShellSessionManager!
    private let key = WirelessLink.randomBytes(32)

    override func setUpWithError() throws {
        // The openssl/PKCS#12 step very rarely fails on a busy machine; retry.
        identity = try (try? makeTestIdentity()) ?? (try? makeTestIdentity()) ?? makeTestIdentity()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShellListenerTests-\(UUID().uuidString)", isDirectory: true)
        store = try TranscriptStore(directory: directory)
        manager = ShellSessionManager(
            transcripts: store,
            command: { ("/bin/sh", []) },
            environment: { ["PATH": "/usr/bin:/bin", "TERM": "xterm-256color", "PS1": "$ "] },
            directory: URL(fileURLWithPath: "/tmp"))
    }

    override func tearDown() {
        manager.closeAll()
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: Helpers

    private func startListener(peerAllowed: @escaping @Sendable (String) -> Bool = ShellAddressPolicy.isAllowed,
                               arrivalAllowed: @escaping @Sendable (String, String?) -> Bool = ShellListener.defaultArrivalAllowed,
                               localAddress: (@Sendable (NWPath?) -> String?)? = nil,
                               events: Locked<[String]>? = nil, keys: Locked<[String: Data]>? = nil) -> ShellListener {
        let keys = keys ?? Locked(["phone-1": key])
        let listener = ShellListener(identity: identity, port: 0, advertise: false, manager: manager, transcripts: store,
                                     shellKeys: { keys.get()[$0].map { [$0] } ?? [] },
                                     phoneLabel: { $0 == "phone-1" ? "Test iPhone" : "?" },
                                     peerAllowed: peerAllowed, arrivalAllowed: arrivalAllowed)
        if let localAddress { listener.localAddress = localAddress }
        if let events { listener.onSessionEvent = { events.set(events.get() + [$0]) } }
        let listening = expectation(description: "listening")
        try! listener.start { _ in listening.fulfill() }
        wait(for: [listening], timeout: 5)
        addTeardownBlock { listener.stop() }
        return listener
    }

    /// Collects a client's events and fulfils expectations on them.
    private final class Probe: @unchecked Sendable {
        /// Recursive: a condition may read the probe's own accessors.
        private let lock = NSRecursiveLock()
        private var _events: [ShellClient.Event] = []
        private var waiters: [(([ShellClient.Event]) -> Bool, XCTestExpectation)] = []

        var events: Locked<[ShellClient.Event]> { Locked(snapshot()) }

        private func snapshot() -> [ShellClient.Event] { lock.lock(); defer { lock.unlock() }; return _events }

        /// Appending the event and fulfilling the waiters it satisfies is one critical section,
        /// as is `expect`'s check-then-register: no event can land between the halves.
        func record(_ event: ShellClient.Event) {
            lock.lock(); defer { lock.unlock() }
            _events.append(event)
            let all = _events
            waiters = waiters.filter { condition, expectation in
                guard condition(all) else { return true }
                expectation.fulfill()
                return false
            }
        }

        func expect(_ test: XCTestCase, _ description: String, _ condition: @escaping ([ShellClient.Event]) -> Bool) -> XCTestExpectation {
            let e = test.expectation(description: description)
            lock.lock(); defer { lock.unlock() }
            if condition(_events) { e.fulfill() } else { waiters.append((condition, e)) }
            return e
        }

        func output(_ session: String) -> String {
            String(decoding: events.get().reduce(Data()) { acc, e in
                if case .output(let s, let d) = e, s == session { return acc + d }
                return acc
            }, as: UTF8.self)
        }
        var opened: String? {
            for case .opened(let id) in events.get() { return id }
            return nil
        }
        var isReady: Bool { events.get().contains { if case .ready = $0 { return true } else { return false } } }
        var failures: [ShellError] { events.get().compactMap { if case .failed(let e, _) = $0 { return e } else { return nil } } }
        var disconnected: Bool { events.get().contains { if case .disconnected = $0 { return true } else { return false } } }
    }

    private func client(_ listener: ShellListener, phoneID: String = "phone-1", key: Data? = nil,
                        pin: String? = nil) -> (ShellClient, Probe) {
        let credential = ShellCredential(macID: "mac", macName: "Test Mac", certSHA256: pin ?? identity.fingerprint,
                                         shellKey: key ?? self.key, phoneID: phoneID, port: listener.port!, addresses: [])
        let probe = Probe()
        let client = ShellClient(credential: credential, queue: DispatchQueue(label: "probe")) { probe.record($0) }
        client.connect(discovered: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: listener.port!)!))
        addTeardownBlock { client.disconnect() }
        return (client, probe)
    }

    private func readyClient(_ listener: ShellListener, phoneID: String = "phone-1", key: Data? = nil) -> (ShellClient, Probe) {
        let (c, probe) = client(listener, phoneID: phoneID, key: key)
        wait(for: [probe.expect(self, "ready") { $0.contains { if case .ready = $0 { return true } else { return false } } }], timeout: 5)
        return (c, probe)
    }

    private func openSession(_ c: ShellClient, _ probe: Probe) -> String {
        c.open(cols: 80, rows: 24)
        wait(for: [probe.expect(self, "opened") { _ in probe.opened != nil }], timeout: 5)
        return probe.opened!
    }

    // MARK: Refusals

    func testAListenerOnATakenPortReportsFailure() throws {
        let first = startListener()
        let port = try XCTUnwrap(first.port)
        let second = ShellListener(identity: identity, port: port, advertise: false, manager: manager, transcripts: store,
                                   shellKeys: { _ in [] }, phoneLabel: { _ in "?" })
        let failed = expectation(description: "failed")
        second.onFailure = { _ in failed.fulfill() }
        try second.start()
        addTeardownBlock { second.stop() }
        wait(for: [failed], timeout: 5)
    }

    func testAStoppedListenersPortCanBeBoundAgainAtOnce() throws {
        let first = startListener()
        let port = try XCTUnwrap(first.port)
        let (_, probe) = readyClient(first)
        let stopped = expectation(description: "stopped")
        first.stop { stopped.fulfill() }
        wait(for: [stopped, probe.expect(self, "disconnected") { _ in probe.disconnected }], timeout: 5)

        let second = ShellListener(identity: identity, port: port, advertise: false, manager: manager, transcripts: store,
                                   shellKeys: { [key] in $0 == "phone-1" ? [key] : [] }, phoneLabel: { _ in "Test iPhone" })
        second.onFailure = { error in XCTFail("could not bind again: \(error)") }
        let listening = expectation(description: "listening again")
        try second.start { _ in listening.fulfill() }
        addTeardownBlock { second.stop() }
        wait(for: [listening], timeout: 5)
        XCTAssertEqual(second.port, port)
        _ = readyClient(second)
    }

    func testStopCompletesForAListenerThatNeverStarted() {
        let listener = ShellListener(identity: identity, port: 0, advertise: false, manager: manager, transcripts: store,
                                     shellKeys: { _ in [] }, phoneLabel: { _ in "?" })
        let stopped = expectation(description: "stopped")
        listener.stop { stopped.fulfill() }
        wait(for: [stopped], timeout: 2)
    }

    func testWrongKeyIsRefused() {
        let listener = startListener()
        let (_, probe) = client(listener, key: WirelessLink.randomBytes(32))
        wait(for: [probe.expect(self, "disconnected") { _ in probe.disconnected }], timeout: 8)
        XCTAssertFalse(probe.isReady)
        XCTAssertEqual(probe.failures, [.notAuthorized])
    }

    func testUnknownPhoneIsRefused() {
        let listener = startListener()
        let (_, probe) = client(listener, phoneID: "stranger")
        wait(for: [probe.expect(self, "disconnected") { _ in probe.disconnected }], timeout: 8)
        XCTAssertFalse(probe.isReady)
        XCTAssertEqual(probe.failures, [.notAuthorized])
    }

    func testDisallowedPeerIsClosedBeforeChallenge() {
        let asked = Locked<[String]>([])
        let listener = startListener(peerAllowed: { asked.set(asked.get() + [$0]); return false })
        let (_, probe) = client(listener)
        wait(for: [probe.expect(self, "disconnected") { _ in probe.disconnected }], timeout: 8)
        XCTAssertFalse(probe.isReady)
        XCTAssertTrue(probe.failures.isEmpty, "no challenge, so no protocol error either")
        XCTAssertEqual(Set(asked.get()), ["127.0.0.1"], "IPv4 peers are checked as plain IPv4")
    }

    /// A connection that arrived where its peer may not (an overlay source on
    /// a LAN address) is closed before TLS, as one from a disallowed peer.
    func testAPeerArrivingOnTheWrongAddressIsClosedBeforeChallenge() {
        let asked = Locked<[String?]>([])
        let listener = startListener(arrivalAllowed: { _, local in asked.set(asked.get() + [local]); return false })
        let (_, probe) = client(listener)
        wait(for: [probe.expect(self, "disconnected") { _ in probe.disconnected }], timeout: 8)
        XCTAssertFalse(probe.isReady)
        XCTAssertTrue(probe.failures.isEmpty, "no challenge")
        XCTAssertEqual(asked.get(), ["127.0.0.1"], "decided at accept, on the address it arrived on")
    }

    /// Where the accepted connection does not know yet which address it
    /// arrived on (and the policy needs it), the listener waits for its path
    /// and decides then; a peer allowed there goes on as usual.
    func testAnArrivalUnknownAtAcceptIsCheckedOnceTheConnectionKnowsIt() {
        let calls = Locked(0)
        let asked = Locked<[String?]>([])
        let listener = startListener(
            arrivalAllowed: { _, local in asked.set(asked.get() + [local]); return local == "127.0.0.1" },
            localAddress: { path in
                calls.set(calls.get() + 1)
                return calls.get() == 1 ? nil : path?.localEndpoint.map(PeerAddress.host(of:))
            })
        _ = readyClient(listener)
        XCTAssertEqual(asked.get(), [nil, "127.0.0.1"])
    }

    /// An arrival that is still unknown once the connection is up is refused
    /// before the handshake reads or sends anything, and its slot is freed.
    func testAnArrivalNeverKnownIsRefused() {
        let asked = Locked<[String?]>([])
        let listener = startListener(arrivalAllowed: { _, local in asked.set(asked.get() + [local]); return local != nil },
                                     localAddress: { _ in nil })
        let (_, probe) = client(listener)
        wait(for: [probe.expect(self, "disconnected") { _ in probe.disconnected }], timeout: 8)
        XCTAssertFalse(probe.isReady)
        XCTAssertTrue(probe.failures.isEmpty, "no challenge")
        XCTAssertEqual(asked.get(), [nil, nil], "asked at accept, then once the connection was up")
        XCTAssertEqual(listener.queue.sync { listener.gate.pendingHandshakes }, 0)
    }

    /// Revoking a phone cuts its live connection at once and ends the
    /// sessions it opened; another phone, and the sessions that phone opened
    /// (even one the revoked phone was attached to), carry on, and the
    /// revoked phone cannot return.
    func testDisconnectPhoneCutsOnlyThatPhone() {
        let otherKey = WirelessLink.randomBytes(32)
        let keys = Locked(["phone-1": key, "phone-2": otherKey])
        let listener = startListener(keys: keys)
        let (a, aProbe) = readyClient(listener)
        let (b, bProbe) = readyClient(listener, phoneID: "phone-2", key: otherKey)
        let mine = openSession(a, aProbe)
        let theirs = openSession(b, bProbe)
        a.attach(theirs, cols: 80, rows: 24)
        wait(for: [aProbe.expect(self, "A attached to B's session") { events in
            events.contains { if case .attached(let id) = $0 { return id == theirs } else { return false } }
        }], timeout: 5)

        keys.set(["phone-2": otherKey])
        listener.disconnect(phoneID: "phone-1")
        wait(for: [aProbe.expect(self, "A disconnected") { _ in aProbe.disconnected }], timeout: 5)

        let deadline = Date().addingTimeInterval(5)
        while manager.sessions.contains(where: { $0.id == mine && $0.running }), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        XCTAssertFalse(manager.sessions.contains { $0.id == mine && $0.running }, "the revoked phone's session ended")
        b.list()
        wait(for: [bProbe.expect(self, "B still served") { events in
            events.contains { if case .sessions(let list) = $0 { return list.contains { $0.id == theirs && $0.running } } else { return false } }
        }], timeout: 5)
        XCTAssertFalse(bProbe.disconnected)

        let (_, again) = client(listener)
        wait(for: [again.expect(self, "revoked phone refused") { _ in again.disconnected }], timeout: 8)
        XCTAssertFalse(again.isReady)
        XCTAssertEqual(again.failures, [.notAuthorized])
    }

    /// Plugging a phone in again re-grants it; until the phone uses the new
    /// key its old one still works, and once it has, the old one no longer does.
    func testRegrantedPhoneKeepsItsOldKeyUntilTheNewOneIsUsed() {
        let access = ShellAccessStore(secrets: InMemorySecrets())
        let old = WirelessLink.randomBytes(32), new = WirelessLink.randomBytes(32)
        access.record(ShellPhone(phoneID: "phone-1", label: "Test iPhone", pairingSlot: "s", key: old, grantedAt: Date()))
        access.record(ShellPhone(phoneID: "phone-1", label: "Test iPhone", pairingSlot: "s", key: new, grantedAt: Date()))
        let listener = ShellListener(identity: identity, port: 0, advertise: false, manager: manager, transcripts: store,
                                     shellKeys: { access.candidateKeys(forPhone: $0) },
                                     keyConfirmed: { access.confirmCurrentKey(phoneID: $0, proven: $1) },
                                     phoneLabel: { _ in "Test iPhone" })
        let listening = expectation(description: "listening")
        try! listener.start { _ in listening.fulfill() }
        wait(for: [listening], timeout: 5)
        addTeardownBlock { listener.stop() }

        let (oldClient, _) = readyClient(listener, key: old)
        oldClient.disconnect()
        _ = readyClient(listener, key: new)
        waitUntil("previous key dropped") { access.phones.first?.previousKey == nil }
        let (_, refused) = client(listener, key: old)
        wait(for: [refused.expect(self, "old key refused") { _ in refused.disconnected }], timeout: 8)
        XCTAssertFalse(refused.isReady)
        XCTAssertEqual(refused.failures, [.notAuthorized])

        access.record(ShellPhone(phoneID: "phone-1", label: "Test iPhone", pairingSlot: "s", key: old, grantedAt: Date()))
        access.revoke(phoneID: "phone-1")
        for key in [old, new] {
            let (_, probe) = client(listener, key: key)
            wait(for: [probe.expect(self, "revoked") { _ in probe.disconnected }], timeout: 8)
            XCTAssertFalse(probe.isReady)
        }
    }

    /// A stored key too short to be one of ours never authenticates.
    func testShortStoredKeyIsRefused() {
        let short = Data(repeating: 9, count: 16)
        let listener = startListener(keys: Locked(["phone-1": short]))
        let (_, probe) = client(listener, key: short)
        wait(for: [probe.expect(self, "refused") { _ in probe.disconnected }], timeout: 8)
        XCTAssertFalse(probe.isReady)
    }

    // MARK: Sessions

    func testOpenInputOutput() {
        let events = Locked<[String]>([])
        let listener = startListener(events: events)
        let (c, probe) = readyClient(listener)
        // The list may arrive in a later read than `ready`.
        wait(for: [probe.expect(self, "ready is followed by the session list") {
            $0.contains { if case .sessions = $0 { return true } else { return false } }
        }], timeout: 5)
        let id = openSession(c, probe)
        c.attach(id, cols: 80, rows: 24)
        c.input(Data("echo over-tls-$((6*7))\n".utf8))
        wait(for: [probe.expect(self, "output") { _ in probe.output(id).contains("over-tls-42\r\n") }], timeout: 10)
        XCTAssertTrue(events.get().contains("Test iPhone opened a session"))
        XCTAssertFalse(events.get().joined().contains("over-tls"), "events never carry terminal bytes")
        c.close(id)
        wait(for: [probe.expect(self, "ended") { $0.contains { if case .ended(id, _) = $0 { return true } else { return false } } }], timeout: 10)
    }

    func testReattachReplaysOverTheWire() {
        let listener = startListener()
        let (first, firstProbe) = readyClient(listener)
        let id = openSession(first, firstProbe)
        first.input(Data("echo replay-$((6*7))\n".utf8))
        wait(for: [firstProbe.expect(self, "output") { _ in firstProbe.output(id).contains("replay-42\r\n") }], timeout: 10)
        first.disconnect()

        let (second, secondProbe) = readyClient(listener)
        second.list()
        wait(for: [secondProbe.expect(self, "listed") { events in
            events.contains { if case .sessions(let list) = $0 { return list.contains { $0.id == id } } else { return false } }
        }], timeout: 5)
        second.attach(id, cols: 100, rows: 30)
        wait(for: [secondProbe.expect(self, "replay") { _ in secondProbe.output(id).contains("replay-42\r\n") }], timeout: 10)
    }

    func testAttachedFollowsReplayAndPrecedesLiveOutput() throws {
        let listener = startListener()
        let (first, firstProbe) = readyClient(listener)
        let id = openSession(first, firstProbe)
        first.input(Data("echo replay-$((6*7))\n".utf8))
        wait(for: [firstProbe.expect(self, "output") { _ in firstProbe.output(id).contains("replay-42\r\n") }], timeout: 10)
        first.disconnect()

        let (second, probe) = readyClient(listener)
        second.attach(id, cols: 80, rows: 24)
        wait(for: [probe.expect(self, "attached") { $0.contains { if case .attached(id) = $0 { return true } else { return false } } }],
             timeout: 10)
        second.input(Data("echo live-$((6*7))\n".utf8))
        wait(for: [probe.expect(self, "live") { _ in probe.output(id).contains("live-42\r\n") }], timeout: 10)

        let events = probe.events.get()
        let marker = try XCTUnwrap(events.firstIndex { if case .attached(id) = $0 { return true } else { return false } })
        func text(_ slice: ArraySlice<ShellClient.Event>) -> String {
            String(decoding: slice.reduce(Data()) { acc, e in
                if case .output(id, let d) = e { return acc + d } else { return acc }
            }, as: UTF8.self)
        }
        XCTAssertTrue(text(events[..<marker]).contains("replay-42\r\n"))
        XCTAssertFalse(text(events[..<marker]).contains("live-"))
        XCTAssertTrue(text(events[(marker + 1)...]).contains("live-42\r\n"))
    }

    func testTakeoverOverTheWire() {
        let listener = startListener()
        let (first, firstProbe) = readyClient(listener)
        let id = openSession(first, firstProbe)
        let (second, secondProbe) = readyClient(listener)
        second.attach(id, cols: 80, rows: 24)
        wait(for: [firstProbe.expect(self, "detached") { $0.contains { if case .detached(id) = $0 { return true } else { return false } } }],
             timeout: 5)
        second.input(Data("echo second-$((6*7))\n".utf8))
        wait(for: [secondProbe.expect(self, "output") { _ in secondProbe.output(id).contains("second-42\r\n") }], timeout: 10)
        XCTAssertFalse(firstProbe.output(id).contains("second-42"), "the first client no longer gets output")
    }

    /// X is taken over by Y, then attaches again before the detach meant for
    /// its first attach is delivered: that late detach must not cut X off.
    func testStaleDetachDoesNotDetachAReattachedClient() {
        let listener = startListener()
        let (x, xProbe) = readyClient(listener)
        let id = openSession(x, xProbe)
        wait(for: [xProbe.expect(self, "X attached") { $0.contains { if case .attached(id) = $0 { return true } else { return false } } }],
             timeout: 5)
        let (y, _) = readyClient(listener)

        manager.suspendCallouts()
        var resumed = false
        defer { if !resumed { manager.resumeCallouts() } }
        let first = manager.attachmentGeneration(id)
        y.attach(id, cols: 80, rows: 24)
        waitUntil("Y took over") { self.manager.attachmentGeneration(id) != first }
        let second = manager.attachmentGeneration(id)
        x.attach(id, cols: 80, rows: 24)
        waitUntil("X attached again") { self.manager.attachmentGeneration(id) != second }
        manager.resumeCallouts()
        resumed = true

        wait(for: [xProbe.expect(self, "X re-attached") {
            $0.filter { if case .attached(id) = $0 { return true } else { return false } }.count >= 2
        }], timeout: 5)
        x.input(Data("echo still-$((6*7))\n".utf8))
        wait(for: [xProbe.expect(self, "X keeps receiving") { _ in xProbe.output(id).contains("still-42\r\n") }], timeout: 10)
        XCTAssertFalse(xProbe.events.get().contains { if case .detached(id) = $0 { return true } else { return false } },
                       "the detach for X's first attach was dropped")
    }

    private func waitUntil(_ message: String, timeout: TimeInterval = 5, _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return XCTFail("timed out: \(message)") }
            Thread.sleep(forTimeInterval: 0.01)
        }
    }

    func testHistoryAndTranscript() {
        let listener = startListener()
        let (c, probe) = readyClient(listener)
        let id = openSession(c, probe)
        c.input(Data("echo hist-$((6*7))\nexit\n".utf8))
        wait(for: [probe.expect(self, "ended") { $0.contains { if case .ended(id, _) = $0 { return true } else { return false } } }],
             timeout: 10)
        c.requestHistory()
        wait(for: [probe.expect(self, "history") { events in
            events.contains { if case .history(let list) = $0 { return list.contains { $0.id == id && $0.phoneLabel == "Test iPhone" } } else { return false } }
        }], timeout: 5)
        c.requestTranscript(id)
        wait(for: [probe.expect(self, "transcript done") { events in
            events.contains { if case .transcript(id, _, true) = $0 { return true } else { return false } }
        }], timeout: 5)
        let text = probe.events.get().reduce(Data()) { acc, e in
            if case .transcript(id, let d, _) = e { return acc + d } else { return acc }
        }
        XCTAssertTrue(String(decoding: text, as: UTF8.self).contains("hist-42\r\n"))
        c.requestTranscript("no-such-session")
        wait(for: [probe.expect(self, "unknown transcript") { _ in probe.failures.contains(.noSuchSession) }], timeout: 5)
        // The failure names the session it was about, so a phone can tell
        // an unrelated refusal from one that ends its pending transcript.
        let sessions = probe.events.get().compactMap { e -> String? in
            if case .failed(.noSuchSession, let session) = e { return session } else { return nil }
        }
        XCTAssertEqual(sessions, ["no-such-session"])
    }

    /// Output larger than one chunk arrives in several `output` lines and in full.
    func testLargeOutputIsChunked() {
        let listener = startListener()
        let (c, probe) = readyClient(listener)
        let id = openSession(c, probe)
        c.input(Data("i=0; while [ $i -lt 2000 ]; do echo line-$i-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx; i=$((i+1)); done; echo all-$((6*7))-done\n".utf8))
        wait(for: [probe.expect(self, "all output") { _ in probe.output(id).contains("all-42-done\r\n") }], timeout: 20)
        XCTAssertTrue(probe.output(id).contains("line-1999-"))
        for case .output(_, let d) in probe.events.get() { XCTAssertLessThanOrEqual(d.count, RemoteShell.outputChunk) }
    }

    /// After proof, malformed or unknown requests are answered, not fatal.
    func testBadRequestsAreAnswered() {
        let listener = startListener()
        let (stream, _) = rawAuthorized(listener)
        let replies = Locked(Data())
        stream.send(Data("not json\n{\"t\":\"frobnicate\"}\n{\"t\":\"attach\",\"session\":\"nope\",\"cols\":80,\"rows\":24}\n{\"t\":\"ping\"}\n".utf8),
                    isComplete: false) { _ in }
        let got = expectation(description: "replies")
        func read() {
            stream.receive(maximumLength: 65536) { data, complete, error in
                if let data { replies.set(replies.get() + data) }
                let lines = replies.get().split(separator: 0x0A).compactMap { try? ShellEnvelope.decode(Data($0)) }
                if lines.contains(where: { $0.t == "pong" }) {
                    let errors = lines.filter { $0.t == "error" }.map(\.reason)
                    XCTAssertEqual(errors, ["bad_request", "bad_request", "no_such_session"])
                    got.fulfill(); return
                }
                if complete || error != nil { return }
                read()
            }
        }
        read()
        wait(for: [got], timeout: 5)
    }

    /// Requests sent right after `open` are answered after it, in order.
    func testRequestsAfterOpenWaitForIt() {
        let listener = startListener()
        let (stream, _) = rawAuthorized(listener)
        let replies = Locked(Data())
        stream.send(Data("{\"t\":\"open\",\"cols\":80,\"rows\":24}\n{\"t\":\"list\"}\n{\"t\":\"ping\"}\n".utf8), isComplete: false) { _ in }
        let got = expectation(description: "replies")
        func read() {
            stream.receive(maximumLength: 65536) { data, complete, error in
                if let data { replies.set(replies.get() + data) }
                let lines = replies.get().split(separator: 0x0A).compactMap { try? ShellEnvelope.decode(Data($0)) }
                if lines.contains(where: { $0.t == "pong" }) {
                    let kinds = lines.map(\.t).filter { ["opened", "sessions", "pong"].contains($0) }
                    XCTAssertEqual(Array(kinds.suffix(3)), ["opened", "sessions", "pong"])
                    let id = lines.first { $0.t == "opened" }?.session
                    XCTAssertNotNil(id)
                    XCTAssertTrue(lines.last { $0.t == "sessions" }?.sessions?.contains { $0.id == id } ?? false,
                                  "the list sent after open has the new session")
                    got.fulfill(); return
                }
                if complete || error != nil { return }
                read()
            }
        }
        read()
        wait(for: [got], timeout: 10)
    }

    /// A shell that is slow to start holds up only the phone that asked for it.
    func testASlowOpenDoesNotHoldUpOtherPhones() {
        manager.closeAll()
        manager = ShellSessionManager(
            transcripts: store,
            command: { Thread.sleep(forTimeInterval: 1.5); return ("/bin/sh", []) },
            environment: { ["PATH": "/usr/bin:/bin", "TERM": "xterm-256color", "PS1": "$ "] },
            directory: URL(fileURLWithPath: "/tmp"))
        let listener = startListener()
        let (a, aProbe) = readyClient(listener)
        let (b, bProbe) = readyClient(listener)
        let listed = { bProbe.events.get().filter { if case .sessions = $0 { return true } else { return false } }.count }
        let before = listed()
        a.open(cols: 80, rows: 24)
        Thread.sleep(forTimeInterval: 0.2)   // the open is under way
        let asked = Date()
        b.list()
        wait(for: [bProbe.expect(self, "B answered") { _ in listed() > before }], timeout: 5)
        XCTAssertLessThan(Date().timeIntervalSince(asked), 0.8, "B was answered while A's shell was starting")
        wait(for: [aProbe.expect(self, "A opened") { _ in aProbe.opened != nil }], timeout: 5)
    }

    /// An authorized connection that sends a line longer than the limit is closed.
    func testOverlongLineAfterProofCloses() {
        let listener = startListener()
        let (stream, _) = rawAuthorized(listener)
        let closed = expectation(description: "closed")
        stream.send(Data(repeating: 0x61, count: RemoteShell.lineLimit + 70_000), isComplete: false) { _ in }
        func drain() {
            stream.receive(maximumLength: 65536) { _, complete, error in
                if complete || error != nil { closed.fulfill() } else { drain() }
            }
        }
        drain()
        wait(for: [closed], timeout: 5)
    }

    /// Dials with TLS, answers the challenge, and reads up to `ready`'s line.
    private func rawAuthorized(_ listener: ShellListener) -> (ConnectionStream, Data) {
        let connection = NWConnection(to: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: listener.port!)!),
                                      using: WirelessLink.pinnedClientParameters(pin: identity.fingerprint, peerToPeer: false))
        let stream = ConnectionStream(connection, queue: .global())
        addTeardownBlock { stream.cancel() }
        let ready = expectation(description: "ready")
        let rest = Locked(Data())
        let key = self.key
        WirelessLink.readLine(stream) { result in
            guard case .success(let (line, _)) = result, let challenge = try? ShellEnvelope.decode(line),
                  let nonce = challenge.nonce.flatMap({ Data(base64Encoded: $0) }) else { return XCTFail("no challenge") }
            var proof = ShellEnvelope(t: ShellEnvelope.proof)
            proof.phoneID = "phone-1"
            proof.mac = RemoteShell.proof(shellKey: key, nonce: nonce).base64EncodedString()
            stream.send(try! proof.encodedLine(), isComplete: false) { _ in }
            WirelessLink.readLine(stream) { result in
                guard case .success(let (line, more)) = result, (try? ShellEnvelope.decode(line))?.t == "ready" else { return XCTFail("not ready") }
                rest.set(more)
                ready.fulfill()
            }
        }
        wait(for: [ready], timeout: 5)
        return (stream, rest.get())
    }

    // MARK: Pre-auth limits (as the wireless listener)

    /// Anyone on the network can connect: one address may hold two
    /// handshakes, and a third from it is refused at once.
    func testOneAddressCannotHoldEveryHandshakeSlot() {
        let port = NWEndpoint.Port(rawValue: startListener().port!)!
        let held = Locked<[NWConnection]>([])
        addTeardownBlock { held.get().forEach { $0.cancel() } }
        func connect(_ closed: XCTestExpectation) {
            let c = NWConnection(host: "127.0.0.1", port: port, using: .tcp)   // never starts TLS
            held.set(held.get() + [c])
            c.stateUpdateHandler = { state in
                guard case .ready = state else { return }
                c.receive(minimumIncompleteLength: 1, maximumLength: 1) { _, _, complete, error in
                    if complete || error != nil { closed.fulfill() }
                }
            }
            c.start(queue: .global())
        }
        let first = expectation(description: "first kept"), second = expectation(description: "second kept")
        first.isInverted = true; second.isInverted = true
        connect(first); connect(second)
        Thread.sleep(forTimeInterval: 0.3)   // both accepted before the third arrives
        let third = expectation(description: "third refused")
        connect(third)
        wait(for: [third], timeout: 3)
        wait(for: [first, second], timeout: 0.5)
    }

    /// Before it has proved anything, a connection may not send more than a
    /// proof's worth: it is closed long before the handshake would time out.
    func testOversizedFirstLineIsRefused() {
        let port = NWEndpoint.Port(rawValue: startListener().port!)!
        let connection = NWConnection(to: .hostPort(host: "127.0.0.1", port: port),
                                      using: WirelessLink.pinnedClientParameters(pin: identity.fingerprint, peerToPeer: false))
        let stream = ConnectionStream(connection, queue: .global())
        addTeardownBlock { stream.cancel() }
        let closed = expectation(description: "closed")
        WirelessLink.readLine(stream) { result in   // the challenge
            guard case .success = result else { return XCTFail("no challenge") }
            stream.send(Data(repeating: 0x61, count: ShellListener.proofLineLimit + 4096), isComplete: false) { _ in }
            func drain() {
                stream.receive(maximumLength: 65536) { _, complete, error in
                    if complete || error != nil { closed.fulfill() } else { drain() }
                }
            }
            drain()
        }
        wait(for: [closed], timeout: WirelessLink.handshakeTimeout / 2)
    }

    // MARK: Client

    /// An address that accepts TCP but never answers TLS (a blackholed route,
    /// say) does not hold up the next one beyond the stagger.
    func testASilentFirstAddressDoesNotDelayAGoodSecondOne() throws {
        let listener = startListener()
        let silent = try NWListener(using: .tcp)
        let held = Locked<[NWConnection]>([])
        silent.newConnectionHandler = { c in held.set(held.get() + [c]); c.start(queue: .global()) }
        let silentReady = expectation(description: "silent listening")
        silent.stateUpdateHandler = { if case .ready = $0 { silentReady.fulfill() } }
        silent.start(queue: .global())
        addTeardownBlock { silent.cancel(); held.get().forEach { $0.cancel() } }
        wait(for: [silentReady], timeout: 5)

        let credential = ShellCredential(macID: "mac", macName: "Test Mac", certSHA256: identity.fingerprint, shellKey: key,
                                         phoneID: "phone-1", port: listener.port!, addresses: ["127.0.0.1"])
        let probe = Probe()
        let c = ShellClient(credential: credential, queue: DispatchQueue(label: "probe")) { probe.record($0) }
        addTeardownBlock { c.disconnect() }
        let started = Date()
        c.connect(discovered: .hostPort(host: "127.0.0.1", port: silent.port!))
        wait(for: [probe.expect(self, "ready") { _ in probe.isReady }], timeout: 3)
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.25 + 1.5,
                          "the good address must not wait for the silent one to time out")
        XCTAssertGreaterThanOrEqual(held.get().count, 1, "the silent address was dialled first")
        c.list()
        wait(for: [probe.expect(self, "served") { $0.filter { if case .sessions = $0 { return true } else { return false } }.count >= 2 }],
             timeout: 5)
        XCTAssertFalse(probe.disconnected)
    }

    /// A ready connection whose path goes dead without closing (the cable
    /// pulled while it used the cable's network) is given up once the Mac
    /// has been silent for `Liveness.silence`, so the phone can dial again.
    func testASilentConnectionIsGivenUp() throws {
        let listener = startListener()
        let proxy = try StallingProxy(to: listener.port!)
        addTeardownBlock { proxy.stop() }
        let liveness = ShellClient.Liveness(interval: 0.2, silence: 0.6, probe: 0.5)
        let (c, probe) = proxiedClient(proxy, listener: listener, liveness: liveness)
        wait(for: [probe.expect(self, "ready") { _ in probe.isReady }], timeout: 5)

        proxy.stall()
        let stalled = Date()
        wait(for: [probe.expect(self, "given up") { _ in probe.disconnected }], timeout: 3)
        XCTAssertLessThan(Date().timeIntervalSince(stalled), liveness.silence + 0.6)
        let error = probe.events.get().compactMap { if case .disconnected(let e) = $0 { return e } else { return nil } }.first
        XCTAssertEqual(error as? ShellClient.ConnectError, .stoppedAnswering)
        _ = c
    }

    /// A quiet connection stays: the client pings and the Mac's pongs keep
    /// it alive well past `Liveness.silence`.
    func testAQuietConnectionThatAnswersPingsStays() throws {
        let listener = startListener()
        let proxy = try StallingProxy(to: listener.port!)
        addTeardownBlock { proxy.stop() }
        let (c, probe) = proxiedClient(proxy, listener: listener, liveness: ShellClient.Liveness(interval: 0.2, silence: 0.6, probe: 0.5))
        wait(for: [probe.expect(self, "ready") { _ in probe.isReady }], timeout: 5)

        let quiet = expectation(description: "quiet")
        quiet.isInverted = true
        wait(for: [quiet], timeout: 2)
        XCTAssertFalse(probe.disconnected)
        XCTAssertGreaterThan(proxy.forwardedToMac.get(), 0, "pings went to the Mac")
        c.list()
        wait(for: [probe.expect(self, "served") { $0.filter { if case .sessions = $0 { return true } else { return false } }.count >= 2 }],
             timeout: 5)
    }

    private func proxiedClient(_ proxy: StallingProxy, listener: ShellListener, liveness: ShellClient.Liveness) -> (ShellClient, Probe) {
        let credential = ShellCredential(macID: "mac", macName: "Test Mac", certSHA256: identity.fingerprint, shellKey: key,
                                         phoneID: "phone-1", port: listener.port!, addresses: [])
        let probe = Probe()
        let client = ShellClient(credential: credential, queue: DispatchQueue(label: "probe"), liveness: liveness) { probe.record($0) }
        addTeardownBlock { client.disconnect() }
        client.connect(discovered: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: proxy.port)!))
        return (client, probe)
    }

    /// Forwards TCP to the listener until `stall()`, then forwards nothing
    /// more either way and closes nothing: a path that died underneath.
    private final class StallingProxy: @unchecked Sendable {
        private let listener: NWListener
        private let queue = DispatchQueue(label: "stalling-proxy")
        private var stalled = false
        private var connections: [NWConnection] = []
        /// Bytes passed from the client to the listener.
        let forwardedToMac = Locked(0)
        var port: UInt16 { listener.port!.rawValue }

        init(to target: UInt16) throws {
            listener = try NWListener(using: .tcp)
            listener.newConnectionHandler = { [unowned self] inbound in
                let upstream = NWConnection(to: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: target)!), using: .tcp)
                connections += [inbound, upstream]
                pump(inbound, to: upstream, counting: forwardedToMac)
                pump(upstream, to: inbound, counting: nil)
                inbound.start(queue: queue)
                upstream.start(queue: queue)
            }
            let ready = DispatchSemaphore(value: 0)
            listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
            listener.start(queue: queue)
            _ = ready.wait(timeout: .now() + 5)
        }

        private func pump(_ from: NWConnection, to: NWConnection, counting: Locked<Int>?) {
            from.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, complete, error in
                guard let self, !self.stalled else { return }
                if let data, !data.isEmpty {
                    counting?.set(counting!.get() + data.count)
                    to.send(content: data, completion: .contentProcessed { _ in })
                }
                if complete || error != nil { return }
                self.pump(from, to: to, counting: counting)
            }
        }

        func stall() { queue.sync { stalled = true } }

        func stop() {
            queue.sync {
                listener.cancel()
                connections.forEach { $0.cancel() }
            }
        }
    }

    // MARK: Screen

    /// Reads from `stream` until `done` holds for everything read so far
    /// (or, with `orEnd`, until the stream ends).
    private func read(_ stream: ConnectionStream, _ description: String, orEnd: Bool = false, timeout: TimeInterval = 5,
                      until done: @escaping @Sendable (Data) -> Bool) -> Data {
        let got = expectation(description: description)
        let buffer = Locked(Data())
        @Sendable func next() {
            stream.receive(maximumLength: 65536) { data, complete, error in
                if let data { buffer.set(buffer.get() + data) }
                if done(buffer.get()) { got.fulfill(); return }
                if complete || error != nil { if orEnd { got.fulfill() }; return }
                next()
            }
        }
        next()
        wait(for: [got], timeout: timeout)
        return buffer.get()
    }

    private static func lines(_ data: Data) -> [ShellEnvelope] {
        data.split(separator: 0x0A).compactMap { try? ShellEnvelope.decode(Data($0)) }
    }

    /// A stand-in for Screen Sharing on loopback: says the RFB banner, then
    /// records what it is sent.
    private final class FakeScreenSharing: @unchecked Sendable {
        let listener: NWListener
        let received = Locked(Data())
        let connection = Locked<NWConnection?>(nil)
        var port: UInt16 { listener.port!.rawValue }

        init(_ test: XCTestCase) throws {
            let params = NWParameters.tcp
            params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
            listener = try NWListener(using: params)
            let ready = test.expectation(description: "fake Screen Sharing listening")
            listener.stateUpdateHandler = { if case .ready = $0 { ready.fulfill() } }
            listener.newConnectionHandler = { [self] connection in
                self.connection.set(connection)
                connection.start(queue: .global())
                connection.send(content: Data("RFB 003.889\n".utf8), completion: .idempotent)
                read(connection)
            }
            listener.start(queue: .global())
            test.wait(for: [ready], timeout: 5)
        }

        private func read(_ connection: NWConnection) {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [self] data, _, complete, error in
                if let data { received.set(received.get() + data) }
                if !complete && error == nil { read(connection) }
            }
        }

        func stop() { connection.get()?.cancel(); listener.cancel() }
    }

    /// A port nothing listens on.
    private func closedPort() throws -> UInt16 {
        let probe = try FakeScreenSharing(self)
        let port = probe.port
        probe.stop()
        return port
    }

    func testScreenNeedsScreenAccess() {
        let listener = startListener()
        let (stream, _) = rawAuthorized(listener)
        stream.send(Data("{\"t\":\"screen\"}\n{\"t\":\"ping\"}\n".utf8), isComplete: false) { _ in }
        let replies = Self.lines(read(stream, "replies") { Self.lines($0).contains { $0.t == "pong" } })
        XCTAssertEqual(replies.filter { $0.t == "error" }.map(\.reason), ["screen_not_allowed"])
        XCTAssertFalse(replies.contains { $0.t == ShellEnvelope.screenReady })
    }

    func testScreenSharingOffIsReportedAndTheConnectionCarriesOn() throws {
        let listener = startListener()
        listener.screenAllowed = { $0 == "phone-1" }
        listener.gate.screenPort.set(try closedPort())
        listener.screenSharingVerified = { true }
        let (stream, _) = rawAuthorized(listener)
        stream.send(Data("{\"t\":\"screen\"}\n{\"t\":\"ping\"}\n".utf8), isComplete: false) { _ in }
        let replies = Self.lines(read(stream, "replies") { Self.lines($0).contains { $0.t == "pong" } })
        XCTAssertEqual(replies.filter { $0.t == "error" }.map(\.reason), ["screen_unavailable"])
    }

    /// A process of the user's can listen on Screen Sharing's port while it
    /// is off, and the phone would send it the Mac password: nothing is
    /// relayed until the check says the port is really Screen Sharing's, and
    /// nothing at all without a check.
    func testScreenIsNotRelayedToAnUnverifiedListener() throws {
        let refuses: @Sendable () async -> Bool = { false }
        let hangs: @Sendable () async -> Bool = { try? await Task.sleep(for: .seconds(30)); return true }
        for check in [refuses, nil, hangs] {
            let fake = try FakeScreenSharing(self)
            addTeardownBlock { fake.stop() }
            let listener = startListener()
            listener.screenAllowed = { _ in true }
            listener.gate.screenPort.set(fake.port)
            listener.screenSharingVerified = check
            let (stream, _) = rawAuthorized(listener)
            stream.send(Data("{\"t\":\"screen\"}\n{\"t\":\"ping\"}\n".utf8), isComplete: false) { _ in }
            let replies = Self.lines(read(stream, "replies", timeout: 10) { Self.lines($0).contains { $0.t == "pong" } })
            XCTAssertEqual(replies.filter { $0.t == "error" }.map(\.reason), ["screen_unavailable"])
            XCTAssertFalse(replies.contains { $0.t == ShellEnvelope.screenReady })
            XCTAssertNil(fake.connection.get(), "the impostor was never dialled")
        }
    }

    /// The check runs before the dial, and once per request.
    func testScreenSharingIsCheckedBeforeEveryRelay() throws {
        let fake = try FakeScreenSharing(self)
        addTeardownBlock { fake.stop() }
        let checks = Locked(0)
        let listener = startListener()
        listener.screenAllowed = { _ in true }
        listener.gate.screenPort.set(fake.port)
        listener.screenSharingVerified = {
            XCTAssertNil(fake.connection.get(), "checked before dialling")
            checks.set(checks.get() + 1)
            return true
        }
        let (stream, _) = rawAuthorized(listener)
        stream.send(try ShellEnvelope(t: ShellEnvelope.screen).encodedLine(), isComplete: false) { _ in }
        _ = read(stream, "screenReady") { $0.firstRange(of: Data("RFB".utf8)) != nil }
        XCTAssertEqual(checks.get(), 1)
    }

    /// After `screenReady` the connection is Screen Sharing's, both ways,
    /// until either end closes; the owner hears who started and stopped.
    func testScreenIsRelayedBothWays() throws {
        let fake = try FakeScreenSharing(self)
        addTeardownBlock { fake.stop() }
        let events = Locked<[String]>([])
        let viewers = Locked<[Bool]>([])
        let listener = startListener(events: events)
        listener.screenAllowed = { _ in true }
        listener.onScreenViewer = { phoneID, label, viewing in
            XCTAssertEqual(phoneID, "phone-1"); XCTAssertEqual(label, "Test iPhone")
            viewers.set(viewers.get() + [viewing])
        }
        listener.gate.screenPort.set(fake.port)
        listener.screenSharingVerified = { true }
        let (stream, _) = rawAuthorized(listener)
        stream.send(try ShellEnvelope(t: ShellEnvelope.screen).encodedLine(), isComplete: false) { _ in }
        let banner = Data("RFB 003.889\n".utf8)
        let got = read(stream, "screenReady and the banner") { data in
            guard let ready = data.firstRange(of: Data("{\"t\":\"screenReady\"}\n".utf8)) else { return false }
            return data[ready.upperBound...].count >= banner.count
        }
        let afterReady = got[got.firstRange(of: Data("{\"t\":\"screenReady\"}\n".utf8))!.upperBound...]
        XCTAssertEqual(Data(afterReady), banner, "nothing between screenReady and Screen Sharing's bytes")
        XCTAssertEqual(viewers.get(), [true])

        stream.send(Data("RFB 003.008\n".utf8), isComplete: false) { _ in }
        waitUntil("Screen Sharing got the phone's bytes") { fake.received.get() == Data("RFB 003.008\n".utf8) }

        // Screen Sharing hangs up: so does the phone's connection.
        fake.connection.get()?.cancel()
        _ = read(stream, "closed", orEnd: true) { _ in false }
        waitUntil("the owner heard the viewer leave") { viewers.get() == [true, false] }
        XCTAssertEqual(events.get().filter { $0.contains("screen") },
                       ["Test iPhone started viewing the screen", "Test iPhone stopped viewing the screen"])
    }

    func testScreenVideoUnavailableIsReportedAndTheConnectionCarriesOn() {
        let listener = startListener()
        listener.screenAllowed = { _ in true }
        listener.screenVideo = { _ in nil }
        let (stream, _) = rawAuthorized(listener)
        stream.send(Data("{\"t\":\"screenVideo\"}\n{\"t\":\"ping\"}\n".utf8), isComplete: false) { _ in }
        let replies = Self.lines(read(stream, "replies") { Self.lines($0).contains { $0.t == "pong" } })
        XCTAssertEqual(replies.filter { $0.t == "error" }.map(\.reason), ["screen_video_unavailable"])
    }

    /// A phone gets two views of the screen at once; a third is refused
    /// with a reason, and a refused or closed view frees its place.
    func testScreenViewsAreCapped() {
        let listener = startListener()
        let views = ScreenViewLimit()
        listener.screenViews = views
        listener.screenAllowed = { _ in true }
        let available = Locked(true)
        let sources = Locked<[FakeVideoSource]>([])
        listener.screenVideo = { _ in
            guard available.get() else { return nil }
            let source = FakeVideoSource()
            sources.set(sources.get() + [source])
            return source
        }

        available.set(false)
        let (shell, _) = rawAuthorized(listener)
        shell.send(Data("{\"t\":\"screenVideo\"}\n{\"t\":\"ping\"}\n".utf8), isComplete: false) { _ in }
        _ = read(shell, "unavailable") { Self.lines($0).contains { $0.t == "pong" } }
        XCTAssertEqual(views.count, 0, "a view the Mac could not make holds no place")
        available.set(true)

        for _ in 0..<2 {
            let (stream, _) = rawAuthorized(listener)
            stream.send(try! ShellEnvelope(t: ShellEnvelope.screenVideo).encodedLine(), isComplete: false) { _ in }
            _ = read(stream, "screenVideoReady") { $0.firstRange(of: Data("{\"t\":\"screenVideoReady\"}\n".utf8)) != nil }
        }
        XCTAssertEqual(views.count, 2)
        shell.send(Data("{\"t\":\"screenVideo\"}\n{\"t\":\"ping\"}\n".utf8), isComplete: false) { _ in }
        let replies = Self.lines(read(shell, "refused") { Self.lines($0).contains { $0.t == "pong" } })
        XCTAssertEqual(replies.filter { $0.t == "error" }.map(\.reason), ["too_many_screens"])

        waitUntil("both sources started") { sources.get().count == 2 && sources.get().allSatisfy { $0.ended.get() != nil } }
        sources.get()[0].ended.get()?()
        waitUntil("the closed view's place is free") { views.count == 1 }
    }

    func testScreenViewLimitCountsInAll() {
        let views = ScreenViewLimit(maxPerPhone: 2, maxTotal: 3)
        XCTAssertTrue(views.take("a")); XCTAssertTrue(views.take("a"))
        XCTAssertFalse(views.take("a"), "two per phone")
        XCTAssertTrue(views.take("b"))
        XCTAssertFalse(views.take("c"), "three in all")
        views.release("a")
        XCTAssertTrue(views.take("c"))
        XCTAssertEqual(RemoteShell.maxScreenViewsPerPhone, 2)
        XCTAssertEqual(RemoteShell.maxScreenViews, 4)
    }

    func testScreenVideoNeedsScreenAccess() {
        let made = Locked(false)
        let listener = startListener()
        listener.screenVideo = { _ in made.set(true); return FakeVideoSource() }
        let (stream, _) = rawAuthorized(listener)
        stream.send(Data("{\"t\":\"screenVideo\"}\n{\"t\":\"ping\"}\n".utf8), isComplete: false) { _ in }
        let replies = Self.lines(read(stream, "replies") { Self.lines($0).contains { $0.t == "pong" } })
        XCTAssertEqual(replies.filter { $0.t == "error" }.map(\.reason), ["screen_not_allowed"])
        XCTAssertFalse(made.get())
    }

    /// After `screenVideoReady` the connection is the source's, both ways;
    /// the source ending closes it, and the owner hears who came and went.
    func testScreenVideoHandsTheConnectionToTheSource() throws {
        let source = FakeVideoSource()
        let viewers = Locked<[Bool]>([])
        let listener = startListener()
        listener.screenAllowed = { _ in true }
        listener.screenVideo = { phoneID in XCTAssertEqual(phoneID, "phone-1"); return source }
        listener.onScreenViewer = { _, _, viewing in viewers.set(viewers.get() + [viewing]) }
        let (stream, _) = rawAuthorized(listener)
        stream.send(try ShellEnvelope(t: ShellEnvelope.screenVideo).encodedLine(), isComplete: false) { _ in }
        _ = read(stream, "screenVideoReady") { $0.firstRange(of: Data("{\"t\":\"screenVideoReady\"}\n".utf8)) != nil }
        waitUntil("the source started") { source.stream.get() != nil }
        XCTAssertEqual(viewers.get(), [true])

        stream.send(Data([1, 2, 3]), isComplete: false) { _ in }
        let received = Locked(Data())
        source.stream.get()?.receive(maximumLength: 100) { data, _, _ in received.set(data ?? Data()) }
        waitUntil("the source reads the phone's bytes") { received.get() == Data([1, 2, 3]) }
        source.stream.get()?.send(Data([9, 9]), isComplete: false) { _ in }
        _ = read(stream, "the source's bytes") { $0.firstRange(of: Data([9, 9])) != nil }

        source.ended.get()?()
        _ = read(stream, "closed", orEnd: true) { _ in false }
        waitUntil("the owner heard the viewer leave") { viewers.get() == [true, false] }
        XCTAssertTrue(source.stopped.get(), "closing the connection stops the source")
    }

    /// Turning screen access off ends a view of the screen at once; the same
    /// phone's shell connection stays.
    func testDisconnectScreenLeavesShellConnections() throws {
        let fake = try FakeScreenSharing(self)
        addTeardownBlock { fake.stop() }
        let listener = startListener()
        listener.screenAllowed = { _ in true }
        listener.gate.screenPort.set(fake.port)
        listener.screenSharingVerified = { true }
        let (shell, _) = rawAuthorized(listener)
        let (screen, _) = rawAuthorized(listener)
        screen.send(try ShellEnvelope(t: ShellEnvelope.screen).encodedLine(), isComplete: false) { _ in }
        _ = read(screen, "screenReady") { $0.firstRange(of: Data("RFB".utf8)) != nil }
        listener.disconnectScreen(phoneID: "phone-1")
        let ended = expectation(description: "screen connection closed")
        @Sendable func drain() {
            screen.receive(maximumLength: 65536) { _, complete, error in
                if complete || error != nil { ended.fulfill() } else { drain() }
            }
        }
        drain()
        wait(for: [ended], timeout: 5)
        shell.send(Data("{\"t\":\"ping\"}\n".utf8), isComplete: false) { _ in }
        _ = read(shell, "pong") { Self.lines($0).contains { $0.t == "pong" } }
    }

    /// The phone's client end to end: it asks, gets the stream handed over,
    /// and reads Screen Sharing's banner from it (some of it may have come
    /// with `screenReady`).
    func testClientHandsOverTheScreenStream() throws {
        let fake = try FakeScreenSharing(self)
        addTeardownBlock { fake.stop() }
        let listener = startListener()
        listener.screenAllowed = { _ in true }
        listener.gate.screenPort.set(fake.port)
        listener.screenSharingVerified = { true }
        let (client, probe) = readyClient(listener)
        client.requestScreen()
        wait(for: [probe.expect(self, "handed over") { $0.contains { if case .screen = $0 { true } else { false } } }], timeout: 5)
        guard case let .screen(stream, initial)? = probe.events.get().last else { return XCTFail("no screen") }
        addTeardownBlock { stream.cancel() }
        let banner = Data("RFB 003.889\n".utf8)
        let got = Locked(initial)
        let done = expectation(description: "banner")
        @Sendable func next() {
            if got.get().count >= banner.count { return done.fulfill() }
            stream.receive(maximumLength: 65536) { data, complete, error in
                if let data { got.set(got.get() + data) }
                if complete || error != nil { return }
                next()
            }
        }
        next()
        wait(for: [done], timeout: 5)
        XCTAssertEqual(got.get(), banner)
        XCTAssertFalse(probe.disconnected, "a hand-over is not a disconnect")
    }

    // MARK: Mac state and control

    private static func state(_ events: [ShellClient.Event]) -> [MacState] {
        events.compactMap { if case .macState(let s) = $0 { s } else { nil } }
    }

    func testMacStateFollowsReadyAndIsPushedAgain() {
        let listener = startListener()
        let awake = Locked(false)
        listener.macState = { $0 == "phone-1" ? MacState(awake: awake.get(), control: true) : nil }
        let (_, probe) = readyClient(listener)
        wait(for: [probe.expect(self, "state") { Self.state($0) == [MacState(awake: false, control: true)] }], timeout: 5)
        awake.set(true)
        listener.pushMacState()
        wait(for: [probe.expect(self, "pushed") { Self.state($0).last == MacState(awake: true, control: true) }], timeout: 5)
    }

    func testNoMacStateWithoutAProvider() {
        let listener = startListener()
        let (_, probe) = readyClient(listener)
        wait(for: [probe.expect(self, "sessions") { $0.contains { if case .sessions = $0 { true } else { false } } }], timeout: 5)
        listener.pushMacState()
        let (_, second) = readyClient(listener)
        wait(for: [second.expect(self, "sessions") { $0.contains { if case .sessions = $0 { true } else { false } } }], timeout: 5)
        XCTAssertTrue(Self.state(probe.events.get()).isEmpty)
    }

    func testControlRequestsReachTheHandlerWithThePhone() {
        let listener = startListener()
        let asked = Locked<[String]>([])
        listener.onMacControl = { phoneID, label, change in
            asked.set(asked.get() + ["\(phoneID) \(label) \(change)"])
            return nil
        }
        let (client, probe) = readyClient(listener)
        client.setAwake(true)
        client.setVPN(false)
        waitUntil("both asked") { asked.get().count == 2 }
        XCTAssertEqual(asked.get(), ["phone-1 Test iPhone awake(true)", "phone-1 Test iPhone vpn(false)"])
        XCTAssertTrue(probe.failures.isEmpty)
    }

    func testARefusedControlRequestIsAnswered() {
        let listener = startListener()
        listener.onMacControl = { _, _, _ in .notAllowed }
        let (client, probe) = readyClient(listener)
        client.setVPN(false)
        wait(for: [probe.expect(self, "refused") { _ in probe.failures == [.notAllowed] }], timeout: 5)
        XCTAssertFalse(probe.disconnected, "the connection carries on")
    }

    func testControlWithoutAHandlerIsABadRequest() {
        let listener = startListener()
        let (client, probe) = readyClient(listener)
        client.setAwake(true)
        wait(for: [probe.expect(self, "refused") { _ in probe.failures == [.badRequest] }], timeout: 5)
    }

    func testClientIsToldWhenTheScreenIsNotAllowed() {
        let listener = startListener()
        let (client, probe) = readyClient(listener)
        client.requestScreen()
        wait(for: [probe.expect(self, "refused") { $0.contains { if case .failed(.screenNotAllowed, _) = $0 { true } else { false } } }],
             timeout: 5)
    }

    /// Against this Mac's real Screen Sharing, when asked for
    /// (`PASSTHROUGH_LIVE_SCREEN=1`) and it is on: Apple's banner comes
    /// through the relay.
    func testLiveScreenSharingBanner() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["PASSTHROUGH_LIVE_SCREEN"] == "1",
                          "set PASSTHROUGH_LIVE_SCREEN=1 with Screen Sharing on")
        let listener = startListener()
        listener.screenAllowed = { _ in true }
        listener.screenSharingVerified = { true }   // the test asserts it is the real one
        let (stream, _) = rawAuthorized(listener)
        stream.send(try ShellEnvelope(t: ShellEnvelope.screen).encodedLine(), isComplete: false) { _ in }
        let got = read(stream, "banner", orEnd: true) { $0.firstRange(of: Data("RFB 003.".utf8)) != nil || Self.lines($0).contains { $0.t == "error" } }
        XCTAssertNotNil(got.firstRange(of: Data("{\"t\":\"screenReady\"}\nRFB 003.".utf8)), String(decoding: got, as: UTF8.self))
    }

    /// The whole path against this Mac's real Screen Sharing: the phone's
    /// client asks, the relay hands over, and the viewer logs in with
    /// Apple's method and gets a frame. Needs Screen Sharing on and
    /// `PASSTHROUGH_LIVE_SCREEN=1`, `PASSTHROUGH_SCREEN_USER` and
    /// `PASSTHROUGH_SCREEN_PASSWORD` (this Mac's account).
    func testLiveScreenSharingLogin() throws {
        let env = ProcessInfo.processInfo.environment
        guard env["PASSTHROUGH_LIVE_SCREEN"] == "1", let user = env["PASSTHROUGH_SCREEN_USER"],
              let password = env["PASSTHROUGH_SCREEN_PASSWORD"] else {
            throw XCTSkip("set PASSTHROUGH_LIVE_SCREEN=1, PASSTHROUGH_SCREEN_USER and PASSTHROUGH_SCREEN_PASSWORD with Screen Sharing on")
        }
        let listener = startListener()
        listener.screenAllowed = { _ in true }
        listener.screenSharingVerified = { true }
        let (client, probe) = readyClient(listener)
        client.requestScreen()
        wait(for: [probe.expect(self, "handed over") { $0.contains { if case .screen = $0 { true } else { false } } }], timeout: 10)
        guard case let .screen(stream, initial)? = probe.events.get().last else { return XCTFail("no screen") }
        let events = Locked<[RFBClient.Event]>([])
        let framed = expectation(description: "a frame")
        let rfb = RFBClient(stream: stream, initialBytes: initial, login: .init(username: user, password: password), queue: .global()) { event in
            events.set(events.get() + [event])
            switch event {
            case .frame: framed.fulfill()
            case let .closed(failure): XCTFail("closed: \(String(describing: failure))"); framed.fulfill()
            default: break
            }
        }
        rfb.start()
        wait(for: [framed], timeout: 20)
        rfb.close()
        guard case let .connected(width, height, name)? = events.get().first else { return XCTFail("\(events.get())") }
        print("Screen Sharing: \(name), \(width)×\(height)")
        XCTAssertGreaterThan(width, 0)
    }

    func testCandidatesOrder() {
        let credential = ShellCredential(macID: "m", macName: "Mac", certSHA256: "x", shellKey: Data(), phoneID: "p",
                                         port: 7893, addresses: ["192.168.1.2", "fd00::2", "100.100.1.1"])
        let discovered = NWEndpoint.service(name: "Mac", type: RemoteShell.serviceType, domain: "local.", interface: nil)
        let port = NWEndpoint.Port(rawValue: 7893)!
        XCTAssertEqual(ShellClient.candidates(for: credential, discovered: discovered), [
            discovered,
            .hostPort(host: "192.168.1.2", port: port),
            .hostPort(host: "fd00::2", port: port),
            .hostPort(host: "100.100.1.1", port: port),
        ])
        XCTAssertEqual(ShellClient.candidates(for: credential, discovered: nil).count, 3)
    }
}

private final class FakeVideoSource: ScreenVideoSource, @unchecked Sendable {
    let stream = Locked<(any ByteStream)?>(nil)
    let ended = Locked<(@Sendable () -> Void)?>(nil)
    let stopped = Locked(false)

    func start(stream: any ByteStream, initialBytes: Data, ended: @escaping @Sendable () -> Void) {
        self.ended.set(ended)
        self.stream.set(stream)
    }

    func stop() { stopped.set(true) }
}
#endif
