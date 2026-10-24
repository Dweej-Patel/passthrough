#if os(macOS)
import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox
import XCTest
import PassthroughCore
import ScreenClient
@testable import ScreenHost

final class ScreenVideoWireTests: XCTestCase {
    func testRoundTripInPieces() throws {
        let messages: [ScreenVideoWire.Message] = [
            .format(width: 1728, height: 1116, sps: Data([0x67, 1, 2]), pps: Data([0x68, 3])),
            .frame(number: 7, keyframe: true, data: Data(repeating: 5, count: 300)),
            .frame(number: 8, keyframe: false, data: Data()),
            .hello(maxWidth: 2868, maxHeight: 1320),
            .ack(number: 0xFFFF_FFFE),
            .pointer(x: 65535, y: 0, buttons: 5),
            .scroll(dx: -3, dy: 1200),
            .key(keysym: RFBKeys.left, modifiers: ScreenVideoWire.Modifiers.control.rawValue),
            .text("héllo 👋"),
            .clipboard(""),
            .keyframeRequest,
        ]
        let bytes = messages.reduce(Data()) { $0 + ScreenVideoWire.encode($1) }
        var reader = ScreenVideoWire.Reader()
        var decoded: [ScreenVideoWire.Message] = []
        // A byte at a time: nothing is assumed about how the stream splits.
        for byte in bytes { decoded += try reader.append(Data([byte])) }
        XCTAssertEqual(decoded, messages)
    }

    func testSkipsUnknownTypesAndRefusesHugeOnes() throws {
        var reader = ScreenVideoWire.Reader()
        let unknown = Data([200, 0, 0, 0, 2, 9, 9])
        XCTAssertEqual(try reader.append(unknown + ScreenVideoWire.encode(.keyframeRequest)), [.keyframeRequest])
        var other = ScreenVideoWire.Reader()
        XCTAssertThrowsError(try other.append(Data([2, 0x7F, 0, 0, 0])))
        var short = ScreenVideoWire.Reader()
        XCTAssertThrowsError(try short.append(Data([17, 0, 0, 0, 1, 0])), "an ack needs 4 bytes")
    }

    /// What the Mac reads from a phone has a cap per type, checked from the
    /// header before the payload is buffered.
    func testPhoneMessagesHaveSmallCaps() throws {
        func header(_ type: UInt8, _ length: Int) -> Data {
            Data([type, UInt8(length >> 24), UInt8(length >> 16 & 0xFF), UInt8(length >> 8 & 0xFF), UInt8(length & 0xFF)])
        }
        for (type, cap) in [(UInt8(21), ScreenVideoWire.maxTextPayload), (22, ScreenVideoWire.maxClipboardPayload),
                            (18, 64), (17, 64), (2, 64), (200, ScreenVideoWire.maxClipboardPayload)] {
            var fromPhone = ScreenVideoWire.Reader(from: .phone)
            XCTAssertThrowsError(try fromPhone.append(header(type, cap + 1)), "type \(type) over its cap")
            var ok = ScreenVideoWire.Reader(from: .phone)
            XCTAssertNoThrow(try ok.append(header(type, cap)), "type \(type) at its cap waits for the payload")
        }
        var fromMac = ScreenVideoWire.Reader()
        XCTAssertNoThrow(try fromMac.append(header(2, 8 << 20)), "frames from the Mac keep the large cap")
        let text = String(repeating: "é", count: 2048)
        var exact = ScreenVideoWire.Reader(from: .phone)
        XCTAssertEqual(try exact.append(ScreenVideoWire.encode(.text(text))), [.text(text)], "4 KiB of text is one message")
    }

    /// Long text is sent in pieces under the cap, split between characters.
    func testTextPieces() {
        XCTAssertEqual(ScreenVideoWire.textPieces(""), [])
        XCTAssertEqual(ScreenVideoWire.textPieces("hi"), ["hi"])
        let long = String(repeating: "ab👋", count: 3000)   // 6 bytes each: 18 000 bytes
        let pieces = ScreenVideoWire.textPieces(long)
        XCTAssertEqual(pieces.joined(), long)
        XCTAssertTrue(pieces.allSatisfy { $0.utf8.count <= ScreenVideoWire.maxTextPayload })
        XCTAssertEqual(pieces.count, 5)
        let family = "👨‍👩‍👧‍👦"   // one character of 25 bytes
        XCTAssertEqual(ScreenVideoWire.textPieces(family + "x", maxBytes: 10).joined(), family + "x")
        XCTAssertTrue(ScreenVideoWire.textPieces(family, maxBytes: 10).allSatisfy { $0.utf8.count <= 10 })
    }
}

