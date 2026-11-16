#if os(macOS)
import Foundation
import PassthroughCore
import XCTest
@testable import ShellHost

/// OSC 7501 reports read from a session's output, and what the session
/// manager makes of them.
final class ProgramStatusTests: XCTestCase {
    /// What Claude Code 2.1.325 sent in a recorded run: a permission prompt,
    /// a background agent, then done.
    private static let recorded: [String] = [
        "\u{1b}]7501;state=idle:app=claude-code\u{7}",
        "\u{1b}]7501;state=working:app=claude-code\u{7}",
        "\u{1b}]7501;state=blocked:app=claude-code:kind=permission:msg=YXBwcm92ZSBCYXNoOiBjdXJsIC1zSSBodHRwczovL2V4YW1wbGUuY29tIC1vIC9kZXYvbnVsbA==\u{7}",
        "\u{1b}]7501;state=working:app=claude-code\u{7}",
        "\u{1b}]7501;state=working:app=claude-code:id=a98ef54decffe49b1:title=UnVuIHNsZWVwIGFuZCByZXBseSBwb25n\u{7}",
        "\u{1b}]7501;state=clear:id=a98ef54decffe49b1\u{7}",
        "\u{1b}]7501;state=done:app=claude-code\u{7}",
        "\u{1b}]7501;state=clear\u{7}",
    ]

    private func report(_ fields: String, end: String = "\u{7}") -> Data { Data("\u{1b}]7501;\(fields)\(end)".utf8) }
    private func b64(_ text: String) -> String { Data(text.utf8).base64EncodedString() }

    private func summary(_ status: ProgramStatus) -> String {
        guard let s = status.summary else { return "none" }
        return [s.state, s.kind, s.message, s.agents > 0 ? "agents=\(s.agents)" : nil].compactMap { $0 }.joined(separator: " | ")
    }

    func testARecordedClaudeCodeRun() {
        var status = ProgramStatus()
        var seen: [String] = []
        for sequence in Self.recorded {
            XCTAssertTrue(status.scan(Data(sequence.utf8)).contains(.changed), sequence)
            seen.append(summary(status))
        }
        XCTAssertEqual(seen, [
            "idle",
            "working",
            "blocked | permission | approve Bash: curl -sI https://example.com -o /dev/null",
            "working",
            "working | agents=1",
            "working",
            "done",
            "none",
        ])
    }

    func testTheQueryIsNoticedEitherWayItEnds() {
        var status = ProgramStatus()
        XCTAssertEqual(status.scan(Data("text\u{1b}]7501;?\u{7}\u{1b}[c".utf8)), .queried)
        XCTAssertEqual(status.scan(Data("\u{1b}]7501;?\u{1b}\\".utf8)), .queried)
        XCTAssertNil(status.summary)
    }

    func testReportsSplitAcrossChunksAndAmongOtherOutput() {
        var status = ProgramStatus()
        let whole = Data("\u{1b}]0;title\u{7}\u{1b}[31mred\u{1b}]7501;state=working:msg=\(b64("Reading files"))\u{1b}\\more".utf8)
        for byte in whole { _ = status.scan(Data([byte])) }
        XCTAssertEqual(summary(status), "working | Reading files")
    }

    /// A blocked agent makes the session blocked, named by its title; done
    /// waits for every agent.
    func testAgents() {
        var status = ProgramStatus()
        _ = status.scan(report("state=done"))
        _ = status.scan(report("state=working:id=a1:title=\(b64("Search the code"))"))
        XCTAssertEqual(summary(status), "working | agents=1", "not done while an agent works")
        _ = status.scan(report("state=blocked:kind=permission:id=a1/b:title=\(b64("Run tests")):msg=\(b64("approve Bash: swift test"))"))
        XCTAssertEqual(summary(status), "blocked | permission | Run tests: approve Bash: swift test | agents=2")
        _ = status.scan(report("state=clear:id=a1"))
        XCTAssertEqual(summary(status), "done", "clearing a record clears the ones beneath it")
    }

    func testMalformedReportsAreIgnored() {
        var status = ProgramStatus()
        _ = status.scan(report("state=working"))
        for bad in ["state=sleeping", "kind=question", "state=done:msg=@@@", "state=done:id=bad id", "state=done:id=a//b",
                    "state=done:msg=\(b64("two\nlines"))"] {
            XCTAssertEqual(status.scan(report(bad)), [], bad)
        }
        XCTAssertEqual(summary(status), "working")
        XCTAssertEqual(status.scan(Data(("\u{1b}]7501;state=done:msg=" + String(repeating: "A", count: 5000) + "\u{7}").utf8)), [], "too long")
        XCTAssertEqual(summary(status), "working")
        XCTAssertEqual(status.scan(report("state=blocked:kind=nonsense")), .changed)
        XCTAssertEqual(summary(status), "blocked", "an unknown kind is left out")
    }

    func testAFullResetAndAProgramGoneEndWhatItWasDoing() {
        var status = ProgramStatus()
        _ = status.scan(report("state=working"))
        XCTAssertEqual(status.scan(Data("\u{1b}c".utf8)), .changed)
        XCTAssertNil(status.summary)
        _ = status.scan(report("state=blocked:kind=question"))
        _ = status.scan(report("state=done:id=x"))
        XCTAssertTrue(status.dropUnfinished())
        XCTAssertEqual(summary(status), "none", "only an agent's record is left, and the session has no root")
        XCTAssertFalse(status.hasUnfinished)
    }

