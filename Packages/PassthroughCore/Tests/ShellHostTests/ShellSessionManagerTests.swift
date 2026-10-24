#if os(macOS)
import Foundation
import PassthroughCore
import XCTest
@testable import ShellHost

final class ShellSessionManagerTests: XCTestCase {
    private var directory: URL!
    private var store: TranscriptStore!
    private var manager: ShellSessionManager!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShellSessionManagerTests-\(UUID().uuidString)", isDirectory: true)
        store = try TranscriptStore(directory: directory)
        manager = makeManager()
    }

    override func tearDown() {
        manager.closeAll()
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeManager(retention: TimeInterval = 600) -> ShellSessionManager {
        ShellSessionManager(
            transcripts: store,
            command: { ("/bin/sh", []) },
            environment: { ["PATH": "/usr/bin:/bin", "TERM": "xterm-256color", "PS1": "$ "] },
            directory: URL(fileURLWithPath: "/tmp"),
            endedRetention: retention)
    }

    private final class FakeClient: ShellAttachment, @unchecked Sendable {
        private let lock = NSLock()
        private var chunks: [Data] = []
        private var endStatus: Int32?
        private var detachCount = 0
        private var replayedAfter: Int?
        /// How many chunks had arrived when `shellReplayed` came.
        var replayedAt: Int? { lock.lock(); defer { lock.unlock() }; return replayedAfter }
        var deliveries: [Data] { lock.lock(); defer { lock.unlock() }; return chunks }
        var text: String { String(decoding: deliveries.reduce(Data(), +), as: UTF8.self) }
        var exitStatus: Int32? { lock.lock(); defer { lock.unlock() }; return endStatus }
        var detaches: Int { lock.lock(); defer { lock.unlock() }; return detachCount }
        func shellOutput(_ data: Data, session: String) { lock.lock(); chunks.append(data); lock.unlock() }
        func shellEnded(session: String, exitStatus: Int32) { lock.lock(); endStatus = exitStatus; lock.unlock() }
        func shellDetached(session: String, generation: UInt64) { lock.lock(); detachCount += 1; lock.unlock() }
        func shellReplayed(session: String) { lock.lock(); replayedAfter = chunks.count; lock.unlock() }
    }

    private func wait(_ message: String, timeout: TimeInterval = 10, until condition: () -> Bool,
                      file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { XCTFail("timed out: \(message)", file: file, line: line); return }
            Thread.sleep(forTimeInterval: 0.02)
        }
    }

    private func info(_ id: String) -> ShellSessionInfo? { manager.sessions.first { $0.id == id } }

    func testOpenListsRunningSession() throws {
        let id = try manager.open(phoneLabel: "Pixel", cols: 80, rows: 24)
        XCTAssertEqual(manager.sessions.count, 1)
        XCTAssertEqual(info(id)?.running, true)
        XCTAssertEqual(info(id)?.title, "~")
        XCTAssertNotNil(UUID(uuidString: id))
        XCTAssertEqual(store.entries().map(\.id), [id])
    }

    func testCapIsEnforced() throws {
        for _ in 0..<RemoteShell.maxSessions { _ = try manager.open(phoneLabel: "Pixel", cols: 80, rows: 24) }
        XCTAssertThrowsError(try manager.open(phoneLabel: "Pixel", cols: 80, rows: 24)) {
            XCTAssertEqual($0 as? ShellError, .tooManySessions)
        }
    }

    /// Revoking a phone ends the sessions it opened, and only those.
    func testCloseSessionsOpenedByAPhone() throws {
        let a1 = try manager.open(phoneLabel: "A", phoneID: "a", cols: 80, rows: 24)
        let a2 = try manager.open(phoneLabel: "A", phoneID: "a", cols: 80, rows: 24)
        let b = try manager.open(phoneLabel: "B", phoneID: "b", cols: 80, rows: 24)
        let mac = try manager.open(phoneLabel: "Mac", cols: 80, rows: 24)
        manager.closeSessions(openedBy: "a")
        wait("a's sessions ended") { info(a1)?.running == false && info(a2)?.running == false }
        Thread.sleep(forTimeInterval: 0.1)
        XCTAssertEqual(info(b)?.running, true)
        XCTAssertEqual(info(mac)?.running, true)
    }

    func testEndedSessionsDoNotCountTowardCap() throws {
        let first = try manager.open(phoneLabel: "Pixel", cols: 80, rows: 24)
        manager.input(first, Data("exit 0\n".utf8))
        wait("first ended") { info(first)?.running == false }
        for _ in 0..<RemoteShell.maxSessions { _ = try manager.open(phoneLabel: "Pixel", cols: 80, rows: 24) }
        XCTAssertNil(info(first), "an open prunes ended sessions")
    }

    func testOutputWhileDetachedIsReplayed() throws {
        let id = try manager.open(phoneLabel: "Pixel", cols: 80, rows: 24)
        manager.input(id, Data("echo replayed\n".utf8))
        wait("transcript has output") { String(decoding: (try? store.output(of: id)) ?? Data(), as: UTF8.self).contains("replayed") }
        let client = FakeClient()
        try manager.attach(id, client: client, cols: 80, rows: 24)
        wait("replay delivered") { client.text.contains("replayed") }
        XCTAssertTrue(String(decoding: client.deliveries[0], as: UTF8.self).contains("replayed"))
    }

    func testReplayIsChunked() throws {
        let id = try manager.open(phoneLabel: "Pixel", cols: 80, rows: 24)
        manager.input(id, Data("head -c 40000 /dev/zero | tr '\\0' x; echo done\n".utf8))
        // "xdone": the echoed command line ends in "done" too.
        wait("output complete") { String(decoding: (try? store.output(of: id)) ?? Data(), as: UTF8.self).contains("xdone\r\n") }
        let client = FakeClient()
        try manager.attach(id, client: client, cols: 80, rows: 24)
        wait("replay delivered") { client.text.contains("xdone") }
        XCTAssertGreaterThan(client.deliveries.count, 1)
        XCTAssertTrue(client.deliveries.allSatisfy { $0.count <= RemoteShell.outputChunk })
    }

    func testReplayedComesAfterReplayAndBeforeLiveOutput() throws {
        let id = try manager.open(phoneLabel: "Pixel", cols: 80, rows: 24)
        manager.input(id, Data("head -c 40000 /dev/zero | tr '\\0' x; echo before-$((6*7))\n".utf8))
        wait("output complete") { String(decoding: (try? store.output(of: id)) ?? Data(), as: UTF8.self).contains("before-42\r\n") }
        let client = FakeClient()
        try manager.attach(id, client: client, cols: 80, rows: 24)
        wait("replayed") { client.replayedAt != nil }
        manager.input(id, Data("echo after-$((6*7))\n".utf8))
        wait("live output") { client.text.contains("after-42") }
        let split = try XCTUnwrap(client.replayedAt)
        let chunks = client.deliveries
        XCTAssertGreaterThan(split, 1, "the replay is chunked")
        let replay = String(decoding: chunks[..<split].reduce(Data(), +), as: UTF8.self)
        let live = String(decoding: chunks[split...].reduce(Data(), +), as: UTF8.self)
        XCTAssertTrue(replay.contains("before-42\r\n"))
        XCTAssertFalse(replay.contains("after-"))
        XCTAssertTrue(live.contains("after-42"))
    }

    func testAttachUnknownSessionThrows() {
        XCTAssertThrowsError(try manager.attach("nope", client: FakeClient(), cols: 80, rows: 24)) {
            XCTAssertEqual($0 as? ShellError, .noSuchSession)
        }
    }

    func testLiveOutputReachesAttachment() throws {
        let id = try manager.open(phoneLabel: "Pixel", cols: 80, rows: 24)
        let client = FakeClient()
        try manager.attach(id, client: client, cols: 80, rows: 24)
        manager.input(id, Data("echo live\n".utf8))
        wait("live output") { client.text.contains("live") }
    }

    func testExitWhileDetachedIsReported() throws {
        let id = try manager.open(phoneLabel: "Pixel", cols: 80, rows: 24)
        manager.input(id, Data("exit 4\n".utf8))
        wait("session ended") { info(id)?.running == false }
        XCTAssertEqual(info(id)?.exitStatus, 4)
        XCTAssertEqual(store.entries().first { $0.id == id }?.exitStatus, 4)
        XCTAssertNotNil(store.entries().first { $0.id == id }?.endedAt)
    }

    func testExitReachesAttachmentAndLaterAttachSeesEnd() throws {
        let id = try manager.open(phoneLabel: "Pixel", cols: 80, rows: 24)
        let first = FakeClient()
        try manager.attach(id, client: first, cols: 80, rows: 24)
        manager.input(id, Data("exit 3\n".utf8))
        wait("end delivered") { first.exitStatus == 3 }
        let second = FakeClient()
        try manager.attach(id, client: second, cols: 80, rows: 24)
        wait("end replayed") { second.exitStatus == 3 }
    }

    func testSecondAttachTakesOver() throws {
        let id = try manager.open(phoneLabel: "Pixel", cols: 80, rows: 24)
        let a = FakeClient(), b = FakeClient()
        let first = try manager.attach(id, client: a, cols: 80, rows: 24)
        let second = try manager.attach(id, client: b, cols: 80, rows: 24)
        XCTAssertGreaterThan(second, first, "every attach gets a new generation")
        wait("A detached") { a.detaches == 1 }
        let before = a.text
        manager.input(id, Data("echo second\n".utf8))
        wait("B output") { b.text.contains("second") }
        XCTAssertEqual(a.text, before)
        XCTAssertEqual(b.detaches, 0)
    }

    func testDetachStopsDelivery() throws {
        let id = try manager.open(phoneLabel: "Pixel", cols: 80, rows: 24)
        let client = FakeClient()
        try manager.attach(id, client: client, cols: 80, rows: 24)
        manager.detach(client: client)
        manager.input(id, Data("echo gone\n".utf8))
        wait("transcript has output") { String(decoding: (try? store.output(of: id)) ?? Data(), as: UTF8.self).contains("gone") }
        XCTAssertFalse(client.text.contains("gone"))
        XCTAssertEqual(client.detaches, 0)
    }

    func testResizeReachesTheTerminal() throws {
        let id = try manager.open(phoneLabel: "Pixel", cols: 80, rows: 24)
        manager.resize(id, cols: 100, rows: 30)
        manager.input(id, Data("stty size\n".utf8))
        wait("size reported") { String(decoding: (try? store.output(of: id)) ?? Data(), as: UTF8.self).contains("30 100") }
        // The transcript records the size, before the output drawn at it.
        let replay = try store.replay(of: id)
        let resized = try XCTUnwrap(replay.firstIndex(of: .resize(cols: 100, rows: 30)))
        let answer = try XCTUnwrap(replay.firstIndex { if case .output(let d) = $0 { String(decoding: d, as: UTF8.self).contains("30 100") } else { false } })
        XCTAssertLessThan(resized, answer)
    }

    func testCloseEndsSession() throws {
        let id = try manager.open(phoneLabel: "Pixel", cols: 80, rows: 24)
        manager.close(id)
        wait("session ended") { info(id)?.running == false }
        XCTAssertNotNil(info(id)?.exitStatus)
    }

    func testCloseAllFinishesTranscripts() throws {
        _ = try manager.open(phoneLabel: "Pixel", cols: 80, rows: 24)
        _ = try manager.open(phoneLabel: "Pixel", cols: 80, rows: 24)
        manager.closeAll()
        XCTAssertTrue(manager.sessions.allSatisfy { !$0.running })
        let entries = store.entries()
        XCTAssertEqual(entries.count, 2)
        XCTAssertTrue(entries.allSatisfy { $0.endedAt != nil })
    }

    func testTitleIsFirstCommand() throws {
        let id = try manager.open(phoneLabel: "Pixel", cols: 80, rows: 24)
        manager.input(id, Data("echo hel".utf8))
        XCTAssertEqual(info(id)?.title, "~")
        manager.input(id, Data("lo\r".utf8))
        wait("title set") { info(id)?.title == "echo hello" }
        manager.input(id, Data("echo other\r".utf8))
        wait("second command run") { String(decoding: (try? store.output(of: id)) ?? Data(), as: UTF8.self).contains("other\r\n") }
        XCTAssertEqual(info(id)?.title, "echo hello")
        XCTAssertEqual(store.entries().first { $0.id == id }?.title, "echo hello")
    }

    /// A line typed at a no-echo prompt (a password) never becomes the title;
    /// the first echoed command does.
    func testUnechoedLineIsNeverTheTitle() throws {
        manager = ShellSessionManager(
            transcripts: store,
            command: { ("/bin/sh", ["-c", "stty -echo; read line; stty echo; echo read-done; exec /bin/sh"]) },
            environment: { ["PATH": "/usr/bin:/bin", "TERM": "xterm-256color", "PS1": "$ "] },
            directory: URL(fileURLWithPath: "/tmp"))
        let id = try manager.open(phoneLabel: "Pixel", cols: 80, rows: 24)
        Thread.sleep(forTimeInterval: 0.3)   // stty has run
        manager.input(id, Data("hunter2-secret\r".utf8))
        wait("read finished") { String(decoding: (try? store.output(of: id)) ?? Data(), as: UTF8.self).contains("read-done") }
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertEqual(info(id)?.title, "~")
        manager.input(id, Data("echo visible\r".utf8))
        wait("echoed command is the title") { info(id)?.title == "echo visible" }
        XCTAssertFalse(store.entries().contains { $0.title.contains("hunter2") })
    }

    /// Arrow keys (CSI and SS3) and a line cleared with ctrl-U or ctrl-C
    /// don't end up in the title.
    func testEscapesAndClearedLinesStayOutOfTheTitle() throws {
        let id = try manager.open(phoneLabel: "Pixel", cols: 80, rows: 24)
        manager.input(id, Data("\u{1B}[A\u{1B}[1;5D\u{1B}OB".utf8))
        manager.input(id, Data("junk\u{15}".utf8))
        manager.input(id, Data("more\u{03}".utf8))
        manager.input(id, Data("echo arrows\r".utf8))
        wait("title set") { info(id)?.title != "~" }
        XCTAssertEqual(info(id)?.title, "echo arrows")
    }

    func testVisibleTextDropsEscapes() {
        let raw = Data("\u{1B}[1;32mec\u{1B}[0mho\u{1B}]0;title\u{07} hi\u{1B}]2;x\u{1B}\\\r\n".utf8)
        XCTAssertEqual(String(decoding: ShellSessionManager.visibleText(raw), as: UTF8.self), "echo hi\n\n")
    }

    /// Text either side of a line break is not one line: "ec", a break, then
    /// "ho hi" is not the echo of "echo hi".
    func testEchoCannotMatchAcrossALineBreak() {
        XCTAssertTrue(ShellSessionManager.echoShows("echo hi", in: Data("$ \u{1B}[1mecho\u{1B}[0m hi\r\n".utf8)))
        for broken in ["ec\r\nho hi", "ec\nho hi", "ec\rho hi", "echo\r\n hi"] {
            XCTAssertFalse(ShellSessionManager.echoShows("echo hi", in: Data(broken.utf8)), broken.debugDescription)
        }
    }

    func testTitleIsCappedAtSixtyCharacters() throws {
        let id = try manager.open(phoneLabel: "Pixel", cols: 80, rows: 24)
        manager.input(id, Data((String(repeating: "x", count: 100) + "\r").utf8))
        wait("title set") { info(id)?.title != "~" }
        XCTAssertEqual(info(id)?.title.count, 60)
    }

    func testEndedSessionIsPrunedAfterRetention() throws {
        manager = makeManager(retention: 0.3)
        let id = try manager.open(phoneLabel: "Pixel", cols: 80, rows: 24)
        manager.input(id, Data("exit 0\n".utf8))
        wait("session pruned") { info(id) == nil }
        XCTAssertEqual(store.entries().map(\.id), [id], "pruning keeps the transcript")
    }

    func testPrunedSessionIsFreed() throws {
        manager = makeManager(retention: 0.2)
        let id = try manager.open(phoneLabel: "Pixel", cols: 80, rows: 24)
        weak var session = manager.sessionObject(id)
        XCTAssertNotNil(session)
        manager.input(id, Data("exit 0\n".utf8))
        wait("session pruned") { info(id) == nil }
        wait("session freed") { session == nil }
    }

    func testOnChangeFires() throws {
        let fired = Counter()
        manager.onChange = { fired.increment() }
        let id = try manager.open(phoneLabel: "Pixel", cols: 80, rows: 24)
        wait("open reported") { fired.value >= 1 }
        manager.input(id, Data("exit 0\n".utf8))
        wait("exit reported") { fired.value >= 2 }
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var value: Int { lock.lock(); defer { lock.unlock() }; return count }
        func increment() { lock.lock(); count += 1; lock.unlock() }
    }
}
#endif