final class TypingPacerTests: XCTestCase {
    func testTypingGoesAtOnceAndAFloodIsPaced() {
        var pacer = TypingPacer(rate: 1000, burst: 100, limit: 1000, now: 0)
        XCTAssertTrue(pacer.push(.text("hello")))
        XCTAssertEqual(pacer.take(now: 0), [.text("hello")], "typing is not held up")
        XCTAssertTrue(pacer.push(.text(String(repeating: "x", count: 250))))
        XCTAssertTrue(pacer.push(.key(keysym: RFBKeys.returnKey, modifiers: 0)))
        XCTAssertEqual(pacer.take(now: 0), [.text(String(repeating: "x", count: 95))], "what the bucket holds")
        XCTAssertNotNil(pacer.nextDelay)
        XCTAssertEqual(pacer.take(now: 0.05), [.text(String(repeating: "x", count: 50))])
        XCTAssertEqual(pacer.take(now: 1), [.text(String(repeating: "x", count: 100))], "never more than the burst")
        XCTAssertEqual(pacer.take(now: 2), [.text(String(repeating: "x", count: 5)), .key(keysym: RFBKeys.returnKey, modifiers: 0)],
                       "the key waited behind the text")
        XCTAssertTrue(pacer.isEmpty)
        XCTAssertNil(pacer.nextDelay)
    }

    func testTooMuchWaitingIsDropped() {
        var pacer = TypingPacer(rate: 10, burst: 10, limit: 100, now: 0)
        XCTAssertTrue(pacer.push(.text(String(repeating: "x", count: 100))))
        XCTAssertFalse(pacer.push(.text("y")), "past the limit")
        XCTAssertTrue(pacer.push(.key(keysym: 0x61, modifiers: 0)), "keys still queue")
        _ = pacer.take(now: 0)
        XCTAssertTrue(pacer.push(.text("y")), "room again once some went")
    }

    func testACharacterBiggerThanTheBucketStillGoes() {
        var pacer = TypingPacer(rate: 4, burst: 4, limit: 100, now: 0)
        XCTAssertTrue(pacer.push(.text("👨‍👩‍👧‍👦")))
        XCTAssertEqual(pacer.take(now: 0), [.text("👨‍👩‍👧‍👦")])
    }
}

final class ScreenVideoStreamerTests: XCTestCase {
    /// The real hardware encoder, frames from a fake capture: the phone's
    /// client gets decodable H.264, at most two frames ahead of its acks.
    func testFramesAreDecodableAndWaitForAcks() throws {
        // Low-latency H.264 needs the hardware encoder, which virtual Macs (CI) lack.
        guard (try? VideoEncoder(width: 640, height: 400, bitRate: 2_000_000)) != nil else {
            throw XCTSkip("no hardware H.264 encoder")
        }
        let capture = FakeCapture(width: 640, height: 400)
        let input = RecordingInput()
        let streamer = ScreenVideoStreamer(capture: capture, input: { _ in input })
        let (mac, phone) = MemoryPipe.pair()
        let ended = expectation(description: "ended")
        ended.isInverted = true
        streamer.start(stream: mac, initialBytes: Data()) { ended.fulfill() }

        let events = Locked<[ScreenVideoClient.Event]>([])
        let client = ScreenVideoClient(stream: phone, maxSide: 1000, queue: DispatchQueue(label: "test")) { event in
            events.set(events.get() + [event])
        }
        client.start()
        waitUntil("capture started at the phone's size") { capture.maxSide.get() == 1000 }

        // Five changes of the screen with nothing acked: only two frames come.
        for shade in 0..<5 { capture.push(shade: UInt8(40 * shade)) }
        waitUntil("two frames") { Self.frames(events.get()).count == 2 }
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertEqual(Self.frames(events.get()).count, 2, "no third frame before an ack")
        guard case let .size(width, height)? = events.get().first else { return XCTFail("size first") }
        XCTAssertEqual([width, height], [640, 400])

        // Showing the first lets the newest waiting one through (the ones in between are dropped).
        client.shown(1)
        waitUntil("a third frame") { Self.frames(events.get()).count == 3 }

        let samples = Self.frames(events.get()).map(\.0)
        XCTAssertEqual(Self.frames(events.get()).map(\.1), [1, 2, 3])
        XCTAssertEqual(try Self.decode(samples), 3, "every frame decodes")

        client.pointer(x: 0.5, y: 1, buttons: .left)
        client.key(RFBKeys.right, modifiers: [.control])
        client.text("hi")
        waitUntil("input arrived") { input.log.get().count == 3 }
        XCTAssertEqual(input.log.get(), ["pointer 32768 65535 1", "key \(RFBKeys.right) 8", "text hi"])

        streamer.stop()
        waitUntil("capture stopped") { capture.stopped.get() }
        wait(for: [ended], timeout: 0.2)
    }

