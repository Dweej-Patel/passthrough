#if os(macOS)
import Foundation
import PassthroughCore
import XCTest
@testable import ShellHost

final class TranscriptStoreTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TranscriptStoreTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeWriter(_ store: TranscriptStore, id: String = "s1", at date: Date = Date(timeIntervalSince1970: 1_000)) throws -> TranscriptWriter {
        try store.begin(id: id, title: "zsh", phoneLabel: "Pixel", cols: 80, rows: 24, at: date)
    }

    func testRoundTripOutput() throws {
        let store = try TranscriptStore(directory: directory)
        let writer = try makeWriter(store)
        writer.append(Data("hello ".utf8), at: Date(timeIntervalSince1970: 1_001))
        writer.append(Data("world".utf8), at: Date(timeIntervalSince1970: 1_002))
        XCTAssertEqual(String(decoding: try store.output(of: "s1"), as: UTF8.self), "hello world")
    }

    func testSplitUTF8IsHeldUntilComplete() throws {
        let store = try TranscriptStore(directory: directory)
        let writer = try makeWriter(store)
        let euro = Array("€".utf8)
        writer.append(Data(euro[0..<2]), at: Date(timeIntervalSince1970: 1_001))
        writer.append(Data(euro[2..<3]), at: Date(timeIntervalSince1970: 1_002))
        XCTAssertEqual(String(decoding: try store.output(of: "s1"), as: UTF8.self), "€")
        let cast = try String(contentsOf: directory.appendingPathComponent("s1.cast"), encoding: .utf8)
        XCTAssertFalse(cast.contains("\u{FFFD}"))
    }

    func testIncompleteTailIsReplacedOnFinish() throws {
        let store = try TranscriptStore(directory: directory)
        let writer = try makeWriter(store)
        writer.append(Data(Array("€".utf8)[0..<2]), at: Date(timeIntervalSince1970: 1_001))
        writer.finish(exitStatus: 0, at: Date(timeIntervalSince1970: 1_002))
        XCTAssertEqual(String(decoding: try store.output(of: "s1"), as: UTF8.self), "\u{FFFD}")
    }

    func testHeaderIsAsciicastV2() throws {
        let store = try TranscriptStore(directory: directory)
        _ = try makeWriter(store)
        let cast = try String(contentsOf: directory.appendingPathComponent("s1.cast"), encoding: .utf8)
        let header = try JSONSerialization.jsonObject(with: Data(cast.split(separator: "\n")[0].utf8)) as? [String: Any]
        XCTAssertEqual(header?["version"] as? Int, 2)
        XCTAssertEqual(header?["width"] as? Int, 80)
        XCTAssertEqual(header?["height"] as? Int, 24)
        XCTAssertEqual(header?["timestamp"] as? Int, 1_000)
        XCTAssertEqual(header?["title"] as? String, "zsh")
    }

    func testEntriesNewestFirstWithExitStatus() throws {
        let store = try TranscriptStore(directory: directory)
        let first = try makeWriter(store, id: "a", at: Date(timeIntervalSince1970: 1_000))
        let second = try makeWriter(store, id: "b", at: Date(timeIntervalSince1970: 2_000))
        first.append(Data("x".utf8), at: Date(timeIntervalSince1970: 1_001))
        first.finish(exitStatus: 3, at: Date(timeIntervalSince1970: 1_500))
        second.finish(exitStatus: nil, at: Date(timeIntervalSince1970: 2_500))
        let entries = store.entries()
        XCTAssertEqual(entries.map(\.id), ["b", "a"])
        XCTAssertEqual(entries[1].exitStatus, 3)
        XCTAssertEqual(entries[1].endedAt, 1_500)
        XCTAssertEqual(entries[1].startedAt, 1_000)
        XCTAssertEqual(entries[1].title, "zsh")
        XCTAssertEqual(entries[1].phoneLabel, "Pixel")
        XCTAssertNil(entries[0].exitStatus)
        XCTAssertEqual(entries[0].endedAt, 2_500)
    }

    func testUnfinishedSessionHasNilEnd() throws {
        let store = try TranscriptStore(directory: directory)
        let writer = try makeWriter(store)
        writer.append(Data("abc".utf8), at: Date(timeIntervalSince1970: 1_001))
        let entry = try XCTUnwrap(store.entries().first)
        XCTAssertNil(entry.endedAt)
        XCTAssertNil(entry.exitStatus)
        XCTAssertGreaterThan(entry.bytes, 0)
    }

    func testPermissions() throws {
        let store = try TranscriptStore(directory: directory)
        let writer = try makeWriter(store)
        writer.finish(exitStatus: 0, at: Date(timeIntervalSince1970: 1_001))
        func mode(_ url: URL) throws -> Int {
            (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int) ?? -1
        }
        XCTAssertEqual(try mode(directory), 0o700)
        XCTAssertEqual(try mode(directory.appendingPathComponent("s1.cast")), 0o600)
        XCTAssertEqual(try mode(directory.appendingPathComponent("s1.json")), 0o600)
    }

    func testExistingFolderIsTightened() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o755])
        _ = try TranscriptStore(directory: directory)
        let mode = try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o700)
    }

    func testDeleteAndTotalBytes() throws {
        let store = try TranscriptStore(directory: directory)
        let a = try makeWriter(store, id: "a")
        let b = try makeWriter(store, id: "b")
        a.append(Data("one".utf8), at: Date(timeIntervalSince1970: 1_001))
        b.append(Data("two".utf8), at: Date(timeIntervalSince1970: 1_001))
        a.finish(exitStatus: 0, at: Date(timeIntervalSince1970: 1_002))
        b.finish(exitStatus: 0, at: Date(timeIntervalSince1970: 1_002))
        let both = store.totalBytes()
        XCTAssertGreaterThan(both, 0)
        store.delete(id: "a")
        XCTAssertEqual(store.entries().map(\.id), ["b"])
        XCTAssertLessThan(store.totalBytes(), both)
        store.deleteAll()
        XCTAssertTrue(store.entries().isEmpty)
        XCTAssertEqual(store.totalBytes(), 0)
    }

    func testDeleteFinishedKeepsLiveWriters() throws {
        let store = try TranscriptStore(directory: directory)
        let done = try makeWriter(store, id: "done")
        done.append(Data("x".utf8), at: Date(timeIntervalSince1970: 1_001))
        done.finish(exitStatus: 0, at: Date(timeIntervalSince1970: 1_002))
        let running = try makeWriter(store, id: "running", at: Date(timeIntervalSince1970: 2_000))
        store.deleteFinished()
        XCTAssertEqual(store.entries().map(\.id), ["running"])
        for ext in ["cast", "json"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("running.\(ext)").path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("done.\(ext)").path))
        }
        running.append(Data("still".utf8), at: Date(timeIntervalSince1970: 2_001))
        running.finish(exitStatus: 0, at: Date(timeIntervalSince1970: 2_002))
        XCTAssertEqual(String(decoding: try store.output(of: "running"), as: UTF8.self), "still")
        store.deleteFinished()
        XCTAssertTrue(store.entries().isEmpty)
    }

    func testWritesAfterDeleteRecreateNothing() throws {
        let store = try TranscriptStore(directory: directory)
        let a = try makeWriter(store, id: "a")
        let b = try makeWriter(store, id: "b")
        a.append(Data("x".utf8), at: Date(timeIntervalSince1970: 1_001))
        store.delete(id: "a")
        a.append(Data("y".utf8), at: Date(timeIntervalSince1970: 1_002))
        a.finish(exitStatus: 0, at: Date(timeIntervalSince1970: 1_003))
        XCTAssertEqual(store.entries().map(\.id), ["b"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("a.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("a.cast").path))

        store.deleteAll()
        b.append(Data("y".utf8), at: Date(timeIntervalSince1970: 1_002))
        b.finish(exitStatus: 0, at: Date(timeIntervalSince1970: 1_003))
        XCTAssertTrue(store.entries().isEmpty)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
    }

    func testPathTraversalIsRejected() throws {
        let store = try TranscriptStore(directory: directory)
        XCTAssertThrowsError(try store.output(of: "../x"))
        XCTAssertThrowsError(try store.output(of: "a/b"))
        XCTAssertThrowsError(try store.begin(id: "../x", title: "", phoneLabel: "", cols: 1, rows: 1, at: Date()))
        let outside = directory.deletingLastPathComponent().appendingPathComponent("victim-\(UUID().uuidString).json")
        try Data("x".utf8).write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }
        store.delete(id: "../" + outside.deletingPathExtension().lastPathComponent)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
    }

    func testEmptyAppendIsHarmless() throws {
        let store = try TranscriptStore(directory: directory)
        let writer = try makeWriter(store)
        writer.append(Data(), at: Date(timeIntervalSince1970: 1_001))
        XCTAssertEqual(try store.output(of: "s1").count, 0)
    }

    func testConcurrentAppends() throws {
        let store = try TranscriptStore(directory: directory)
        let writer = try makeWriter(store)
        DispatchQueue.concurrentPerform(iterations: 50) { _ in
            writer.append(Data("ab".utf8), at: Date(timeIntervalSince1970: 1_001))
        }
        XCTAssertEqual(try store.output(of: "s1").count, 100)
    }

    func testSetTitleRewritesEntryAndSurvivesFinish() throws {
        let store = try TranscriptStore(directory: directory)
        let writer = try makeWriter(store)
        writer.setTitle("ls -la")
        XCTAssertEqual(store.entries().first?.title, "ls -la")
        writer.finish(exitStatus: 0, at: Date(timeIntervalSince1970: 1_002))
        XCTAssertEqual(store.entries().first?.title, "ls -la")
    }

    func testSetTitleAfterDeleteRecreatesNothing() throws {
        let store = try TranscriptStore(directory: directory)
        let writer = try makeWriter(store)
        store.delete(id: "s1")
        writer.setTitle("late")
        XCTAssertTrue(store.entries().isEmpty)
    }

    /// A cast stops growing at its limit: one marker event, then nothing more,
    /// and the session's end is still recorded.
    func testCastIsCappedWithAMarker() throws {
        let limit: Int64 = 4096
        let store = try TranscriptStore(directory: directory, castLimit: limit)
        let writer = try makeWriter(store)
        for i in 0..<200 { writer.append(Data("line \(i) xxxxxxxxxxxxxxxx\r\n".utf8), at: Date(timeIntervalSince1970: 1_001)) }
        writer.append(Data("after-the-cap".utf8), at: Date(timeIntervalSince1970: 1_002))
        writer.finish(exitStatus: 7, at: Date(timeIntervalSince1970: 1_003))
        let cast = directory.appendingPathComponent("s1.cast")
        let size = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: cast.path)[.size] as? NSNumber).int64Value
        XCTAssertLessThanOrEqual(size, limit)
        let text = String(decoding: try store.output(of: "s1"), as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("line 0 "))
        XCTAssertTrue(text.hasSuffix("[transcript truncated]\r\n"))
        XCTAssertEqual(text.components(separatedBy: "[transcript truncated]").count, 2, "one marker")
        XCTAssertFalse(text.contains("after-the-cap"))
        let entry = try XCTUnwrap(store.entries().first)
        XCTAssertEqual(entry.exitStatus, 7)
        XCTAssertEqual(entry.endedAt, 1_003)
        XCTAssertEqual(entry.bytes, size)
    }

    /// A read returns the end of a long session, reading only the end of its file.
    func testTailReadIsBoundedOnALargeCast() throws {
        let store = try TranscriptStore(directory: directory)
        let writer = try makeWriter(store)
        // About 24 MiB of cast: 6000 events of 4 KiB.
        let filler = String(repeating: "x", count: 4086)
        for i in 0..<6000 {
            writer.append(Data(String(format: "%08d", i).utf8) + Data(filler.utf8) + Data("\r\n".utf8), at: Date(timeIntervalSince1970: 1_001))
        }
        writer.finish(exitStatus: 0, at: Date(timeIntervalSince1970: 1_002))
        let cast = directory.appendingPathComponent("s1.cast")
        let maxBytes = 1 << 20
        let (output, bytesRead) = try TranscriptStore.tail(of: cast, maxBytes: maxBytes)
        XCTAssertEqual(output.count, maxBytes)
        XCTAssertTrue(String(decoding: output, as: UTF8.self).hasSuffix("00005999" + filler + "\r\n"))
        // The end of the file, and back to the size restated at most `sizeCheckpoint` before it.
        XCTAssertLessThan(bytesRead, maxBytes + Int(TranscriptStore.sizeCheckpoint) + 2 * TranscriptStore.tailBlock,
                          "only the end of the file is read")
        let replay = try store.replay(of: "s1", maxBytes: maxBytes)
        XCTAssertEqual(replay.first, .resize(cols: 80, rows: 24), "the tail starts with the size it was drawn at")
        XCTAssertEqual(try store.output(of: "s1", maxBytes: maxBytes), output)
        // The default bound applies too.
        XCTAssertEqual(try store.output(of: "s1").count, TranscriptStore.readLimit)
    }

    /// A cut never starts inside a multi-byte character.
    func testTailStartsOnACharacter() throws {
        let store = try TranscriptStore(directory: directory)
        let writer = try makeWriter(store)
        writer.append(Data("€€€".utf8), at: Date(timeIntervalSince1970: 1_001))
        XCTAssertEqual(String(decoding: try store.output(of: "s1", maxBytes: 4), as: UTF8.self), "€")
    }

    // MARK: Sizes

    private func lines(_ id: String = "s1") throws -> [String] {
        try String(contentsOf: directory.appendingPathComponent("\(id).cast"), encoding: .utf8)
            .split(separator: "\n").map(String.init)
    }

    func testResizeIsAnAsciicastResizeEvent() throws {
        let store = try TranscriptStore(directory: directory)
        let writer = try makeWriter(store)
        writer.append(Data("a".utf8), at: Date(timeIntervalSince1970: 1_001))
        writer.resize(cols: 48, rows: 20, at: Date(timeIntervalSince1970: 1_002))
        writer.resize(cols: 48, rows: 20, at: Date(timeIntervalSince1970: 1_003))   // unchanged: not written
        writer.append(Data("b".utf8), at: Date(timeIntervalSince1970: 1_004))
        writer.finish(exitStatus: 0, at: Date(timeIntervalSince1970: 1_005))
        let events = try lines().dropFirst().map { try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [Any]) }
        XCTAssertEqual(events.map { $0[1] as? String }, ["o", "r", "o"])
        XCTAssertEqual(events[1][0] as? Double, 2)
        XCTAssertEqual(events[1][2] as? String, "48x20")
        XCTAssertEqual(try store.replay(of: "s1"), [
            .resize(cols: 80, rows: 24), .output(Data("a".utf8)), .resize(cols: 48, rows: 20), .output(Data("b".utf8)),
        ])
        XCTAssertEqual(String(decoding: try store.output(of: "s1"), as: UTF8.self), "ab")
        let entry = try XCTUnwrap(store.entries().first)
        XCTAssertEqual(entry.cols, 80)
        XCTAssertEqual(entry.rows, 24)
    }

    /// A character split across a resize is still whole in the replay.
    func testResizeInsideACharacterKeepsItWhole() throws {
        let store = try TranscriptStore(directory: directory)
        let writer = try makeWriter(store)
        let euro = Array("€".utf8)
        writer.append(Data(euro[0..<1]), at: Date(timeIntervalSince1970: 1_001))
        writer.resize(cols: 40, rows: 10, at: Date(timeIntervalSince1970: 1_002))
        writer.append(Data(euro[1..<3]), at: Date(timeIntervalSince1970: 1_003))
        // No output at the first size: only the second is kept.
        XCTAssertEqual(try store.replay(of: "s1"), [.resize(cols: 40, rows: 10), .output(Data("€".utf8))])
    }

    /// A tail that starts mid-file starts with the last size before the cut.
    func testTailStartsWithTheSizeInEffectAtTheCut() throws {
        let store = try TranscriptStore(directory: directory)
        let writer = try makeWriter(store)
        writer.append(Data("0123456789".utf8), at: Date(timeIntervalSince1970: 1_001))
        writer.resize(cols: 48, rows: 20, at: Date(timeIntervalSince1970: 1_002))
        writer.append(Data("abcdefghij".utf8), at: Date(timeIntervalSince1970: 1_003))
        writer.append(Data("ABCDEFGHIJ".utf8), at: Date(timeIntervalSince1970: 1_004))
        writer.resize(cols: 100, rows: 30, at: Date(timeIntervalSince1970: 1_005))
        writer.append(Data("xyz".utf8), at: Date(timeIntervalSince1970: 1_006))
        // Cut inside "abcdefghij": drawn at 48x20.
        XCTAssertEqual(try store.replay(of: "s1", maxBytes: 18), [
            .resize(cols: 48, rows: 20), .output(Data("fghijABCDEFGHIJ".utf8)),
            .resize(cols: 100, rows: 30), .output(Data("xyz".utf8)),
        ])
        // Cut inside the first output: the header's size.
        // (Resize lines have a budget of their own, also `maxBytes`: 31 bytes here.)
        XCTAssertEqual(try store.replay(of: "s1", maxBytes: 32), [
            .resize(cols: 80, rows: 24), .output(Data("123456789".utf8)), .resize(cols: 48, rows: 20),
            .output(Data("abcdefghijABCDEFGHIJ".utf8)), .resize(cols: 100, rows: 30), .output(Data("xyz".utf8)),
        ])
        // Only the last output: the last size.
        XCTAssertEqual(try store.replay(of: "s1", maxBytes: 3), [.resize(cols: 100, rows: 30), .output(Data("xyz".utf8))])
    }

    /// The size is restated every `sizeCheckpoint` bytes, so a tail read finds it close by.
    func testSizeIsRestatedAtCheckpoints() throws {
        let store = try TranscriptStore(directory: directory, sizeCheckpoint: 1_000)
        let writer = try makeWriter(store)
        writer.resize(cols: 48, rows: 20, at: Date(timeIntervalSince1970: 1_001))
        for _ in 0..<100 { writer.append(Data(String(repeating: "x", count: 100).utf8), at: Date(timeIntervalSince1970: 1_002)) }
        writer.finish(exitStatus: 0, at: Date(timeIntervalSince1970: 1_003))
        let sizes = try lines().filter { $0.contains(#""r""#) }
        XCTAssertGreaterThanOrEqual(sizes.count, 8)
        XCTAssertTrue(sizes.allSatisfy { $0.hasSuffix(#""48x20"]"#) })
        XCTAssertEqual(try store.replay(of: "s1", maxBytes: 150).first, .resize(cols: 48, rows: 20))
    }

    /// A cast from before resize events were recorded: the header's size throughout.
    func testCastWithoutResizeEventsUsesTheHeader() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let cast = """
        {"version":2,"width":48,"height":20,"timestamp":1000,"title":"zsh"}
        [0.5,"o","janeappleseed@Janes-MacBook-Pro16 ~ % "]
        [1.0,"o","python --v"]

        """
        try Data(cast.utf8).write(to: directory.appendingPathComponent("old.cast"))
        let store = try TranscriptStore(directory: directory)
        XCTAssertEqual(try store.replay(of: "old"), [
            .resize(cols: 48, rows: 20), .output(Data("janeappleseed@Janes-MacBook-Pro16 ~ % python --v".utf8)),
        ])
    }

    /// The cut lands inside the first output of a cast with no resize events:
    /// the read reaches the start of the file and takes the header's size from there.
    func testCutInsideTheFirstOutputUsesTheHeaderAtTheStart() throws {
        let store = try TranscriptStore(directory: directory)
        let writer = try makeWriter(store)
        writer.append(Data("0123456789".utf8), at: Date(timeIntervalSince1970: 1_001))
        writer.finish(exitStatus: 0, at: Date(timeIntervalSince1970: 1_002))
        let url = directory.appendingPathComponent("s1.cast")
        let (chunks, bytesRead) = try TranscriptStore.replay(of: url, maxBytes: 4)
        XCTAssertEqual(chunks, [.resize(cols: 80, rows: 24), .output(Data("6789".utf8))])
        let size = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber).intValue
        XCTAssertEqual(bytesRead, size, "read back to the header")
    }

    /// A large cast with no resize events: the search for the size at the cut
    /// gives up `sizeSearchLimit` past it and takes the header's, reading only so far.
    func testHeaderOnlyCastReadIsBounded() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("big.cast")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        try handle.write(contentsOf: Data(#"{"version":2,"width":48,"height":20,"timestamp":1000,"title":"zsh"}"#.utf8) + Data("\n".utf8))
        let line = try JSONSerialization.data(withJSONObject: [1.0, "o", String(repeating: "y", count: 4000)] as [Any]) + Data("\n".utf8)
        var block = Data()
        for _ in 0..<256 { block.append(line) }   // ~1 MiB
        for _ in 0..<24 { try handle.write(contentsOf: block) }
        try handle.close()
        let maxBytes = 1 << 20
        let (chunks, bytesRead) = try TranscriptStore.replay(of: url, maxBytes: maxBytes)
        XCTAssertEqual(chunks.first, .resize(cols: 48, rows: 20))
        XCTAssertEqual(chunks.count, 2)
        XCTAssertLessThan(bytesRead, maxBytes + TranscriptStore.sizeSearchLimit + 3 * TranscriptStore.tailBlock)
    }

    func testSizesAreClamped() throws {
        let store = try TranscriptStore(directory: directory)
        let writer = try store.begin(id: "s1", title: "zsh", phoneLabel: "Pixel", cols: 0, rows: 5000, at: Date(timeIntervalSince1970: 1_000))
        writer.append(Data("a".utf8), at: Date(timeIntervalSince1970: 1_001))
        writer.resize(cols: 5000, rows: 0, at: Date(timeIntervalSince1970: 1_002))
        writer.append(Data("b".utf8), at: Date(timeIntervalSince1970: 1_003))
        XCTAssertEqual(try store.replay(of: "s1"), [
            .resize(cols: 1, rows: 1000), .output(Data("a".utf8)), .resize(cols: 1000, rows: 1), .output(Data("b".utf8)),
        ])
    }

    /// Resizes with no output between them come back as the last one.
    func testConsecutiveResizesCoalesce() throws {
        let store = try TranscriptStore(directory: directory)
        let writer = try makeWriter(store)
        writer.append(Data("a".utf8), at: Date(timeIntervalSince1970: 1_001))
        for rows in 10..<20 { writer.resize(cols: 48, rows: rows, at: Date(timeIntervalSince1970: 1_002)) }
        writer.append(Data("b".utf8), at: Date(timeIntervalSince1970: 1_003))
        XCTAssertEqual(try store.replay(of: "s1"), [
            .resize(cols: 80, rows: 24), .output(Data("a".utf8)), .resize(cols: 48, rows: 19), .output(Data("b".utf8)),
        ])
    }

    /// Listing again picks up a changed entry and drops a deleted one.
    func testEntriesFollowChanges() throws {
        let store = try TranscriptStore(directory: directory)
        let a = try makeWriter(store, id: "a")
        _ = try makeWriter(store, id: "b", at: Date(timeIntervalSince1970: 2_000))
        XCTAssertEqual(store.entries().map(\.id), ["b", "a"])
        a.setTitle("renamed")
        a.append(Data("abc".utf8), at: Date(timeIntervalSince1970: 1_001))
        store.delete(id: "b")
        let entries = store.entries()
        XCTAssertEqual(entries.map(\.id), ["a"])
        XCTAssertEqual(entries.first?.title, "renamed")
        XCTAssertGreaterThan(entries.first?.bytes ?? 0, 0, "sizes are current even when the entry is not re-read")
    }
}
#endif
