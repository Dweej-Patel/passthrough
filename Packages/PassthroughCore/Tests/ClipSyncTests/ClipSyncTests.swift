import XCTest
@testable import ClipSync
@testable import PassthroughCore

/// Two in-memory byte streams wired back to back.
final class PipeStream: ByteStream, @unchecked Sendable {
    weak var peer: PipeStream?
    private let lock = NSLock()
    private var buffer = Data()
    private var finished = false
    private var dead = false
    private var waiting: ((Data?, Bool, Error?) -> Void, Int)?
    var onTerminated: (@Sendable (Error?) -> Void)?
    /// Everything this side sent, for tests that read the wire.
    let sent = Locked(Data())

    static func pair() -> (PipeStream, PipeStream) {
        let a = PipeStream(), b = PipeStream()
        a.peer = b; b.peer = a
        return (a, b)
    }

    func receive(maximumLength: Int, completion: @escaping @Sendable (Data?, Bool, Error?) -> Void) {
        lock.lock(); waiting = (completion, maximumLength); lock.unlock()
        pump()
    }

    func send(_ data: Data?, isComplete: Bool, completion: @escaping @Sendable (Error?) -> Void) {
        guard let peer, !dead else { completion(CancellationError()); return }
        sent.set(sent.get() + (data ?? Data()))
        peer.deliver(data ?? Data(), finished: isComplete)
        completion(nil)
    }

    func cancel() {
        dead = true
        let peer = self.peer
        DispatchQueue.global().async { peer?.onTerminated?(nil) }
    }

    private func deliver(_ data: Data, finished: Bool) {
        lock.lock(); buffer.append(data); if finished { self.finished = true }; lock.unlock()
        pump()
    }

    private func pump() {
        lock.lock()
        guard let (completion, max) = waiting else { lock.unlock(); return }
        if !buffer.isEmpty {
            let n = min(max, buffer.count)
            let chunk = buffer.prefix(n); buffer.removeSubrange(buffer.startIndex ..< buffer.startIndex + n)
            waiting = nil; lock.unlock()
            DispatchQueue.global().async { completion(Data(chunk), false, nil) }
        } else if finished {
            waiting = nil; lock.unlock()
            DispatchQueue.global().async { completion(nil, true, nil) }
        } else {
            lock.unlock()
        }
    }
}

final class ClipSyncWireTests: XCTestCase {
    func testMessagesRoundTrip() throws {
        let messages: [ClipSyncWire.Message] = [
            .hello(version: 1),
            .offer(.init(transfer: 7, kind: .drop, x: 100, y: 65535, count: 3, total: 1 << 40)),
            .item(transfer: 7, index: 2, .init(format: .file, size: 1234, name: "Fotos/été.jpg")),
            .data(transfer: 7, item: 2, bytes: Data([1, 2, 3])),
            .done(transfer: 7),
            .abandon(transfer: 8),
            .decline(transfer: 9, reason: .noRoom),
            .result(transfer: 10, status: .savedToDownloads),
        ]
        var reader = ClipSyncWire.Reader()
        var wire = Data()
        for m in messages { wire.append(ClipSyncWire.encode(m)) }
        // A byte at a time: messages split anywhere still come out whole.
        var out: [ClipSyncWire.Message] = []
        for b in wire { out += try reader.append(Data([b])) }
        XCTAssertEqual(out, messages)
    }

    func testFixedLayout() {
        // offer: type 2, length 21, transfer, kind, x, y, count, total.
        let bytes = ClipSyncWire.encode(.offer(.init(transfer: 1, kind: .clipboard, count: 2, total: 5)))
        XCTAssertEqual([UInt8](bytes), [2, 0, 0, 0, 21, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 2, 0, 0, 0, 0, 0, 0, 0, 5])
        let item = ClipSyncWire.encode(.item(transfer: 1, index: 0, .init(format: .text, size: 5)))
        XCTAssertEqual([UInt8](item), [8, 0, 0, 0, 19, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 5, 0, 0])
    }

