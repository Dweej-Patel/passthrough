#if os(macOS)
import Foundation
import PassthroughCore
import XCTest
@testable import PassthroughCore
@testable import ShellHost

/// A replay that starts partway through a session turns on the modes the
/// cut-off output had turned on (Claude Code's fullscreen mode, vim, less).
final class TerminalModesTests: XCTestCase {
    private func modes(_ text: String) -> TerminalModes {
        TerminalModes().scanned(Data(text.utf8))
    }

    private func restoring(_ text: String) -> String {
        String(decoding: modes(text).restoring, as: UTF8.self)
    }

    func testNothingOnRestoresNothing() {
        XCTAssertEqual(restoring("hello\r\n\u{1b}[31mred\u{1b}[0m \u{1b}[2J\u{1b}[H"), "")
        XCTAssertEqual(restoring("\u{1b}[?25l\u{1b}[?25h\u{1b}[?2004h\u{1b}[?2004l"), "", "turned back off")
    }

    /// What Claude Code's fullscreen mode turns on as it starts.
    func testAFullScreenProgramsModes() {
        let start = "\u{1b}[?2004h\u{1b}[?1004h\u{1b}[>5u\u{1b}[?1049h\u{1b}[<u\u{1b}[>5u"
            + "\u{1b}[?1000h\u{1b}[?1002h\u{1b}[?1003h\u{1b}[?1006h\u{1b}[>4;2m\u{1b}[?25l"
        let found = modes(start)
        XCTAssertTrue(found.isAlternateScreen)
        XCTAssertEqual(restoring(start),
                       "\u{1b}[=0;1u\u{1b}[>5u"        // the main screen's keyboard flags
                       + "\u{1b}[?1049h"
                       + "\u{1b}[=0;1u\u{1b}[>5u"      // the alternate screen's
                       + "\u{1b}[?25l\u{1b}[?1004h\u{1b}[?2004h"
                       + "\u{1b}[?1003h\u{1b}[?1006h\u{1b}[>4;2m")
    }

    func testLeavingTheAlternateScreenAndTurningTheMouseOff() {
        XCTAssertEqual(restoring("\u{1b}[?1049h\u{1b}[?1002h\u{1b}[?1000l\u{1b}[?1049l"), "")
        XCTAssertEqual(restoring("\u{1b}[?1049h\u{1b}[?1006h\u{1b}[?1006l"), "\u{1b}[?1049h")
        XCTAssertEqual(restoring("\u{1b}[?1;1049h\u{1b}="), "\u{1b}[?1049h\u{1b}[?1h\u{1b}=", "several modes in one sequence")
    }

    func testAFullResetTurnsEverythingOff() {
        XCTAssertEqual(restoring("\u{1b}[?1049h\u{1b}[?2004h\u{1b}[>1u\u{1b}c"), "")
    }

    func testSoftResetLeavesTheScreen() {
        XCTAssertEqual(restoring("\u{1b}[?1049h\u{1b}[?1h\u{1b}[?25l\u{1b}=\u{1b}[!p"), "\u{1b}[?1049h")
    }

    func testKeyboardStackPopsAndSets() {
        XCTAssertEqual(restoring("\u{1b}[>1u\u{1b}[>3u\u{1b}[<u"), "\u{1b}[=0;1u\u{1b}[>1u")
        XCTAssertEqual(restoring("\u{1b}[>1u\u{1b}[<5u"), "", "popping past the bottom empties it")
        XCTAssertEqual(restoring("\u{1b}[=8;1u\u{1b}[=1;2u\u{1b}[=8;3u"), "\u{1b}[=1;1u")
    }

    func testSequencesSplitAcrossScansAndOtherSequencesAreSkipped() {
        var split = TerminalModes()
        split.scan(Data("\u{1b}[?10".utf8))
        split.scan(Data("49h".utf8))
        XCTAssertTrue(split.isAlternateScreen)
        // An OSC title and an SGR around it read as nothing.
        XCTAssertEqual(restoring("\u{1b}]0;title?1049h\u{7}\u{1b}[38;5;1m"), "")
        XCTAssertEqual(restoring("\u{1b}[?" + String(repeating: "1;", count: 100) + "1049h"), "", "too long to be one")
    }

