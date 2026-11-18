#if os(macOS)
import CoreMedia
import CoreVideo
import Foundation
import ImageIO
import VideoToolbox
import XCTest
import PassthroughCore
import ScreenClient
@testable import ScreenHost

final class ScreenVideoWireTests: XCTestCase {
    func testRoundTripInPieces() throws {
        let messages: [ScreenVideoWire.Message] = [
            .format(codec: .h264, width: 1728, height: 1116, parameterSets: [Data([0x67, 1, 2]), Data([0x68, 3])]),
            .format(codec: .hevc, width: 1206, height: 2622, parameterSets: [Data([0x40, 1]), Data([0x42, 2]), Data([0x44, 3])]),
            .frame(number: 7, keyframe: true, data: Data(repeating: 5, count: 300)),
            .frame(number: 8, keyframe: false, data: Data()),
            .hello(.init(width: 2868, height: 1320, fit: .mac, codecs: .h264)),
            .hello(.init(width: 1206, height: 2622, fit: .device, codecs: [.h264, .hevc])),
            .hello(.init(width: 2752, height: 2064, fit: .device, codecs: .h264, fps: 120, quality: .fast, space: 125)),
            .viewers([]),
            .viewers(["iPad Pro", "Dweej’s iPhone 👋"]),
            .movedAway(to: "iPad Pro"),
            .useHere,
            .gesture(.magnify, phase: .began, value: 0),
            .gesture(.magnify, phase: .changed, value: 0.0125),
            .gesture(.rotate, phase: .changed, value: -12.5),
            .gesture(.rotate, phase: .ended, value: 0),
            .fitted(.device),
            .fitted(.mac),
            .cursor(x: 1, y: 65535, visible: true),
            .cursor(x: 0, y: 0, visible: false),
            .cursorShape(width: 17, height: 23, hotX: 4, hotY: 0, png: Data([0x89, 0x50, 0x4E, 0x47])),
            .ack(number: 0xFFFF_FFFE),
            .pointer(x: 65535, y: 0, buttons: 5),
            .scroll(dx: -3, dy: 1200),
            .key(keysym: RFBKeys.left, modifiers: ScreenVideoWire.Modifiers.control.rawValue),
            .text("héllo 👋"),
            .clipboard(""),
            .keyframeRequest,
            .copy,
            .copied(.text("copié ✂︎")),
            .copied(.text("")),
            .copied(.nothing),
            .copied(.tooLong),
            .copied(.notText),
            .curtain(true),
            .curtain(false),
            .curtained(true),
            .curtained(false),
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
        var copiedFromMac = ScreenVideoWire.Reader()
        XCTAssertThrowsError(try copiedFromMac.append(header(3, ScreenVideoWire.maxClipboardPayload + 2)),
                             "what the Mac copied is held to what a phone may paste")
        var copiedAtCap = ScreenVideoWire.Reader()
        XCTAssertNoThrow(try copiedAtCap.append(header(3, ScreenVideoWire.maxClipboardPayload + 1)))
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

final class StreamPacerTests: XCTestCase {
    /// Before any ack two frames go; after, as many as fit in the shortest trip.
    func testWindowFitsTheShortestRoundTrip() {
        var pacer = StreamPacer(maxBitRate: 8_000_000)
        XCTAssertEqual(pacer.window, 2)
        pacer.sent(1, keyframe: true, at: 0)
        pacer.acked(1, at: 0.010)
        XCTAssertEqual(pacer.window, 2, "nearby: 10 ms is under a frame")
        pacer = StreamPacer(maxBitRate: 8_000_000)
        pacer.sent(1, keyframe: false, at: 0)
        pacer.acked(1, at: 0.100)
        XCTAssertEqual(pacer.window, 7, "100 ms away: six frames' time, and one")
        pacer.sent(2, keyframe: false, at: 1)
        pacer.acked(2, at: 1.400)
        XCTAssertEqual(pacer.window, 7, "a trip that queued doesn't widen it")
        pacer.sent(3, keyframe: false, at: 20)
        pacer.acked(3, at: 21)
        XCTAssertEqual(pacer.window, StreamPacer.maxWindow, "old trips are forgotten, and it never goes past the cap")
    }

    /// Acks lagging behind the shortest trip cut the bitrate, once a round trip;
    /// prompt ones bring it back up slowly, never past the top.
    func testBitrateFollowsTheLag() {
        var pacer = StreamPacer(maxBitRate: 8_000_000)
        var time: TimeInterval = 0, number: UInt32 = 0
        func frame(rtt: TimeInterval, keyframe: Bool = false) {
            number += 1
            pacer.sent(number, keyframe: keyframe, at: time)
            pacer.acked(number, at: time + rtt)
            time += 1.0 / 30
        }
        for _ in 0..<10 { frame(rtt: 0.05) }
        XCTAssertEqual(pacer.bitRate, 8_000_000, "steady: nothing to change")
        for _ in 0..<30 { frame(rtt: 0.4) }
        let cut = pacer.bitRate
        XCTAssertLessThan(cut, 3_000_000, "a queue building: cut hard")
        XCTAssertGreaterThanOrEqual(cut, StreamPacer.minBitRate)
        for _ in 0..<30 { frame(rtt: 2, keyframe: true) }
        XCTAssertEqual(pacer.bitRate, cut, "keyframes are slow anyway and don't count")
        for _ in 0..<600 { frame(rtt: 0.05) }
        XCTAssertGreaterThan(pacer.bitRate, cut, "room again: back up")
        XCTAssertLessThanOrEqual(pacer.bitRate, 8_000_000)
        for _ in 0..<3000 { frame(rtt: 0.05) }
        XCTAssertEqual(pacer.bitRate, 8_000_000, "up to the top and no further")
    }

    func testANewSizeKeepsTheShare() {
        var pacer = StreamPacer(maxBitRate: 8_000_000)
        var time: TimeInterval = 0
        for number in UInt32(1)...40 {
            pacer.sent(number, keyframe: false, at: time)
            pacer.acked(number, at: time + (number < 5 ? 0.02 : 0.5))
            time += 0.05
        }
        let share = Double(pacer.bitRate) / 8_000_000
        XCTAssertLessThan(share, 1)
        pacer.setMaxBitRate(16_000_000)
        XCTAssertEqual(Double(pacer.bitRate) / 16_000_000, share, accuracy: 0.01)
    }

    /// A bitrate too low for the size shrinks the picture after a while, a step
    /// at a time, not more often than `rescaleGap`; enough again grows it back.
    func testThePictureShrinksOnASlowLinkAndGrowsBack() {
        var pacer = StreamPacer(maxBitRate: 8_000_000)
        pacer.setProfile(.of(.smooth), fps: 60)
        var time: TimeInterval = 0, number: UInt32 = 0
        var changes: [(TimeInterval, Double)] = []
        func run(for seconds: TimeInterval, rtt: TimeInterval) {
            let end = time + seconds
            while time < end {
                number += 1
                pacer.sent(number, keyframe: false, at: time)
                pacer.acked(number, at: time + rtt)
                if let scale = pacer.rescale(at: time + rtt) { changes.append((time, scale)) }
                time += 1.0 / 30
            }
        }
        run(for: 3, rtt: 0.05)
        XCTAssertTrue(changes.isEmpty, "a good link keeps the full size")
        run(for: 1.5, rtt: 0.6)   // a queue: the bitrate is cut hard
        XCTAssertLessThan(Double(pacer.bitRate) / 8_000_000, pacer.profile.shrinkBelow)
        run(for: 1, rtt: 0.6)
        XCTAssertTrue(changes.isEmpty, "not at once")
        run(for: 2, rtt: 0.6)
        XCTAssertEqual(changes.map(\.1), [0.75], "then smaller")
        run(for: 3, rtt: 0.6)
        XCTAssertEqual(changes.map(\.1), [0.75], "not again within the gap")
        run(for: 10, rtt: 0.6)
        XCTAssertEqual(changes.map(\.1), [0.75, 0.5], "and smaller still, but no further")
        run(for: 120, rtt: 0.05)   // room again: the bitrate climbs, then the size
        XCTAssertEqual(changes.map(\.1), [0.75, 0.5, 0.75, 1])
        XCTAssertEqual(pacer.scale, 1)
        for (a, b) in zip(changes, changes.dropFirst()) {
            XCTAssertGreaterThanOrEqual(b.0 - a.0, StreamPacer.rescaleGap - 0.1)
        }
    }

    /// An ack for a frame never sent (or already acked) changes nothing.
    func testUnknownAcksAreIgnored() {
        var pacer = StreamPacer(maxBitRate: 8_000_000)
        XCTAssertFalse(pacer.acked(5, at: 1))
        XCTAssertNil(pacer.minRTT)
        pacer.sent(1, keyframe: false, at: 0)
        pacer.sent(2, keyframe: false, at: 0.01)
        pacer.acked(2, at: 0.05)
        XCTAssertFalse(pacer.acked(1, at: 0.06), "done with when 2 was acked")
        XCTAssertEqual(pacer.minRTT ?? 0, 0.04, accuracy: 0.0001)
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

    /// Keys cost no bytes, but count: behind text that waits, a phone sending
    /// keys without end gets only `itemLimit` of them queued.
    func testKeysBehindWaitingTextAreCapped() {
        var pacer = TypingPacer(rate: 10, burst: 10, limit: 1000, itemLimit: 5, now: 0)
        XCTAssertTrue(pacer.push(.text(String(repeating: "x", count: 30))))
        _ = pacer.take(now: 0)
        for k in 0..<4 { XCTAssertTrue(pacer.push(.key(keysym: UInt32(k), modifiers: 0))) }
        XCTAssertFalse(pacer.push(.key(keysym: 99, modifiers: 0)), "past the item limit")
        XCTAssertFalse(pacer.push(.text("y")), "text too")
        XCTAssertEqual(pacer.count, 5)
        XCTAssertEqual(pacer.take(now: 1), [.text(String(repeating: "x", count: 10))])
        XCTAssertEqual(pacer.take(now: 2), [.text(String(repeating: "x", count: 10))] + (0..<4).map { .key(keysym: UInt32($0), modifiers: 0) },
                       "in order, the keys behind the text")
        XCTAssertTrue(pacer.isEmpty)
        XCTAssertTrue(pacer.push(.key(keysym: 99, modifiers: 0)), "room again")
    }

    /// Many items, pushed and taken in turns across the queue's compaction:
    /// each comes out once, in order.
    func testLongQueueDrainsInOrder() {
        var pacer = TypingPacer(rate: 1, burst: 1, limit: 1 << 20, itemLimit: 10_000, now: 0)
        var expected: [TypingPacer.Item] = [], taken: [TypingPacer.Item] = []
        var now: TimeInterval = 0
        for round in 0..<20 {
            for k in 0..<500 {
                let item: TypingPacer.Item = k % 50 == 0 ? .text("a") : .key(keysym: UInt32(round * 1000 + k), modifiers: 0)
                XCTAssertTrue(pacer.push(item))
                expected.append(item)
            }
            now += 0.5
            taken += pacer.take(now: now)
        }
        while !pacer.isEmpty {
            now += 1
            taken += pacer.take(now: now)
        }
        XCTAssertEqual(taken, expected)
        XCTAssertEqual(pacer.count, 0)
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
        try framesAreDecodable(codecs: .h264, expect: kCMVideoCodecType_H264)
    }

    /// A phone that decodes HEVC gets HEVC, just as decodable.
    func testHEVCForAPhoneThatDecodesIt() throws {
        guard (try? VideoEncoder(codec: .hevc, width: 640, height: 400, bitRate: 2_000_000)) != nil else {
            throw XCTSkip("no hardware HEVC encoder")
        }
        try framesAreDecodable(codecs: [.h264, .hevc], expect: kCMVideoCodecType_HEVC)
    }

    private func framesAreDecodable(codecs: ScreenVideoWire.Codecs, expect codecType: CMVideoCodecType) throws {
        // Low-latency H.264 needs the hardware encoder, which virtual Macs (CI) lack.
        guard (try? VideoEncoder(width: 640, height: 400, bitRate: 2_000_000)) != nil else {
            throw XCTSkip("no hardware H.264 encoder")
        }
        let capture = FakeCapture(width: 640, height: 400)
        let input = RecordingInput()
        let streamer = ScreenVideoStreamer(capture: { capture }, input: { _ in input })
        let (mac, phone) = MemoryPipe.pair()
        let ended = expectation(description: "ended")
        ended.isInverted = true
        streamer.start(stream: mac, initialBytes: Data()) { ended.fulfill() }

        let events = Locked<[ScreenVideoClient.Event]>([])
        let client = ScreenVideoClient(stream: phone, layout: .init(width: 1000, height: 1000, fit: .mac), codecs: codecs,
                                       queue: DispatchQueue(label: "test")) { event in
            events.set(events.get() + [event])
        }
        client.start()
        waitUntil("capture started at the phone's size") { capture.maxSide.get() == 1000 }

        // Five changes of the screen with nothing acked: only two frames come.
        for shade in 0..<5 { capture.push(shade: UInt8(40 * shade)) }
        waitUntil("two frames") { Self.frames(events.get()).count == 2 }
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertEqual(Self.frames(events.get()).count, 2, "no third frame before an ack")
        guard case .fitted(.mac)? = events.get().first else { return XCTFail("what it shows first") }
        guard case let .size(width, height)? = events.get().dropFirst().first else { return XCTFail("then its size") }
        XCTAssertEqual([width, height], [640, 400])

        // Showing the first lets the newest waiting one through (the ones in between are dropped).
        client.shown(1)
        waitUntil("a third frame") { Self.frames(events.get()).count == 3 }

        let samples = Self.frames(events.get()).map(\.0)
        XCTAssertEqual(Self.frames(events.get()).map(\.1), [1, 2, 3])
        XCTAssertEqual(samples.first?.formatDescription.map(CMFormatDescriptionGetMediaSubType), codecType)
        XCTAssertEqual(try Self.decode(samples), 3, "every frame decodes")

        client.pointer(x: 0.5, y: 1, buttons: .left)
        client.key(RFBKeys.right, modifiers: [.control])
        client.text("hi")
        client.gesture(.magnify, phase: .changed, value: 0.25)
        client.gesture(.rotate, phase: .ended, value: 0)
        waitUntil("input arrived") { input.log.get().count == 5 }
        XCTAssertEqual(input.log.get(), ["pointer 32768 65535 1", "key \(RFBKeys.right) 8", "text hi",
                                         "gesture magnify changed 0.25", "gesture rotate ended 0.0"])

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
        let streamer = ScreenVideoStreamer(capture: { capture }, input: { _ in RecordingInput() }, limits: limits)
        let ended = expectation(description: "dropped")
        streamer.start(stream: stalled, initialBytes: ScreenVideoWire.encode(.hello(.init(width: 640, height: 640, fit: .mac, codecs: .h264)))) { ended.fulfill() }
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
        let streamer = ScreenVideoStreamer(capture: { capture }, input: { _ in input })
        let (mac, phone) = MemoryPipe.pair()
        streamer.start(stream: mac, initialBytes: ScreenVideoWire.encode(.hello(.init(width: 320, height: 320, fit: .mac, codecs: .h264)))) {}
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

    /// Copy: the Mac presses ⌘C and answers with what it copied; a clipboard
    /// that didn't change is `nothing`, never what was on it before.
    func testCopySendsOnlyWhatItsCommandCCopied() {
        let capture = FakeCapture(width: 320, height: 200)
        let input = RecordingInput()
        input.clipboard = (count: 5, text: "a password copied earlier")
        var limits = ScreenVideoStreamer.Limits()
        limits.copyTimeout = 0.3
        let streamer = ScreenVideoStreamer(capture: { capture }, input: { _ in input }, limits: limits)
        let (mac, phone) = MemoryPipe.pair()
        streamer.start(stream: mac, initialBytes: ScreenVideoWire.encode(.hello(.init(width: 320, height: 320, fit: .mac, codecs: .h264)))) {}
        addTeardownBlock { streamer.stop() }
        let events = Locked<[ScreenVideoClient.Event]>([])
        let client = ScreenVideoClient(stream: phone, maxSide: 320, queue: DispatchQueue(label: "test")) { event in
            events.set(events.get() + [event])
        }
        client.start()
        waitUntil("capture started") { capture.maxSide.get() == 320 }
        waitUntil("input ready") {
            client.pointer(x: 0, y: 0, buttons: [])
            Thread.sleep(forTimeInterval: 0.02)
            return !input.log.get().isEmpty
        }

        // Nothing selected: ⌘C changes nothing, so the old clipboard stays on the Mac.
        client.copySelection()
        waitUntil("answered") { Self.copies(events.get()).count == 1 }
        XCTAssertEqual(Self.copies(events.get()), [.nothing])
        XCTAssertTrue(input.log.get().contains("key 99 1"), "⌘C pressed")

        // Something selected: ⌘C copies it, and that is the answer.
        input.copies = "the selection"
        client.copySelection()
        waitUntil("answered again") { Self.copies(events.get()).count == 2 }
        XCTAssertEqual(Self.copies(events.get()).last, .text("the selection"))

        input.copies = String(repeating: "x", count: ScreenVideoWire.maxClipboardPayload + 1)
        client.copySelection()
        waitUntil("answered a third time") { Self.copies(events.get()).count == 3 }
        XCTAssertEqual(Self.copies(events.get()).last, .tooLong)

        // A copy while one is unanswered is answered too (nothing, at once), so every copy gets one answer.
        input.copies = "again"
        client.copySelection()
        client.copySelection()
        waitUntil("both answered") { Self.copies(events.get()).count == 5 }
        XCTAssertEqual(Self.copies(events.get()).suffix(2), [.nothing, .text("again")])
    }

    /// A changed clipboard that isn't this Mac's own copy, or is empty, answers nothing.
    func testCopyResults() {
        XCTAssertEqual(ScreenVideoStreamer.copyResult(.text("hi")), .text("hi"))
        XCTAssertEqual(ScreenVideoStreamer.copyResult(.text("")), .nothing)
        XCTAssertEqual(ScreenVideoStreamer.copyResult(.elsewhere), .nothing)
        XCTAssertEqual(ScreenVideoStreamer.copyResult(.notText), .notText)
        XCTAssertEqual(ScreenVideoStreamer.copyResult(.text(String(repeating: "é", count: ScreenVideoWire.maxClipboardPayload / 2))),
                       .text(String(repeating: "é", count: ScreenVideoWire.maxClipboardPayload / 2)))
        XCTAssertEqual(ScreenVideoStreamer.copyResult(.text(String(repeating: "x", count: ScreenVideoWire.maxClipboardPayload + 1))), .tooLong)
    }

    /// The phone takes the Mac's copies only as answers: one sent unasked is dropped.
    func testTheClientIgnoresCopiesItDidNotAskFor() {
        let (mac, phone) = MemoryPipe.pair()
        let events = Locked<[ScreenVideoClient.Event]>([])
        let client = ScreenVideoClient(stream: phone, maxSide: 320, queue: DispatchQueue(label: "test")) { event in
            events.set(events.get() + [event])
        }
        client.start()
        let heard = Locked<[ScreenVideoWire.Message]>([])
        func read() {
            mac.receive(maximumLength: 1 << 16) { data, _, _ in
                var reader = ScreenVideoWire.Reader(from: .phone)
                heard.set(heard.get() + ((try? reader.append(data ?? Data())) ?? []))
                read()
            }
        }
        read()
        waitUntil("hello") { !heard.get().isEmpty }
        Thread.sleep(forTimeInterval: 0.1)   // the client reading
        mac.send(ScreenVideoWire.encode(.copied(.text("pushed"))), isComplete: false) { _ in }
        Thread.sleep(forTimeInterval: 0.2)
        client.copySelection()
        waitUntil("asked") { heard.get().contains(.copy) }
        mac.send(ScreenVideoWire.encode(.copied(.text("answer"))), isComplete: false) { _ in }
        mac.send(ScreenVideoWire.encode(.copied(.text("pushed again"))), isComplete: false) { _ in }
        waitUntil("answer arrived") { !Self.copies(events.get()).isEmpty }
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertEqual(Self.copies(events.get()), [.text("answer")])
        client.close()
    }

    private static func copies(_ events: [ScreenVideoClient.Event]) -> [ScreenVideoWire.CopyResult] {
        events.compactMap { if case let .copied(result) = $0 { result } else { nil } }
    }

    /// A phone hides the Mac's displays and shows them again; the Mac says what they are each time,
    /// also when it couldn't hide them.
    func testTheCurtainIsAskedForAndAnswered() {
        let capture = FakeCapture(width: 320, height: 200)
        let streamer = ScreenVideoStreamer(capture: { capture }, input: { _ in RecordingInput() })
        let (mac, phone) = MemoryPipe.pair()
        // Asked before capture is up: it waits for it.
        streamer.start(stream: mac, initialBytes: ScreenVideoWire.encode(.hello(.init(width: 320, height: 320, fit: .mac, codecs: .h264)))
                       + ScreenVideoWire.encode(.curtain(true))) {}
        addTeardownBlock { streamer.stop() }
        let events = Locked<[ScreenVideoClient.Event]>([])
        let client = ScreenVideoClient(stream: phone, maxSide: 320, queue: DispatchQueue(label: "test")) { event in
            events.set(events.get() + [event])
        }
        client.start()
        func answers() -> [Bool] { events.get().compactMap { if case let .curtained(hidden) = $0 { return hidden } else { return nil } } }
        waitUntil("hidden") { answers() == [true] }
        client.curtain(false)
        waitUntil("shown") { answers() == [true, false] }
        capture.canHide.set(false)
        client.curtain(true)
        waitUntil("couldn't hide") { answers() == [true, false, false] }
        XCTAssertEqual(capture.curtains.get(), [true, false, true])
    }

    /// A screen pass's view (another Mac's) may not hide the Mac's displays:
    /// its curtain is refused, and said so, and nothing is hidden.
    func testARestrictedViewCantHideTheDisplays() {
        let capture = FakeCapture(width: 320, height: 200)
        let streamer = ScreenVideoStreamer(capture: { capture }, input: { _ in RecordingInput() }, restricted: true)
        let (mac, phone) = MemoryPipe.pair()
        streamer.start(stream: mac, initialBytes: ScreenVideoWire.encode(.hello(.init(width: 320, height: 320, fit: .mac, codecs: .h264)))
                       + ScreenVideoWire.encode(.curtain(true))) {}
        addTeardownBlock { streamer.stop() }
        let events = Locked<[ScreenVideoClient.Event]>([])
        let client = ScreenVideoClient(stream: phone, maxSide: 320, queue: DispatchQueue(label: "test")) { event in
            events.set(events.get() + [event])
        }
        client.start()
        func answers() -> [Bool] { events.get().compactMap { if case let .curtained(hidden) = $0 { return hidden } else { return nil } } }
        waitUntil("refused") { answers() == [false] }
        client.curtain(true)
        waitUntil("refused again") { answers() == [false, false] }
        XCTAssertEqual(capture.curtains.get(), [], "nothing was hidden")
    }

    /// A pointer image is checked for its real size before it's decoded: a few
    /// bytes claiming a huge image are skipped, a real pointer's shape is shown.
    func testAHugePointerImageIsNotDecoded() throws {
        func png(_ side: Int) throws -> Data {
            let context = try XCTUnwrap(CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            let data = NSMutableData()
            let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
            CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
            XCTAssertTrue(CGImageDestinationFinalize(destination))
            return data as Data
        }
        let (mac, phone) = MemoryPipe.pair()
        let events = Locked<[ScreenVideoClient.Event]>([])
        let client = ScreenVideoClient(stream: phone, maxSide: 320, queue: DispatchQueue(label: "test")) { event in
            events.set(events.get() + [event])
        }
        client.start()
        addTeardownBlock { client.close() }
        func shapes() -> [CGSize] { events.get().compactMap { if case let .cursorShape(_, size, _) = $0 { size } else { nil } } }
        let huge = ScreenVideoWire.encode(.cursorShape(width: 10, height: 10, hotX: 0, hotY: 0, png: try png(2048)))
        let real = ScreenVideoWire.encode(.cursorShape(width: 20, height: 20, hotX: 1, hotY: 1, png: try png(64)))
        mac.send(huge + real, isComplete: false) { _ in }
        waitUntil("the real one") { !shapes().isEmpty }
        XCTAssertEqual(shapes(), [CGSize(width: 20, height: 20)], "the huge one was skipped")
    }

    /// A phone that goes quiet (put away) with frames it hasn't acknowledged gets its curtain
    /// taken down, and is told so; the stream itself goes on.
    func testAQuietPhonesCurtainComesDown() throws {
        guard (try? VideoEncoder(width: 320, height: 200, bitRate: 1_000_000)) != nil else {
            throw XCTSkip("no hardware H.264 encoder")
        }
        let capture = FakeCapture(width: 320, height: 200)
        var limits = ScreenVideoStreamer.Limits()
        limits.curtainSilence = 0.4
        let streamer = ScreenVideoStreamer(capture: { capture }, input: { _ in RecordingInput() }, limits: limits)
        let (mac, phone) = MemoryPipe.pair()
        streamer.start(stream: mac, initialBytes: ScreenVideoWire.encode(.hello(.init(width: 320, height: 320, fit: .mac, codecs: .h264)))
                       + ScreenVideoWire.encode(.curtain(true))) {}
        addTeardownBlock { streamer.stop() }
        waitUntil("hidden") { capture.curtains.get() == [true] }
        capture.push(shade: 80)   // a frame the phone never acknowledges
        waitUntil("shown again") { capture.curtains.get() == [true, false] }
        XCTAssertFalse(capture.stopped.get())
        _ = phone
    }

    /// The pointer goes separately from the frames: where it is when it moves,
    /// what it looks like when that changes, in the stream's terms.
    func testThePointerIsSentApart() {
        let capture = FakeCapture(width: 720, height: 450)
        let cursor = FakeCursor()
        cursor.point.set(CGPoint(x: 720, y: 225))   // the display is 1440×900 points
        let streamer = ScreenVideoStreamer(capture: { capture }, input: { _ in RecordingInput() }, cursor: cursor)
        let (mac, phone) = MemoryPipe.pair()
        streamer.start(stream: mac, initialBytes: Data()) {}
        addTeardownBlock { streamer.stop() }
        let events = Locked<[ScreenVideoClient.Event]>([])
        let client = ScreenVideoClient(stream: phone, maxSide: 720, queue: DispatchQueue(label: "test")) { event in
            events.set(events.get() + [event])
        }
        client.start()
        func cursors() -> [(Double, Double, Bool)] {
            events.get().compactMap { if case let .cursor(x, y, visible) = $0 { (x, y, visible) } else { nil } }
        }
        func shapes() -> [(CGSize, CGPoint)] {
            events.get().compactMap { if case let .cursorShape(_, size, hot) = $0 { (size, hot) } else { nil } }
        }
        waitUntil("where it is") { !cursors().isEmpty }
        guard !cursors().isEmpty else { return }
        XCTAssertEqual(cursors()[0].0, 720.0 / 1439, accuracy: 0.001)
        XCTAssertEqual(cursors()[0].1, 225.0 / 899, accuracy: 0.001)
        XCTAssertTrue(cursors()[0].2)
        waitUntil("what it looks like") { !shapes().isEmpty }
        guard !cursors().isEmpty, !shapes().isEmpty else { return }
        // 20×24 points with the tip at (4, 2), in a stream of half the display's points.
        XCTAssertEqual(shapes()[0].0, CGSize(width: 10, height: 12))
        XCTAssertEqual(shapes()[0].1, CGPoint(x: 2, y: 1))

        spin(0.2)
        XCTAssertEqual(cursors().count, 1, "still: nothing more")
        XCTAssertEqual(shapes().count, 1)
        cursor.point.set(CGPoint(x: 2000, y: 10))   // on another display
        waitUntil("off this display") { cursors().last?.2 == false }
    }

    /// `device`: the stream moves to a display made in the phone's shape, and
    /// back to the Mac's own when asked, which removes it. Stopping removes it too.
    func testTheStreamMovesToADisplayMadeForThePhone() {
        let capture = FakeCapture(width: 640, height: 400)
        let display = FakeDisplay()
        let streamer = ScreenVideoStreamer(capture: { capture }, input: { _ in RecordingInput() }, display: display)
        let (mac, phone) = MemoryPipe.pair()
        streamer.start(stream: mac, initialBytes: Data()) {}
        let events = Locked<[ScreenVideoClient.Event]>([])
        let client = ScreenVideoClient(stream: phone, layout: .init(width: 640, height: 640, fit: .mac),
                                       queue: DispatchQueue(label: "test")) { event in events.set(events.get() + [event]) }
        client.start()
        func fits() -> [ScreenVideoWire.Fit] { events.get().compactMap { if case let .fitted(fit) = $0 { fit } else { nil } } }
        waitUntil("the Mac's own") { fits() == [.mac] }
        XCTAssertEqual(capture.sources.get(), [.main(maxSide: 640, scale: 1)])

        client.relayout(.init(width: 402, height: 874, fit: .device))
        waitUntil("the phone's") { fits() == [.mac, .device] }
        XCTAssertEqual(display.shown.get(), [CGSize(width: 402, height: 874)])
        XCTAssertEqual(capture.sources.get().last, .display(77, width: 402, height: 874))

        // Turned: the same display, the other way round.
        client.relayout(.init(width: 874, height: 402, fit: .device))
        waitUntil("turned") { fits().count == 3 }
        XCTAssertEqual(display.shown.get().last, CGSize(width: 874, height: 402))
        XCTAssertEqual(display.closes.get(), 0)

        client.relayout(.init(width: 874, height: 402, fit: .mac))
        waitUntil("the Mac's own again") { fits().last == .mac && fits().count == 4 }
        XCTAssertEqual(display.closes.get(), 1)
        XCTAssertEqual(capture.sources.get().last, .main(maxSide: 874, scale: 1))

        client.relayout(.init(width: 402, height: 874, fit: .device))
        waitUntil("the phone's again") { fits().count == 5 }
        streamer.stop()
        waitUntil("removed when it ends") { display.closes.get() == 2 }
    }

    /// A Mac that can't make the phone's display shows its own, and says so.
    func testNoDisplayForThePhoneMeansTheMacsOwn() {
        let capture = FakeCapture(width: 640, height: 400)
        let display = FakeDisplay()
        display.fails.set(true)
        let streamer = ScreenVideoStreamer(capture: { capture }, input: { _ in RecordingInput() }, display: display)
        let (mac, phone) = MemoryPipe.pair()
        streamer.start(stream: mac, initialBytes: Data()) {}
        addTeardownBlock { streamer.stop() }
        let events = Locked<[ScreenVideoClient.Event]>([])
        let client = ScreenVideoClient(stream: phone, layout: .init(width: 402, height: 874, fit: .device),
                                       queue: DispatchQueue(label: "test")) { event in events.set(events.get() + [event]) }
        client.start()
        waitUntil("answered") { events.get().contains { if case .fitted = $0 { true } else { false } } }
        XCTAssertTrue(events.get().contains { if case .fitted(.mac) = $0 { true } else { false } })
        XCTAssertEqual(capture.sources.get(), [.main(maxSide: 874, scale: 1)])
    }

    /// Each view hears which other devices view the screen; "Use Here" on one
    /// ends the others', which are told who took over.
    func testUseHereEndsTheOtherDevicesViews() {
        func view(_ phoneID: String, _ name: String) -> (ScreenVideoStreamer, Locked<[ScreenVideoClient.Event]>, ScreenVideoClient, XCTestExpectation) {
            let capture = FakeCapture(width: 320, height: 200)
            let streamer = ScreenVideoStreamer(capture: { capture }, input: { _ in RecordingInput() }, viewer: (phoneID, name))
            let (mac, phone) = MemoryPipe.pair()
            let ended = expectation(description: "\(name) ended")
            ended.assertForOverFulfill = false
            streamer.start(stream: mac, initialBytes: Data()) { ended.fulfill() }
            let events = Locked<[ScreenVideoClient.Event]>([])
            let client = ScreenVideoClient(stream: phone, maxSide: 320, queue: DispatchQueue(label: name)) { events.set(events.get() + [$0]) }
            client.start()
            return (streamer, events, client, ended)
        }
        func others(_ events: Locked<[ScreenVideoClient.Event]>) -> [String]? {
            events.get().compactMap { if case let .viewers(names) = $0 { names } else { nil } }.last
        }
        let (pad, padEvents, padClient, padEnded) = view("pad", "iPad")
        let (phone, phoneEvents, phoneClient, phoneEnded) = view("phone", "iPhone")
        phoneEnded.isInverted = true
        // The phone's second stream (trying to replace Screen Sharing, say) doesn't count twice.
        let (second, _, secondClient, secondEnded) = view("phone", "iPhone")
        secondEnded.isInverted = true
        // The clients are kept: one let go stops reading.
        addTeardownBlock { pad.stop(); phone.stop(); second.stop(); _ = [padClient, secondClient] }
        waitUntil("the iPad hears of the iPhone") { others(padEvents) == ["iPhone"] }
        waitUntil("and the iPhone of the iPad") { others(phoneEvents) == ["iPad"] }

        phoneClient.useHere()
        wait(for: [padEnded], timeout: 5)
        XCTAssertTrue(padEvents.get().contains { if case .movedAway(to: "iPhone") = $0 { true } else { false } })
        waitUntil("the iPhone is alone") { others(phoneEvents) == [] }
        wait(for: [phoneEnded, secondEnded], timeout: 0.3)
    }

    /// While only a sliver of the screen changes and the phone is still, frames
    /// slow to `idleFPS`; the phone's next input brings them back at once.
    func testASpinnerAloneIsSentSlowly() throws {
        guard (try? VideoEncoder(width: 320, height: 200, bitRate: 1_000_000)) != nil else {
            throw XCTSkip("no hardware H.264 encoder")
        }
        let capture = FakeCapture(width: 320, height: 200)
        let streamer = ScreenVideoStreamer(capture: { capture }, input: { _ in RecordingInput() })
        let (mac, phone) = MemoryPipe.pair()
        streamer.start(stream: mac, initialBytes: Data()) {}
        addTeardownBlock { streamer.stop() }
        let events = Locked<[ScreenVideoClient.Event]>([])
        let clientQueue = DispatchQueue(label: "test")
        var client: ScreenVideoClient!
        client = ScreenVideoClient(stream: phone, maxSide: 320, queue: clientQueue) { event in
            events.set(events.get() + [event])
            if case let .frame(_, number) = event { client.shown(number) }   // a phone that keeps up
        }
        client.start()
        waitUntil("capture started") { capture.maxSide.get() == 320 }
        func frames() -> Int { Self.frames(events.get()).count }
        func push(for seconds: TimeInterval, changed: Double) {
            let end = Date().addingTimeInterval(seconds)
            var shade: UInt8 = 0
            while Date() < end {
                shade &+= 7
                capture.push(shade: shade, changed: changed)
                spin(1.0 / 60)
            }
        }
        push(for: 1.5, changed: 0.01)   // the first second goes at full speed
        let before = frames()
        push(for: 1, changed: 0.01)
        let idle = frames() - before
        XCTAssertLessThanOrEqual(idle, Int(ScreenVideoStreamer.idleFPS) + 3, "a spinner alone: slow")
        XCTAssertGreaterThan(idle, 5, "but still moving")
        client.pointer(x: 0.5, y: 0.5, buttons: [])
        spin(0.05)
        let touched = frames()
        push(for: 0.5, changed: 0.01)
        // Half a second at the idle rate is 7 or 8 frames; anything clearly over that is the limit lifted
        // (a slow machine's encoder may not manage many more).
        XCTAssertGreaterThan(frames() - touched, Int(ScreenVideoStreamer.idleFPS / 2) + 2, "touched: full speed again")
    }

    /// The phone's frame rate reaches the capture and its display; `space` sizes
    /// the display against the stream; `fast` starts smaller.
    func testFrameRateQualityAndSpaceReachTheCapture() {
        let capture = FakeCapture(width: 640, height: 400)
        let display = FakeDisplay()
        let streamer = ScreenVideoStreamer(capture: { capture }, input: { _ in RecordingInput() }, display: display)
        let (mac, phone) = MemoryPipe.pair()
        streamer.start(stream: mac, initialBytes: Data()) {}
        addTeardownBlock { streamer.stop() }
        let events = Locked<[ScreenVideoClient.Event]>([])
        let client = ScreenVideoClient(stream: phone, layout: .init(width: 1000, height: 800, fit: .device, fps: 120, space: 125),
                                       queue: DispatchQueue(label: "test")) { events.set(events.get() + [$0]) }
        client.start()
        func fits() -> Int { events.get().filter { if case .fitted = $0 { true } else { false } }.count }
        waitUntil("started") { fits() == 1 }
        XCTAssertEqual(display.shown.get(), [CGSize(width: 1250, height: 1000)], "more room: a bigger display")
        XCTAssertEqual(capture.sources.get().last, .display(77, width: 1000, height: 800), "streamed at the phone's size")
        XCTAssertEqual(capture.rates.get().last, 120)

        client.relayout(.init(width: 1000, height: 800, fit: .device, fps: 120, quality: .fast, space: 80))
        waitUntil("changed") { fits() == 2 }
        XCTAssertEqual(display.shown.get().last, CGSize(width: 800, height: 640), "bigger text: a smaller display")
        XCTAssertEqual(capture.sources.get().last, .display(77, width: 750, height: 600), "fast: ¾ size from the start")
    }

    /// Leaving the phone's display removes it, which stops the capture on it
    /// before the new one is up: the curtain still goes over to the new one, so
    /// the Mac's displays don't show, and the phone isn't told otherwise.
    func testTheCurtainStaysUpWhenTheOldDisplayGoesFirst() {
        let made = Locked<[FakeCapture]>([])
        let display = FakeDisplay()
        let streamer = ScreenVideoStreamer(capture: {
            let capture = FakeCapture(width: 320, height: 200)
            made.set(made.get() + [capture])
            return capture
        }, input: { _ in RecordingInput() }, display: display)
        let (mac, phone) = MemoryPipe.pair()
        streamer.start(stream: mac, initialBytes: Data()) {}
        addTeardownBlock { streamer.stop() }
        let events = Locked<[ScreenVideoClient.Event]>([])
        let client = ScreenVideoClient(stream: phone, layout: .init(width: 400, height: 800, fit: .device),
                                       queue: DispatchQueue(label: "test")) { events.set(events.get() + [$0]) }
        client.start()
        func fits() -> Int { events.get().filter { if case .fitted = $0 { true } else { false } }.count }
        func answers() -> [Bool] { events.get().compactMap { if case let .curtained(hidden) = $0 { hidden } else { nil } } }
        waitUntil("on the phone's display") { fits() == 1 }
        client.curtain(true)
        waitUntil("hidden") { answers() == [true] }
        XCTAssertEqual(made.get().first?.curtains.get(), [true])

        display.onClose.set { made.get()[0].die() }
        client.relayout(.init(width: 400, height: 800, fit: .mac))
        waitUntil("on the Mac's own") { fits() == 2 }
        waitUntil("the new capture holds the curtain") { made.get().count == 2 && made.get()[1].curtains.get() == [true] }
        waitUntil("the old one let go after") { made.get()[0].stopped.get() }
        spin(0.2)
        XCTAssertEqual(answers(), [true], "the phone was never told it fell")
    }

    /// The phone can place the pointer only once it knows the stream's size, so
    /// where it is goes again after each format, though it hasn't moved.
    func testThePointerFollowsEachFormat() throws {
        guard (try? VideoEncoder(width: 320, height: 200, bitRate: 1_000_000)) != nil else {
            throw XCTSkip("no hardware H.264 encoder")
        }
        let capture = FakeCapture(width: 320, height: 200)
        let cursor = FakeCursor()
        cursor.point.set(CGPoint(x: 100, y: 100))
        let streamer = ScreenVideoStreamer(capture: { capture }, input: { _ in RecordingInput() }, cursor: cursor)
        let (mac, phone) = MemoryPipe.pair()
        streamer.start(stream: mac, initialBytes: Data()) {}
        addTeardownBlock { streamer.stop() }
        let events = Locked<[ScreenVideoClient.Event]>([])
        let client = ScreenVideoClient(stream: phone, maxSide: 320, queue: DispatchQueue(label: "test")) { events.set(events.get() + [$0]) }
        client.start()
        waitUntil("capture started") { capture.maxSide.get() == 320 }
        spin(0.2)   // the first place goes before any format
        capture.push(shade: 90)
        waitUntil("a size") { events.get().contains { if case .size = $0 { true } else { false } } }
        waitUntil("then where the pointer is") {
            let all = events.get()
            guard let size = all.firstIndex(where: { if case .size = $0 { true } else { false } }) else { return false }
            return all[size...].contains { if case .cursor = $0 { true } else { false } }
        }
    }

    /// The encoder skips frames on purpose (no error, no output): after a detailed
    /// keyframe at a modest bitrate it skips a dozen or more in a row to stay in
    /// budget. That isn't the encoder dying, and the stream goes on. (Three in a
    /// row used to count as a dead encoder and end the stream: every view on a slow link.)
    func testFramesTheEncoderSkipsDontEndTheStream() throws {
        guard (try? VideoEncoder(width: 1296, height: 836, bitRate: 500_000)) != nil else {
            throw XCTSkip("no hardware H.264 encoder")
        }
        let capture = FakeCapture(width: 1296, height: 836)
        let streamer = ScreenVideoStreamer(capture: { capture }, input: { _ in RecordingInput() })
        let (mac, phone) = MemoryPipe.pair()
        let ended = expectation(description: "ended")
        ended.isInverted = true
        streamer.start(stream: mac, initialBytes: Data()) { ended.fulfill() }
        addTeardownBlock { streamer.stop() }
        let events = Locked<[ScreenVideoClient.Event]>([])
        var client: ScreenVideoClient!
        client = ScreenVideoClient(stream: phone, maxSide: 1296, queue: DispatchQueue(label: "test")) { event in
            events.set(events.get() + [event])
            if case let .frame(_, number) = event { client.shown(number) }
        }
        client.start()
        waitUntil("capture started") { capture.maxSide.get() == 1296 }
        // Detailed pictures (noise), changing every time: the keyframe costs a lot, and
        // the encoder skips what follows until the budget allows.
        for seed in 0..<90 {
            capture.push(noise: UInt32(seed))
            spin(1.0 / 60)
        }
        waitUntil("frames go on after the skipping") { Self.frames(events.get()).count >= 3 }
        wait(for: [ended], timeout: 0.5)
    }

    /// A phone that goes while holding the button (mid-drag) or mid-pinch leaves
    /// nothing held on the Mac: the stream's end lets go of it all.
    func testTheEndLetsGoOfWhatThePhoneHeld() {
        let capture = FakeCapture(width: 320, height: 200)
        let input = RecordingInput()
        let streamer = ScreenVideoStreamer(capture: { capture }, input: { _ in input })
        let (mac, phone) = MemoryPipe.pair()
        let ended = expectation(description: "ended")
        streamer.start(stream: mac, initialBytes: ScreenVideoWire.encode(.hello(.init(width: 320, height: 320, fit: .mac, codecs: .h264)))) {
            ended.fulfill()
        }
        waitUntil("input ready") {
            phone.send(ScreenVideoWire.encode(.pointer(x: 10, y: 10, buttons: 1)), isComplete: false) { _ in }
            spin(0.02)
            return !input.log.get().isEmpty
        }
        XCTAssertFalse(input.log.get().contains("release"))
        phone.send(nil, isComplete: true) { _ in }   // gone, button still down
        wait(for: [ended], timeout: 5)
        XCTAssertEqual(input.log.get().last, "release")
    }

    /// The injector's events never make macOS ignore the Mac's own keyboard and trackpad.
    func testTheMacsOwnInputIsNeverHeldBack() throws {
        let source = try XCTUnwrap(InputInjector(display: CGRect(x: 0, y: 0, width: 100, height: 100)).source)
        XCTAssertEqual(source.localEventsSuppressionInterval, 0)
        let everything: CGEventFilterMask = [.permitLocalMouseEvents, .permitLocalKeyboardEvents, .permitSystemDefinedEvents]
        XCTAssertEqual(source.getLocalEventsFilterDuringSuppressionState(.eventSuppressionStateSuppressionInterval), everything)
        XCTAssertEqual(source.getLocalEventsFilterDuringSuppressionState(.eventSuppressionStateRemoteMouseDrag), everything)
    }

    /// Scrolling comes in the stream's pixels and reaches the Mac in its points: on a display
    /// made for the phone (two pixels to the point) half as far, fractions carried over.
    func testScrollingFollowsTheFingersAtAnyStreamSize() {
        let capture = FakeCapture(width: 640, height: 400)
        let input = RecordingInput()
        let streamer = ScreenVideoStreamer(capture: { capture }, input: { _ in input }, display: FakeDisplay())
        let (mac, phone) = MemoryPipe.pair()
        streamer.start(stream: mac, initialBytes: Data()) {}
        addTeardownBlock { streamer.stop() }
        let events = Locked<[ScreenVideoClient.Event]>([])
        let client = ScreenVideoClient(stream: phone, layout: .init(width: 1000, height: 800, fit: .device),
                                       queue: DispatchQueue(label: "test")) { events.set(events.get() + [$0]) }
        client.start()
        waitUntil("on the phone's display") { events.get().contains { if case .fitted(.device) = $0 { true } else { false } } }
        client.scroll(dx: 0, dy: 101)
        client.scroll(dx: 0, dy: 1)
        client.scroll(dx: -40, dy: 0)
        waitUntil("scrolled") { input.log.get().filter { $0.hasPrefix("scroll") }.count == 3 }
        XCTAssertEqual(input.log.get().filter { $0.hasPrefix("scroll") }, ["scroll 0 50", "scroll 0 1", "scroll -20 0"])
    }

    /// The phone hanging up ends the stream (and so, upstream, the connection).
    func testThePhoneLeavingEndsIt() {
        let capture = FakeCapture(width: 320, height: 200)
        let streamer = ScreenVideoStreamer(capture: { capture }, input: { _ in RecordingInput() })
        let (mac, phone) = MemoryPipe.pair()
        let ended = expectation(description: "ended")
        streamer.start(stream: mac, initialBytes: ScreenVideoWire.encode(.hello(.init(width: 320, height: 320, fit: .mac, codecs: .h264)))) { ended.fulfill() }
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

    /// Runs the main queue meanwhile: the phone's display and the pointer's shape are made there.
    private func waitUntil(_ message: String, timeout: TimeInterval = 5, _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { return XCTFail("timed out: \(message)") }
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
    }

    private func spin(_ seconds: TimeInterval) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }
}

/// Frames of one flat shade, pushed when a test says the screen changed.
private final class FakeCapture: FrameCapturing, @unchecked Sendable {
    let width: Int, height: Int
    let maxSide = Locked(0)
    let stopped = Locked(false)
    private let deliver = Locked<((CVPixelBuffer, Double) -> Void)?>(nil)
    private let queue = Locked<DispatchQueue?>(nil)

    init(width: Int, height: Int) { self.width = width; self.height = height }

    /// Every source it was started with, in order.
    let sources = Locked<[CaptureSource]>([])

    /// The frame rate of each start, in order.
    let rates = Locked<[Int]>([])

    func start(_ source: CaptureSource, fps: Int, queue: DispatchQueue, frame: @escaping (CVPixelBuffer, Double) -> Void,
               stopped: @escaping (Error?) -> Void) async throws -> (width: Int, height: Int, display: CGRect) {
        self.queue.set(queue)
        rates.set(rates.get() + [fps])
        ended.set(stopped)
        deliver.set(frame)
        sources.set(sources.get() + [source])
        switch source {
        case let .main(maxSide, _):
            self.maxSide.set(maxSide)
            return (width, height, CGRect(x: 0, y: 0, width: 1440, height: 900))
        case let .display(_, width, height):
            return (width, height, CGRect(x: 1440, y: 0, width: Double(width) / 2, height: Double(height) / 2))
        }
    }

    func stop() { stopped.set(true); deliver.set(nil) }

    /// Capture ends by itself, as ScreenCaptureKit's does when its display goes away.
    private let ended = Locked<((Error?) -> Void)?>(nil)
    func die() { deliver.set(nil); ended.get()?(CocoaError(.featureUnsupported)) }

    /// What the phone asked of the curtain, and whether this capture can do it.
    let curtains = Locked<[Bool]>([])
    let canHide = Locked(true)
    func setCurtain(_ hidden: Bool, done: @escaping @Sendable (Bool) -> Void) {
        curtains.set(curtains.get() + [hidden])
        done(hidden && canHide.get())
    }

    /// A frame of noise, different for each `seed`: as costly to encode as a picture gets.
    func push(noise seed: UInt32) {
        // A few pictures, made once: filling one takes a while unoptimized.
        let seed = seed % 4
        if let made = noises.get()[seed] {
            guard let queue = queue.get(), let deliver = deliver.get() else { return }
            return queue.sync { deliver(made, 1) }
        }
        var buffer: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, attributes, &buffer)
        guard let buffer else { return }
        CVPixelBufferLockBaseAddress(buffer, [])
        var x = seed &* 2_654_435_761 &+ 1
        for plane in 0..<2 {
            let base = CVPixelBufferGetBaseAddressOfPlane(buffer, plane)!.assumingMemoryBound(to: UInt8.self)
            for i in 0..<(CVPixelBufferGetBytesPerRowOfPlane(buffer, plane) * CVPixelBufferGetHeightOfPlane(buffer, plane)) {
                x = x &* 1_664_525 &+ 1_013_904_223
                base[i] = UInt8(x >> 24)
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        var all = noises.get()
        all[seed] = buffer
        noises.set(all)
        guard let queue = queue.get(), let deliver = deliver.get() else { return }
        queue.sync { deliver(buffer, 1) }
    }
    private let noises = Locked<[UInt32: CVPixelBuffer]>([:])

    /// A frame of one shade; `changed`: how much of the screen it says changed.
    func push(shade: UInt8, changed: Double = 1) {
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
        queue.sync { deliver(buffer, changed) }
    }
}

/// A pointer a test moves; it looks like a 20×24-point arrow.
private final class FakeCursor: CursorSource, @unchecked Sendable {
    let point = Locked(CGPoint.zero)
    func location() -> CGPoint? { point.get() }
    @MainActor func shape() -> CursorImage? {
        CursorImage(png: Self.png, size: CGSize(width: 20, height: 24), hotSpot: CGPoint(x: 4, y: 2))
    }

    /// A 2×2 PNG: the phone skips a shape that doesn't decode.
    static let png: Data = {
        let context = CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        CGImageDestinationFinalize(destination)
        return data as Data
    }()
}

/// A display for the phone that a test watches being made and removed.
private final class FakeDisplay: DeviceDisplaying, @unchecked Sendable {
    let shown = Locked<[CGSize]>([])
    let closes = Locked(0)
    let fails = Locked(false)
    /// Runs as it closes (the capture on it stopping, say).
    let onClose = Locked<(@Sendable () -> Void)?>(nil)
    private let open = Locked(false)
    struct Failed: Error {}
    @MainActor func show(width: Int, height: Int, fps: Int) async throws -> CGDirectDisplayID {
        guard !fails.get() else { throw Failed() }
        shown.set(shown.get() + [CGSize(width: width, height: height)])
        open.set(true)
        return 77
    }
    @MainActor func close() {
        guard open.get() else { return }
        open.set(false)
        closes.set(closes.get() + 1)
        onClose.get()?()
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
    func key(keysym: UInt32, modifiers: UInt8) {
        log.set(log.get() + ["key \(keysym) \(modifiers)"])
        if keysym == 0x63, modifiers == ScreenVideoWire.Modifiers.command.rawValue, let copied = copy.get() {
            board.set((board.get().count + 1, copied))
        }
    }
    func text(_ text: String) { log.set(log.get() + ["text \(text)"]) }
    func clipboard(_ text: String) { log.set(log.get() + ["clipboard \(text)"]) }
    func gesture(_ gesture: ScreenVideoWire.Gesture, phase: ScreenVideoWire.GesturePhase, value: Double) {
        log.set(log.get() + ["gesture \(gesture) \(phase) \(value)"])
    }
    func releaseAll() { log.set(log.get() + ["release"]) }
    /// The Mac's clipboard; ⌘C replaces it with `copies` when that is set.
    private let board = Locked<(count: Int, text: String?)>((0, nil))
    private let copy = Locked<String?>(nil)
    var clipboard: (count: Int, text: String?) { get { board.get() } set { board.set(newValue) } }
    var copies: String? { get { copy.get() } set { copy.set(newValue) } }
    var clipboardChangeCount: Int { board.get().count }
    func clipboardContents() -> ClipboardContents { board.get().text.map { .text($0) } ?? .notText }
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