    func testUnknownTypeIsSkippedAndOversizeEnds() throws {
        var reader = ClipSyncWire.Reader()
        var wire = Data([99, 0, 0, 0, 2, 1, 2])
        wire.append(ClipSyncWire.encode(.done(transfer: 3)))
        XCTAssertEqual(try reader.append(wire), [.unknown(type: 99), .done(transfer: 3)])
        var big = ClipSyncWire.Reader()
        XCTAssertThrowsError(try big.append(Data([3, 0, 0x20, 0, 0])))
    }

    func testNames() {
        for good in ["a", "a/b", "Fotos/été.jpg", "x y/z.txt", String(repeating: "a", count: 255)] {
            XCTAssertTrue(ClipSyncWire.isValidName(good), good)
        }
        // A combining mark after `/` makes one Character with it, but the file system still splits there.
        for bad in ["../\u{0301}x", "a/../\u{0301}b", "../\u{200D}x", "", "/a", "a/", "a//b", ".", "..", "a/../b", "a\\b", "C:x", "a\u{0}b", "a\nb", "a\u{85}b",
                    String(repeating: "a", count: 256), Array(repeating: "abcd", count: 300).joined(separator: "/")] {
            XCTAssertFalse(ClipSyncWire.isValidName(bad), bad)
        }
    }

    func testItemCheck() {
        let offer = ClipSyncWire.Offer(transfer: 1, kind: .drop, count: 4, total: 10)
        var check = ClipSyncWire.ItemCheck(offer)
        XCTAssertEqual(check.refusal(of: .init(format: .file, size: 1, name: "d/x"), index: 0), .badOffer, "folder first")
        XCTAssertNil(check.refusal(of: .init(format: .folder, size: 0, name: "D"), index: 0))
        XCTAssertEqual(check.refusal(of: .init(format: .file, size: 1, name: "x"), index: 2), .badOffer, "in order")
        XCTAssertNil(check.refusal(of: .init(format: .file, size: 4, name: "d/x"), index: 1), "case-insensitive folder")
        XCTAssertEqual(check.refusal(of: .init(format: .file, size: 1, name: "D/X"), index: 2), .badOffer, "same name")
        XCTAssertEqual(check.refusal(of: .init(format: .text, size: 1), index: 2), .badOffer, "files only")
        XCTAssertEqual(check.refusal(of: .init(format: .file, size: 7, name: "y"), index: 2), .badOffer, "past the total")
        XCTAssertNil(check.refusal(of: .init(format: .file, size: 6, name: "y"), index: 2))
        XCTAssertFalse(check.isComplete)
        XCTAssertEqual(check.refusal(of: .init(format: .folder, size: 1, name: "e"), index: 3), .badOffer, "folders are empty")

        var text = ClipSyncWire.ItemCheck(.init(transfer: 2, kind: .clipboard, count: 2, total: 2))
        XCTAssertNil(text.refusal(of: .init(format: .text, size: 1), index: 0))
        XCTAssertEqual(text.refusal(of: .init(format: .text, size: 1), index: 1), .badOffer, "one of each")

        var big = ClipSyncWire.ItemCheck(.init(transfer: 3, kind: .clipboard, count: 1, total: 600_000_000))
        XCTAssertEqual(big.refusal(of: .init(format: .file, size: 600_000_000, name: "f"), index: 0), .tooLarge)
        XCTAssertEqual(ClipSyncWire.refusal(of: .init(transfer: 4, kind: .clipboard, count: 10_001, total: 1)), .tooLarge)
        XCTAssertEqual(ClipSyncWire.refusal(of: .init(transfer: 4, kind: .drop, count: 1, total: 100), room: 99), .noRoom)
        XCTAssertNil(ClipSyncWire.refusal(of: .init(transfer: 4, kind: .drop, count: 50_000, total: 100)))
    }
}

final class ClipSyncSessionTests: XCTestCase {
    private var dirs: [URL] = []