    func testOtherTerminalsAnswersToTheQueryAreDropped() {
        let typed = Data("ab\u{1b}]7501;?:states=idle,working\u{1b}\\cd\u{1b}]11;rgb:0/0/0\u{7}".utf8)
        XCTAssertEqual(TerminalReports.removingProgramStatusReplies(from: typed), Data("abcd\u{1b}]11;rgb:0/0/0\u{7}".utf8))
        XCTAssertEqual(TerminalReports.removingProgramStatusReplies(from: Data("plain".utf8)), Data("plain".utf8))
    }

    // MARK: The session manager

    final class Client: ShellAttachment, @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        var text: String { lock.lock(); defer { lock.unlock() }; return String(decoding: data, as: UTF8.self) }
        func shellOutput(_ data: Data, session: String) { lock.lock(); self.data.append(data); lock.unlock() }
        func shellEnded(session: String, exitStatus: Int32) {}
        func shellDetached(session: String, generation: UInt64) {}
    }

    private var directory: URL!
    private var manager: ShellSessionManager!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("ProgramStatusTests-\(UUID().uuidString)", isDirectory: true)
        manager = ShellSessionManager(
            transcripts: try TranscriptStore(directory: directory),
            command: { ("/bin/sh", []) },
            environment: { ["PATH": "/usr/bin:/bin", "TERM": "xterm-256color", "PS1": "$ "] },
            directory: URL(fileURLWithPath: "/tmp"),
            endedRetention: 600,
            quietBeforeAsking: 0.2)
    }

    override func tearDown() {
        manager.closeAll()
        try? FileManager.default.removeItem(at: directory)
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

    /// A program in a job of its own (as Claude Code runs) prints `reports`, one a second apart, then waits.
    private func run(_ reports: [String], in id: String) {
        let printfs = reports.map { "printf '\\033]7501;\($0)\\007'; sleep 1" }.joined(separator: "; ")
        manager.input(id, Data("sh -c \"\(printfs); sleep 60\"\n".utf8))
    }

    func testTheMacAnswersTheQuery() throws {
        let id = try manager.open(phoneLabel: "iPhone", cols: 80, rows: 24)
        let phone = Client()
        try manager.attach(id, client: phone, cols: 80, rows: 24)
        manager.input(id, Data("sh -c \"stty -echo -icanon min 1; printf '\\033]7501;?\\007'; head -c 12 | od -An -c\"\n".utf8))
        wait("the answer reaches the program") { phone.text.contains("7   5   0   1   ;   ?   :") }
    }

    func testABlockedProgramIsWaitingOnItsQuestionUntilItIsGone() throws {
        let id = try manager.open(phoneLabel: "iPhone", cols: 80, rows: 24)
        try manager.attach(id, client: Client(), cols: 80, rows: 24)
        run(["state=working:msg=\(b64("Reading files"))", "state=blocked:kind=question:msg=\(b64("Pick a colour?"))"], in: id)
        wait("working") { info(id)?.status?.state == "working" }
        XCTAssertEqual(info(id)?.status?.message, "Reading files")
        XCTAssertNil(info(id)?.waiting)
        wait("blocked") { info(id)?.status?.state == "blocked" }
        XCTAssertEqual(info(id)?.status?.kind, "question")
        XCTAssertEqual(info(id)?.waiting, "Pick a colour?", "everything that shows needs-you sees it")
        // Killed without clearing: once the shell's prompt is back, it isn't waiting any more.
        manager.input(id, Data([0x03]))
        wait("gone with the program") { info(id).map { $0.status == nil && $0.waiting == nil } ?? false }
    }

    /// A program the shell `exec`ed is the shell itself, in front all along: what it says stands.
    func testAProgramTheShellBecameKeepsItsStatus() throws {
        let id = try manager.open(phoneLabel: "iPhone", cols: 80, rows: 24)
        try manager.attach(id, client: Client(), cols: 80, rows: 24)
        manager.input(id, Data("exec sh -c \"printf '\\033]7501;state=working\\007'; sleep 1; printf 'more output'; sleep 60\"\n".utf8))
        wait("working") { info(id)?.status?.state == "working" }
        Thread.sleep(forTimeInterval: 1.5)   // past its next output
        XCTAssertEqual(info(id)?.status?.state, "working")
    }

    func testDoneIsSeenOnceSomeoneHasTheSessionOpen() throws {
        let id = try manager.open(phoneLabel: "iPhone", cols: 80, rows: 24)
        let phone = Client()
        try manager.attach(id, client: phone, cols: 80, rows: 24)
        run(["state=working", "state=done"], in: id)
        wait("done") { info(id)?.status?.state == "done" }
        XCTAssertEqual(info(id)?.status?.seen, true, "the phone had it open")

        let unseen = try manager.open(phoneLabel: "iPhone", cols: 80, rows: 24)
        run(["state=working", "state=done"], in: unseen)
        wait("done") { info(unseen)?.status?.state == "done" }
        XCTAssertEqual(info(unseen)?.status?.seen, false, "nobody was looking")
        XCTAssertTrue(info(unseen)?.status?.isUnseenResult ?? false)
        try manager.attach(unseen, client: Client(), cols: 80, rows: 24)
        wait("seen once opened") { info(unseen)?.status?.seen == true }
    }
}
#endif