    /// Acks are not enough: while the stream has not taken what was sent
    /// (a phone that acks but doesn't read), no new frame is encoded, and
    /// past the hard cap for the stall timeout the phone is dropped.
    func testAPhoneThatDoesNotReadIsNotBufferedFor() throws {
        guard (try? VideoEncoder(width: 640, height: 400, bitRate: 2_000_000)) != nil else {
            throw XCTSkip("no hardware H.264 encoder")
        }
        let capture = FakeCapture(width: 640, height: 400)
        let stalled = StalledStream()
        let limits = ScreenVideoStreamer.Limits(frames: 2, softBytes: 4 << 20, hardBytes: 1, stallTimeout: 0.5)
        let streamer = ScreenVideoStreamer(capture: capture, input: { _ in RecordingInput() }, limits: limits)
        let ended = expectation(description: "dropped")
        streamer.start(stream: stalled, initialBytes: ScreenVideoWire.encode(.hello(maxWidth: 640, maxHeight: 640))) { ended.fulfill() }
        waitUntil("capture started") { capture.maxSide.get() == 640 }
        for shade in 0..<6 {
            capture.push(shade: UInt8(30 * shade))
            stalled.deliver(ScreenVideoWire.encode(.ack(number: UInt32(shade + 1))))   // acks for frames it never read
            Thread.sleep(forTimeInterval: 0.05)
        }
        XCTAssertEqual(stalled.frames, 2, "two frames waiting in the stream, whatever the acks say")
        wait(for: [ended], timeout: 5)
        XCTAssertTrue(capture.stopped.get())
    }

    /// Text and keys reach the Mac in the order typed, a long paste included.
    func testTypingKeepsItsOrder() {
        let capture = FakeCapture(width: 320, height: 200)
        let input = RecordingInput()
        let streamer = ScreenVideoStreamer(capture: capture, input: { _ in input })
        let (mac, phone) = MemoryPipe.pair()
        streamer.start(stream: mac, initialBytes: ScreenVideoWire.encode(.hello(maxWidth: 320, maxHeight: 320))) {}
        addTeardownBlock { streamer.stop() }
        waitUntil("capture started") { capture.maxSide.get() == 320 }
        waitUntil("input ready") {
            phone.send(ScreenVideoWire.encode(.pointer(x: 0, y: 0, buttons: 0)), isComplete: false) { _ in }
            Thread.sleep(forTimeInterval: 0.02)
            return !input.log.get().isEmpty
        }
        let paste = String(repeating: "x", count: 12_000)
        for piece in ScreenVideoWire.textPieces(paste) { phone.send(ScreenVideoWire.encode(.text(piece)), isComplete: false) { _ in } }
        phone.send(ScreenVideoWire.encode(.key(keysym: RFBKeys.returnKey, modifiers: 0)), isComplete: false) { _ in }
        waitUntil("all typed", timeout: 10) { input.log.get().last == "key \(RFBKeys.returnKey) 0" }
        let typed = input.log.get().filter { $0.hasPrefix("text ") }.map { $0.dropFirst(5) }.joined()
        XCTAssertEqual(typed, paste)
    }

