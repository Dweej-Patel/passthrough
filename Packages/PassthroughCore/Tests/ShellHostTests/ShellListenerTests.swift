#if os(macOS)
import Foundation
import Network
import XCTest
import PassthroughCore
import PhoneTransport
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
                               events: Locked<[String]>? = nil, keys: Locked<[String: Data]>? = nil) -> ShellListener {
        let keys = keys ?? Locked(["phone-1": key])
        let listener = ShellListener(identity: identity, port: 0, advertise: false, manager: manager, transcripts: store,
                                     shellKeys: { keys.get()[$0].map { [$0] } ?? [] },
                                     phoneLabel: { $0 == "phone-1" ? "Test iPhone" : "?" },
                                     peerAllowed: peerAllowed)
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

    /// Revoking a phone cuts its live connection at once; another phone and
    /// the sessions themselves carry on, and the revoked phone cannot return.
    func testDisconnectPhoneCutsOnlyThatPhone() {
        let otherKey = WirelessLink.randomBytes(32)
        let keys = Locked(["phone-1": key, "phone-2": otherKey])
        let listener = startListener(keys: keys)
        let (a, aProbe) = readyClient(listener)
        let (b, bProbe) = readyClient(listener, phoneID: "phone-2", key: otherKey)
        let id = openSession(a, aProbe)

        keys.set(["phone-2": otherKey])
        listener.disconnect(phoneID: "phone-1")
        wait(for: [aProbe.expect(self, "A disconnected") { _ in aProbe.disconnected }], timeout: 5)

        b.list()
        wait(for: [bProbe.expect(self, "B still served") { events in
            events.contains { if case .sessions(let list) = $0 { return list.contains { $0.id == id && $0.running } } else { return false } }
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
#endif
