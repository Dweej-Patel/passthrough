#if os(macOS)
import Foundation
import PassthroughCore
import XCTest
@testable import ShellHost

/// `historyList` stays a line a phone accepts, however long the history is.
final class ShellHistoryReplyTests: XCTestCase {
    private func entries(_ count: Int, titleLength: Int = 8) -> [ShellHistoryEntry] {
        // Newest first, as TranscriptStore.entries() returns them.
        (0..<count).map { i in
            ShellHistoryEntry(id: "s\(i)", title: String(repeating: "t", count: titleLength), phoneLabel: "Pixel",
                              startedAt: Double(count - i), endedAt: Double(count - i) + 1, exitStatus: 0, bytes: 1234)
        }
    }

    func testShortHistoryIsSentWhole() throws {
        let all = entries(3)
        XCTAssertEqual(ShellConnection.historyReply(all).history, all)
        XCTAssertEqual(ShellConnection.historyReply([]).history, [])
    }

    func testOnlyTheNewestEntriesAreSent() throws {
        let all = entries(2_000)
        let reply = ShellConnection.historyReply(all)
        XCTAssertEqual(reply.t, ShellEnvelope.historyList)
        XCTAssertEqual(reply.history, Array(all.prefix(ShellConnection.historyLimit)))
        XCTAssertLessThanOrEqual(try reply.encodedLine().count, RemoteShell.lineLimit)
    }

    func testOldestAreDroppedUntilTheLineFits() throws {
        // 500 entries of ~2 KB each would be ~1 MB: far over the limit.
        let all = entries(2_000, titleLength: 2_000)
        let reply = ShellConnection.historyReply(all)
        let sent = try XCTUnwrap(reply.history)
        XCTAssertLessThanOrEqual(try reply.encodedLine().count, RemoteShell.lineLimit)
        XCTAssertGreaterThan(sent.count, 50)
        XCTAssertLessThan(sent.count, ShellConnection.historyLimit)
        XCTAssertEqual(sent, Array(all.prefix(sent.count)), "the newest are kept")
        // One more would not have fit.
        var bigger = ShellEnvelope(t: ShellEnvelope.historyList)
        bigger.history = Array(all.prefix(sent.count + 1))
        XCTAssertGreaterThan(try bigger.encodedLine().count, RemoteShell.lineLimit)
    }
}
#endif