    override func tearDown() {
        for dir in dirs { try? FileManager.default.removeItem(at: dir) }
    }

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("clipsync-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        dirs.append(dir)
        return dir
    }

    private final class Recorder: @unchecked Sendable {
        let lock = NSLock()
        var events: [ClipSyncSession.Event] = []
        private var handler: ((ClipSyncSession.Event) -> Void)?
        /// Set under the lock, as `add` reads it.
        var onEvent: ((ClipSyncSession.Event) -> Void)? {
            get { lock.lock(); defer { lock.unlock() }; return handler }
            set { lock.lock(); handler = newValue; lock.unlock() }
        }
        func add(_ e: ClipSyncSession.Event) { lock.lock(); events.append(e); let f = handler; lock.unlock(); f?(e) }
    }

    private func pair() throws -> (a: ClipSyncSession, b: ClipSyncSession, aEvents: Recorder, bEvents: Recorder) {
        let (sa, sb) = PipeStream.pair()
        let ra = Recorder(), rb = Recorder()
        let q = DispatchQueue(label: "events")
        let a = ClipSyncSession(stream: sa, staging: try tempDir(), eventQueue: q) { ra.add($0) }
        let b = ClipSyncSession(stream: sb, staging: try tempDir(), eventQueue: q) { rb.add($0) }
        a.start(); b.start()
        return (a, b, ra, rb)
    }

    /// Waits until what was received satisfies `until` (by default: anything at all).
    private func received(_ r: Recorder, until: @escaping ([ReceivedTransfer]) -> Bool = { !$0.isEmpty }) -> [ReceivedTransfer] {
        let done = expectation(description: "received")
        done.assertForOverFulfill = false
        r.onEvent = { _ in
            r.lock.lock()
            let got = r.events.compactMap { if case let .received(t) = $0 { t } else { nil } }
            r.lock.unlock()
            if until(got) { done.fulfill() }
        }
        r.add(.sent(transfer: 0))   // checks what came before the handler was set
        wait(for: [done], timeout: 10)
        r.lock.lock(); defer { r.lock.unlock() }
        return r.events.compactMap { if case let .received(t) = $0 { t } else { nil } }
    }

    func testClipboardText() throws {
        let (a, b, _, rb) = try pair(); defer { a.close(); b.close() }
        let html = Data("<b>hi</b>".utf8)
        a.send(ClipPayload(items: [.data(.text, Data("hi\r\n".utf8)), .data(.html, html)]), kind: .clipboard)
        let t = try XCTUnwrap(received(rb).first)
        XCTAssertEqual(t.kind, .clipboard)
        XCTAssertEqual(t.data(.text), Data("hi\r\n".utf8), "line endings untouched")
        XCTAssertEqual(t.data(.html), html)
        XCTAssertNil(t.folder)
    }