    /// The phone hanging up ends the stream (and so, upstream, the connection).
    func testThePhoneLeavingEndsIt() {
        let capture = FakeCapture(width: 320, height: 200)
        let streamer = ScreenVideoStreamer(capture: capture, input: { _ in RecordingInput() })
        let (mac, phone) = MemoryPipe.pair()
        let ended = expectation(description: "ended")
        streamer.start(stream: mac, initialBytes: ScreenVideoWire.encode(.hello(maxWidth: 320, maxHeight: 320))) { ended.fulfill() }
        waitUntil("capture started") { capture.maxSide.get() == 320 }
        phone.send(nil, isComplete: true) { _ in }
        wait(for: [ended], timeout: 5)
        XCTAssertTrue(capture.stopped.get())
    }

    func testKeyCodes() {
        XCTAssertEqual(InputInjector.keyCode(0x61)?.0, 0)            // a
        XCTAssertEqual(InputInjector.keyCode(0x41)?.shifted, true)    // A
        XCTAssertEqual(InputInjector.keyCode(0x40)?.0, 19)            // @ is shift-2
        XCTAssertEqual(InputInjector.keyCode(RFBKeys.left)?.2.contains(.maskSecondaryFn), true)
        XCTAssertEqual(InputInjector.keyCode(RFBKeys.function(11))?.0, 103)
        XCTAssertNil(InputInjector.keyCode(0x0100_00E9))
    }

    // MARK: Helpers

    private static func frames(_ events: [ScreenVideoClient.Event]) -> [(CMSampleBuffer, UInt32)] {
        events.compactMap { if case let .frame(sample, number) = $0 { (sample, number) } else { nil } }
    }

    /// Decodes in order with VideoToolbox; the number that decoded.
    private static func decode(_ samples: [CMSampleBuffer]) throws -> Int {
        guard let format = samples.first?.formatDescription else { return 0 }
        var session: VTDecompressionSession?
        XCTAssertEqual(VTDecompressionSessionCreate(allocator: nil, formatDescription: format, decoderSpecification: nil,
                                                    imageBufferAttributes: nil, outputCallback: nil, decompressionSessionOut: &session), noErr)
        guard let session else { return 0 }
        defer { VTDecompressionSessionInvalidate(session) }
        let count = Locked(0)
        for sample in samples {
            VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [], infoFlagsOut: nil) { status, _, image, _, _ in
                if status == noErr, image != nil { count.set(count.get() + 1) }
            }
        }
        VTDecompressionSessionWaitForAsynchronousFrames(session)
        return count.get()
    }

    private func waitUntil(_ message: String, timeout: TimeInterval = 5, _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { return XCTFail("timed out: \(message)") }
            Thread.sleep(forTimeInterval: 0.01)
        }
    }
}

/// Frames of one flat shade, pushed when a test says the screen changed.
private final class FakeCapture: FrameCapturing, @unchecked Sendable {
    let width: Int, height: Int
    let maxSide = Locked(0)
    let stopped = Locked(false)
    private let deliver = Locked<((CVPixelBuffer) -> Void)?>(nil)
    private let queue = Locked<DispatchQueue?>(nil)

    init(width: Int, height: Int) { self.width = width; self.height = height }

    func start(maxSide: Int, queue: DispatchQueue, frame: @escaping (CVPixelBuffer) -> Void,
               stopped: @escaping (Error?) -> Void) async throws -> (width: Int, height: Int, display: CGRect) {
        self.queue.set(queue)
        deliver.set(frame)
        self.maxSide.set(maxSide)
        return (width, height, CGRect(x: 0, y: 0, width: 1440, height: 900))
    }

    func stop() { stopped.set(true); deliver.set(nil) }