    /// An escape ends a string and begins a sequence, as the phone's
    /// terminal reads it: even one wrapped for another terminal (tmux passthrough) counts.
    func testAnEscapeEndsAString() {
        XCTAssertEqual(restoring("\u{1b}Ptmux;\u{1b}\u{1b}[?1049h\u{1b}\\"), "\u{1b}[?1049h")
        XCTAssertEqual(restoring("\u{1b}]0;unterminated title\u{1b}[?2004h"), "\u{1b}[?2004h")
        XCTAssertEqual(restoring("\u{1b}]0;?1049h\u{7}"), "", "what is in it is text")
    }

    func testSoftResetTurnsTheKeypadModeOff() {
        XCTAssertEqual(restoring("\u{1b}[?66h\u{1b}[!p"), "")
    }

    /// A Mac terminal window that stops showing a session turns off every
    /// mode a replay could have turned on in it.
    func testAMacWindowLeavingUndoesEveryModeAReplayRestores() {
        var on = "\u{1b}[>5u\u{1b}[?1049h\u{1b}[>3u\u{1b}=\u{1b}[>4;2m\u{1b}[?1003h\u{1b}[?1006h"
        for (mode, initial) in TerminalModes.switches { on += "\u{1b}[?\(mode)\(initial ? "l" : "h")" }
        for (tracking, encoding) in [(9, 1005), (1000, 1015), (1001, 1016), (1002, 1006)] {
            let left = modes(on + "\u{1b}[?\(tracking)h\u{1b}[?\(encoding)h").scanned(LocalTerminalClient.restoreTerminal)
            XCTAssertEqual(String(decoding: left.restoring, as: UTF8.self), "", "\(tracking)/\(encoding)")
        }
    }

    // MARK: Replays

    /// However output arrives, a replay is the modes where its tail starts plus the tail.
    func testReplaysMatchReadingEverythingFromTheStart() {
        var generator = SystemRandomNumberGenerator()
        let pieces = ["text ", "\r\n", "\u{1b}[?1049h", "\u{1b}[?1049l", "\u{1b}[?2004h", "\u{1b}[?2004l",
                      "\u{1b}[>5u", "\u{1b}[<u", "\u{1b}[?1002h", "\u{1b}[?1000l", "\u{1b}[31m", "é"]
        for capacity in [16, 40, 100] {
            var buffer = ScrollbackBuffer(capacity: capacity)
            var all = Data()
            for _ in 0..<400 {
                var chunk = ""
                for _ in 0..<Int.random(in: 1...4, using: &generator) { chunk += pieces.randomElement(using: &generator)! }
                var data = Data(chunk.utf8)
                // Split sequences across appends too.
                if data.count > 2, Bool.random(using: &generator) {
                    let cut = Int.random(in: 1..<data.count, using: &generator)
                    buffer.append(data.prefix(cut)); all.append(data.prefix(cut)); data = data.dropFirst(cut)
                }
                buffer.append(data); all.append(data)
                guard buffer.isPartial else { continue }
                let contents = all.suffix(capacity)
                let tail: Data = contents.prefix(ScrollbackBuffer.resyncWindow).firstIndex(of: 0x0A)
                    .map { contents[($0 + 1)...] } ?? contents.drop { $0 & 0xC0 == 0x80 }
                let expected = TerminalModes().scanned(all[..<tail.startIndex]).restoring + tail
                XCTAssertEqual(buffer.replay, expected)
            }
        }
    }

    func testAReplayFromTheStartIsUnchanged() {
        var buffer = ScrollbackBuffer(capacity: 64)
        buffer.append(Data("\u{1b}[?1049hframe\n".utf8))
        XCTAssertFalse(buffer.isPartial)
        XCTAssertEqual(buffer.replay, Data("\u{1b}[?1049hframe\n".utf8))
    }

    /// The switch to the alternate screen scrolled out of the buffer long
    /// ago: the replay turns it back on before the frames.
    func testAPartialReplayTurnsOnWhatWasCutOff() {
        var buffer = ScrollbackBuffer(capacity: 32)
        buffer.append(Data("$ claude\r\n\u{1b}[?1049h\u{1b}[?1002h\u{1b}[?1006h".utf8))
        for n in 0..<20 { buffer.append(Data("\u{1b}[H frame \(n)\n".utf8)) }
        XCTAssertTrue(buffer.isPartial)
        XCTAssertTrue(buffer.modes.isAlternateScreen)
        let replay = String(decoding: buffer.replay, as: UTF8.self)
        XCTAssertTrue(replay.hasPrefix("\u{1b}[?1049h\u{1b}[?1002h\u{1b}[?1006h"), replay)
        XCTAssertTrue(replay.hasSuffix("frame 19\n"), replay)
        XCTAssertFalse(replay.contains("claude"))
    }