    func testFilesAndFoldersArriveWhole() throws {
        let src = try tempDir()
        let top = src.appendingPathComponent("Project", isDirectory: true)
        try FileManager.default.createDirectory(at: top.appendingPathComponent("empty"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: top.appendingPathComponent("sub"), withIntermediateDirectories: true)
        let big = Data((0..<700_000).map { UInt8($0 % 251) })   // spans several chunks
        try big.write(to: top.appendingPathComponent("sub/big.bin"))
        try Data("x".utf8).write(to: top.appendingPathComponent("a:b.txt"))   // a name the other side can't take as is
        try FileManager.default.createSymbolicLink(at: top.appendingPathComponent("link"), withDestinationURL: URL(fileURLWithPath: "/etc"))
        let loose = src.appendingPathComponent("loose.txt")
        try Data().write(to: loose)

        let payload = try ClipPayload.files([top, loose]).get()
        XCTAssertFalse(payload.items.contains { $0.name.contains("link") }, "links are left out")
        let (a, b, _, rb) = try pair(); defer { a.close(); b.close() }
        a.send(payload, kind: .drop, x: 10, y: 20)
        let t = try XCTUnwrap(received(rb).first)
        XCTAssertEqual(t.kind, .drop)
        XCTAssertEqual(t.x, 10)
        XCTAssertEqual(t.y, 20)
        let folder = try XCTUnwrap(t.folder)
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("Project/sub/big.bin")), big)
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("Project/a_b.txt")), Data("x".utf8))
        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("Project/empty").path, isDirectory: &isDir) && isDir.boolValue)
        XCTAssertEqual(Set(t.topLevel.map(\.lastPathComponent)), ["Project", "loose.txt"])
    }

    func testTooLargeStopsCounting() throws {
        let src = try tempDir()
        for i in 0..<5 { try Data(count: 100).write(to: src.appendingPathComponent("f\(i)")) }
        XCTAssertEqual(ClipPayload.files([src], maxBytes: 250).failureValue, .tooLarge)
        XCTAssertEqual(ClipPayload.files([src], maxItems: 3).failureValue, .tooLarge)
        XCTAssertNotNil(try? ClipPayload.files([src], maxBytes: 500).get())
    }

    func testNewerCopyWins() throws {
        let (a, b, _, rb) = try pair(); defer { a.close(); b.close() }
        a.send(ClipPayload(items: [.data(.text, Data(repeating: 65, count: 3 << 20))]), kind: .clipboard)
        a.send(ClipPayload(items: [.data(.text, Data("second".utf8))]), kind: .clipboard)
        // The first may land before the second is offered, or be abandoned for it; either way the second lands, last.
        let got = received(rb) { $0.contains { $0.data(.text) == Data("second".utf8) } }
        XCTAssertEqual(got.last?.data(.text), Data("second".utf8))
    }

    /// A path out of the folder is declined and nothing is written outside it.
    func testHostileNameDeclined() throws {
        let (sa, sb) = PipeStream.pair()
        let staging = try tempDir()
        let rb = Recorder()
        let b = ClipSyncSession(stream: sb, staging: staging, eventQueue: .global()) { rb.add($0) }
        b.start()
        let declined = expectation(description: "declined")
        let got = Locked(Data())
        func read() {
            sa.receive(maximumLength: 1 << 16) { data, _, _ in
                if let data { got.set(got.get() + data) }
                var r = ClipSyncWire.Reader()
                if (try? r.append(got.get()))?.contains(.decline(transfer: 1, reason: .badOffer)) == true { declined.fulfill(); return }
                read()
            }
        }
        read()
        var wire = Data()
        wire.append(ClipSyncWire.encode(.offer(.init(transfer: 1, kind: .drop, count: 1, total: 1))))
        wire.append(ClipSyncWire.encode(.item(transfer: 1, index: 0, .init(format: .file, size: 1, name: "../escape"))))
        wire.append(ClipSyncWire.encode(.data(transfer: 1, item: 0, bytes: Data([1]))))
        wire.append(ClipSyncWire.encode(.done(transfer: 1)))
        sa.send(wire, isComplete: false) { _ in }
        wait(for: [declined], timeout: 5)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.deletingLastPathComponent().appendingPathComponent("escape").path))
        rb.lock.lock(); defer { rb.lock.unlock() }
        XCTAssertFalse(rb.events.contains { if case .received = $0 { true } else { false } })
        b.close()
    }
}