    func push(shade: UInt8) {
        var buffer: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, attributes, &buffer)
        guard let buffer else { return }
        CVPixelBufferLockBaseAddress(buffer, [])
        for plane in 0..<2 {
            let base = CVPixelBufferGetBaseAddressOfPlane(buffer, plane)!
            memset(base, Int32(plane == 0 ? shade : 128), CVPixelBufferGetBytesPerRowOfPlane(buffer, plane) * CVPixelBufferGetHeightOfPlane(buffer, plane))
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        guard let queue = queue.get(), let deliver = deliver.get() else { return }
        queue.sync { deliver(buffer) }
    }
}

/// A stream the phone writes to but never reads from: sends are taken and never complete.
private final class StalledStream: ByteStream, @unchecked Sendable {
    private let lock = NSLock()
    private var sent: [Data] = []
    private var inbox = Data()
    private var reader: (@Sendable (Data?, Bool, Error?) -> Void)?
    var onTerminated: (@Sendable (Error?) -> Void)?

    var frames: Int { lock.lock(); defer { lock.unlock() }; return sent.filter { $0.first == 2 }.count }

    func deliver(_ data: Data) {
        lock.lock()
        inbox.append(data)
        let reader = self.reader, chunk = inbox
        if reader != nil { self.reader = nil; inbox = Data() }
        lock.unlock()
        reader?(chunk, false, nil)
    }

    func receive(maximumLength: Int, completion: @escaping @Sendable (Data?, Bool, Error?) -> Void) {
        lock.lock()
        if inbox.isEmpty { reader = completion; lock.unlock(); return }
        let chunk = inbox
        inbox = Data()
        lock.unlock()
        completion(chunk, false, nil)
    }

    func send(_ data: Data?, isComplete: Bool, completion: @escaping @Sendable (Error?) -> Void) {
        lock.lock(); if let data { sent.append(data) }; lock.unlock()
    }

    func cancel() {}
}

private final class RecordingInput: InputSink, @unchecked Sendable {
    let log = Locked<[String]>([])
    func pointer(x: UInt16, y: UInt16, buttons: UInt8) { log.set(log.get() + ["pointer \(x) \(y) \(buttons)"]) }
    func scroll(dx: Int16, dy: Int16) { log.set(log.get() + ["scroll \(dx) \(dy)"]) }
    func key(keysym: UInt32, modifiers: UInt8) { log.set(log.get() + ["key \(keysym) \(modifiers)"]) }
    func text(_ text: String) { log.set(log.get() + ["text \(text)"]) }
    func clipboard(_ text: String) { log.set(log.get() + ["clipboard \(text)"]) }
}

/// Two `ByteStream`s joined in memory.
final class MemoryPipe: ByteStream, @unchecked Sendable {
    private let lock = NSLock()
    private var inbox = Data()
    private var ended = false
    private var waiting: [(Int, @Sendable (Data?, Bool, Error?) -> Void)] = []
    fileprivate weak var peer: MemoryPipe?
    var onTerminated: (@Sendable (Error?) -> Void)?

    static func pair() -> (MemoryPipe, MemoryPipe) {
        let a = MemoryPipe(), b = MemoryPipe()
        a.peer = b; b.peer = a
        return (a, b)
    }

    func receive(maximumLength: Int, completion: @escaping @Sendable (Data?, Bool, Error?) -> Void) {
        lock.lock(); waiting.append((maximumLength, completion)); lock.unlock()
        flush()
    }

    func send(_ data: Data?, isComplete: Bool, completion: @escaping @Sendable (Error?) -> Void) {
        peer?.deliver(data ?? Data(), end: isComplete)
        completion(nil)
    }

    func cancel() { peer?.deliver(Data(), end: true) }

    private func deliver(_ data: Data, end: Bool) {
        lock.lock(); inbox.append(data); if end { ended = true }; lock.unlock()
        flush()
    }

    private func flush() {
        while true {
            lock.lock()
            guard !waiting.isEmpty, !inbox.isEmpty || ended else { lock.unlock(); return }
            let (maximum, completion) = waiting.removeFirst()
            let chunk = inbox.prefix(maximum)
            inbox.removeFirst(chunk.count)
            let done = ended && inbox.isEmpty
            lock.unlock()
            DispatchQueue.global().async { completion(chunk.isEmpty ? nil : Data(chunk), done, nil) }
        }
    }
}
#endif