    /// Modes turned on and off within what is skipped to reach a line start count too.
    func testModesInTheSkippedStartOfTheTailCount() {
        var buffer = ScrollbackBuffer(capacity: 16)
        buffer.append(Data(String(repeating: "x", count: 30).utf8))
        buffer.append(Data("ab\u{1b}[?2004hcd\nlast".utf8))
        XCTAssertEqual(String(decoding: buffer.replay, as: UTF8.self), "\u{1b}[?2004hlast")
        buffer.append(Data("\u{1b}[?2004l".utf8))
        XCTAssertEqual(String(decoding: buffer.replay, as: UTF8.self), "\u{1b}[?2004hlast\u{1b}[?2004l", "on where the tail starts; the tail turns it off")
    }

    // MARK: Attaching

    final class Client: ShellAttachment, @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        var text: String { lock.lock(); defer { lock.unlock() }; return String(decoding: data, as: UTF8.self) }
        func shellOutput(_ data: Data, session: String) { lock.lock(); self.data.append(data); lock.unlock() }
        func shellEnded(session: String, exitStatus: Int32) {}
        func shellDetached(session: String, generation: UInt64) {}
    }

    private func wait(_ message: String, timeout: TimeInterval = 15, until condition: () -> Bool,
                      file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { XCTFail("timed out: \(message)", file: file, line: line); return }
            Thread.sleep(forTimeInterval: 0.02)
        }
    }

    /// Attaching to a full-screen program whose start is gone from the
    /// scrollback has it redraw (one row shorter for a moment, then back):
    /// the replay alone may not hold all of its screen.
    func testAttachingToAFullScreenProgramReplayedFromPartwayRedrawsIt() throws {
        try checkRedraw(shared: false)
    }

    /// A Mac window joining a session the phone uses redraws it too: on the
    /// alternate screen there is no prompt for the resize to wipe.
    func testAMacWindowJoiningAFullScreenProgramReplayedFromPartwayRedrawsIt() throws {
        try checkRedraw(shared: true)
    }

    /// Two attaches close together: the terminal ends at its real size, not a row short.
    func testRedrawsCloseTogetherLeaveTheRealSize() throws {
        try checkRedraw(shared: false, again: true)
    }

    private func checkRedraw(shared: Bool, again: Bool = false) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TerminalModesTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let manager = ShellSessionManager(
            transcripts: try TranscriptStore(directory: directory),
            command: { ("/bin/sh", []) },
            environment: { ["PATH": "/usr/bin:/bin", "TERM": "xterm-256color", "PS1": "$ "] },
            directory: URL(fileURLWithPath: "/tmp"),
            endedRetention: 600,
            quietBeforeAsking: 0.2)
        defer { manager.closeAll() }
        let id = try manager.open(phoneLabel: "iPhone", cols: 80, rows: 24)
        let first = Client()
        try manager.attach(id, client: first, cols: 80, rows: 24)
        // Into the alternate screen, more than the scrollback holds, then wait reporting each size.
        let fill = RemoteShell.scrollbackBytes + 100_000
        manager.input(id, Data(("printf '\\033[?1049h'; head -c \(fill) /dev/zero | tr '\\0' x; echo; echo fi''lled; "
            // In a shell of its own, which the terminal's resize signal reaches (the
            // interactive one puts `sleep` in a process group of its own).
            + "exec sh -c 'trap \"echo size \\$(stty size)\" WINCH; while :; do sleep 0.05; done'\n").utf8))
        wait("the scrollback is past full") { first.text.contains("filled") }
        Thread.sleep(forTimeInterval: 0.3)   // the trap is set

        let second = Client()
        try manager.attach(id, client: second, cols: shared ? 120 : 80, rows: shared ? 40 : 24, shared: shared)
        if again { try manager.attach(id, client: Client(), cols: 120, rows: 40, shared: true) }
        wait("it redraws at one row fewer, then back") { second.text.contains("size 23 80") && second.text.contains("size 24 80") }
        if again {
            Thread.sleep(forTimeInterval: ShellSessionManager.redrawPause * 3)
            XCTAssertTrue(second.text.hasSuffix("size 24 80\r\n"), String(second.text.suffix(80)))
        }
        XCTAssertTrue(second.text.hasPrefix("\u{1b}[?1049h"), "the replay starts on the alternate screen")
        let shorter = try XCTUnwrap(second.text.range(of: "size 23 80"))
        XCTAssertNotNil(second.text.range(of: "size 24 80", range: shorter.upperBound..<second.text.endIndex))
    }
}
#endif