extension ClipSyncSessionTests {
    /// Writes `messages` to a session from a raw peer and collects what it answers.
    private func raw(_ messages: [ClipSyncWire.Message], acceptsDrops: Bool = true,
                     until done: @escaping ([ClipSyncWire.Message]) -> Bool) throws -> [ClipSyncWire.Message] {
        let (sa, sb) = PipeStream.pair()
        let b = ClipSyncSession(stream: sb, staging: try tempDir(), acceptsDrops: acceptsDrops, eventQueue: .global()) { _ in }
        b.start()
        defer { b.close() }
        let finished = expectation(description: "answers")
        let got = Locked(Data())
        let answers = Locked<[ClipSyncWire.Message]>([])
        @Sendable func read() {
            sa.receive(maximumLength: 1 << 16) { data, _, _ in
                if let data { got.set(got.get() + data) }
                var r = ClipSyncWire.Reader()
                let all = (try? r.append(got.get())) ?? []
                answers.set(all)
                if done(all) { finished.fulfill(); return }
                read()
            }
        }
        read()
        sa.send(messages.reduce(into: Data()) { $0.append(ClipSyncWire.encode($1)) }, isComplete: false) { _ in }
        wait(for: [finished], timeout: 5)
        return answers.get()
    }

    /// An offer of a kind this side doesn't know is declined (4) and the copy coming meanwhile still lands.
    func testUnknownKindIsDeclinedWithoutTouchingTheRest() throws {
        var unknown = ClipSyncWire.encode(.offer(.init(transfer: 2, kind: .clipboard, count: 1, total: 1)))
        unknown[unknown.startIndex + 9] = 9   // the kind byte: no such kind
        var r = ClipSyncWire.Reader()
        XCTAssertEqual(try r.append(unknown), [.unknownOffer(transfer: 2)])

        let (sa, sb) = PipeStream.pair()
        let rb = Recorder()
        let b = ClipSyncSession(stream: sb, staging: try tempDir(), eventQueue: .global()) { rb.add($0) }
        b.start()
        defer { b.close() }
        var wire = ClipSyncWire.encode(.offer(.init(transfer: 1, kind: .clipboard, count: 1, total: 2)))
        wire.append(ClipSyncWire.encode(.item(transfer: 1, index: 0, .init(format: .text, size: 2))))
        wire.append(unknown)
        wire.append(ClipSyncWire.encode(.data(transfer: 1, item: 0, bytes: Data("hi".utf8))))
        wire.append(ClipSyncWire.encode(.done(transfer: 1)))
        sa.send(wire, isComplete: false) { _ in }
        XCTAssertEqual(received(rb).first?.data(.text), Data("hi".utf8))
    }

    func testAViewerDeclinesDrops() throws {
        let answers = try raw([.offer(.init(transfer: 1, kind: .drop, count: 1, total: 5))], acceptsDrops: false) {
            $0.contains(.decline(transfer: 1, reason: .badOffer))
        }
        XCTAssertTrue(answers.contains(.decline(transfer: 1, reason: .badOffer)))
    }

    func testOnlyFourTransfersAtOnce() throws {
        let offers = (1...5).map { ClipSyncWire.Message.offer(.init(transfer: UInt32($0), kind: .drop, count: 1, total: 1)) }
        let answers = try raw(offers) { $0.contains { if case .decline = $0 { true } else { false } } }
        XCTAssertEqual(answers.filter { if case .decline = $0 { true } else { false } }, [.decline(transfer: 5, reason: .noRoom)])
    }

    /// A file that grew after it was offered isn't sent cut short: the transfer is abandoned.
    func testAFileThatGrewIsAbandoned() throws {
        let src = try tempDir()
        let file = src.appendingPathComponent("grows.txt")
        try Data("abc".utf8).write(to: file)
        var payload = try ClipPayload.files([file]).get()
        try Data("abcdef".utf8).write(to: file)
        XCTAssertEqual(payload.items.first?.size, 3)
        payload = ClipPayload(items: payload.items)
        let (a, b, ra, rb) = try pair()
        defer { a.close(); b.close() }
        let gone = expectation(description: "abandoned")
        gone.assertForOverFulfill = false
        let abandoned: @Sendable (ClipSyncSession.Event) -> Bool = { if case .declined(_, .failed) = $0 { true } else { false } }
        ra.onEvent = { if abandoned($0) { gone.fulfill() } }
        a.send(payload, kind: .drop)
        ra.lock.lock(); let already = ra.events.contains(where: abandoned); ra.lock.unlock()
        if already { gone.fulfill() }
        wait(for: [gone], timeout: 5)
        rb.lock.lock(); defer { rb.lock.unlock() }
        XCTAssertFalse(rb.events.contains { if case .received = $0 { true } else { false } })
    }
}

extension ClipSyncSessionTests {
    /// Received files are quarantined, so Gatekeeper asks before one is opened.
    func testReceivedFilesAreQuarantined() throws {
        let src = try tempDir()
        let file = src.appendingPathComponent("tool.terminal")
        try Data("x".utf8).write(to: file)
        let (a, b, _, rb) = try pair(); defer { a.close(); b.close() }
        a.send(try ClipPayload.files([file]).get(), kind: .clipboard)
        let url = try XCTUnwrap(received(rb).first?.topLevel.first)
        let size = getxattr(url.path, "com.apple.quarantine", nil, 0, 0, 0)
        XCTAssertGreaterThan(size, 0, "no quarantine on \(url.path)")
    }

    /// A file listed for sending and swapped for a link since isn't read through the link.
    func testALinkSwappedInIsNotRead() throws {
        let src = try tempDir()
        let secret = src.appendingPathComponent("secret")
        try Data("key".utf8).write(to: secret)
        let file = src.appendingPathComponent("copied.txt")
        try Data("abc".utf8).write(to: file)
        XCTAssertNotNil(ClipSyncSession.openRegularFile(file))
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: secret)
        XCTAssertNil(ClipSyncSession.openRegularFile(file))
    }
}

#if canImport(AppKit)
import AppKit

final class MacClipboardTests: XCTestCase {
    private var pasteboard: NSPasteboard!

    override func setUp() { pasteboard = NSPasteboard(name: .init("passthrough.test.\(UUID().uuidString)")) }
    override func tearDown() { pasteboard.releaseGlobally() }

    func testSecretsAndOwnCopiesDontSync() {
        pasteboard.clearContents()
        pasteboard.setString("hunter2", forType: .string)
        pasteboard.setData(Data(), forType: .init("org.nspasteboard.ConcealedType"))
        if case .nothing = MacClipboard.snapshot(pasteboard) {} else { XCTFail("a concealed copy synced") }

        let transfer = ReceivedTransfer(transfer: 1, kind: .clipboard, x: 0, y: 0,
                                        items: [.init(format: .text, name: "", data: Data("from there".utf8), url: nil)], folder: nil)
        MacClipboard.write(transfer, to: pasteboard)
        XCTAssertEqual(pasteboard.string(forType: .string), "from there")
        if case .nothing = MacClipboard.snapshot(pasteboard) {} else { XCTFail("what came from the stream was sent back") }
    }

    func testTextSyncsAndTooLargeSaysWhich() {
        pasteboard.clearContents()
        pasteboard.setString("hello", forType: .string)
        guard case let .payload(p) = MacClipboard.snapshot(pasteboard) else { return XCTFail("plain text didn't sync") }
        XCTAssertEqual(p.items.first?.format, .text)

        pasteboard.clearContents()
        pasteboard.setData(Data(count: Int(ClipSyncWire.maxClipboardImage) + 1), forType: .png)
        guard case .tooLarge(files: false) = MacClipboard.snapshot(pasteboard) else { return XCTFail("a huge image wasn't too large") }
    }

    func testFoldersTheClipboardHolds() throws {
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent("st-\(UUID().uuidString)", isDirectory: true)
        let held = staging.appendingPathComponent("A", isDirectory: true)
        try FileManager.default.createDirectory(at: held, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        let file = held.appendingPathComponent("f.txt")
        try Data().write(to: file)
        pasteboard.clearContents()
        pasteboard.writeObjects([file as NSURL])
        XCTAssertEqual(MacClipboard.folders(within: staging, pasteboard), [held.standardizedFileURL])
    }
}
#endif

extension Result {
    var failureValue: Failure? { if case let .failure(e) = self { e } else { nil } }
}
