import XCTest
import Network
@testable import PassthroughCore

/// Two in-memory byte streams wired back to back, standing in for the TLS connection.
final class MemoryStream: ByteStream, @unchecked Sendable {
    weak var peer: MemoryStream?
    private let lock = NSLock()
    private var buffer = Data()
    private var finished = false
    private var dead = false
    private var waiting: ((Data?, Bool, Error?) -> Void, Int)?
    var onTerminated: (@Sendable (Error?) -> Void)?

    static func pair() -> (MemoryStream, MemoryStream) {
        let a = MemoryStream(), b = MemoryStream()
        a.peer = b; b.peer = a
        return (a, b)
    }

    func receive(maximumLength: Int, completion: @escaping @Sendable (Data?, Bool, Error?) -> Void) {
        lock.lock(); waiting = (completion, maximumLength); lock.unlock()
        pump()
    }

    func send(_ data: Data?, isComplete: Bool, completion: @escaping @Sendable (Error?) -> Void) {
        guard let peer, !dead else { completion(MuxError.linkClosed); return }
        peer.deliver(data ?? Data(), finished: isComplete)
        completion(nil)
    }

    func cancel() {
        dead = true
        peer?.remoteCancelled()
    }

    private func remoteCancelled() {
        let handler = onTerminated
        DispatchQueue.global().async { handler?(nil) }
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

/// Reads until the stream finishes; returns everything received.
func readAll(_ stream: ByteStream, into data: Locked<Data>, done: XCTestExpectation) {
    stream.receive(maximumLength: 65536) { chunk, complete, error in
        if let chunk { data.set(data.get() + chunk) }
        if complete || error != nil { done.fulfill(); return }
        readAll(stream, into: data, done: done)
    }
}

final class MuxTests: XCTestCase {
    private func linked() -> (mac: Mux, phone: Mux) {
        let (a, b) = MemoryStream.pair()
        let mac = Mux(transport: a, isOpener: true, queue: DispatchQueue(label: "mac"))
        let phone = Mux(transport: b, isOpener: false, queue: DispatchQueue(label: "phone"))
        mac.start(); phone.start()
        return (mac, phone)
    }

    func testFramesRoundTripAndWaitForMoreBytes() throws {
        let frames = [MuxFrame(.open, stream: 1, payload: Data([0x1E, 0xD2])), MuxFrame(.data, stream: 7, payload: Data(repeating: 9, count: 300)), MuxFrame(.fin, stream: 7)]
        var wire = frames.reduce(Data()) { $0 + $1.encoded }
        let tail = wire.suffix(5)
        wire.removeLast(5)
        XCTAssertEqual(try MuxFrame.parse(&wire), Array(frames.prefix(2)), "the cut FIN waits for its last bytes")
        wire.append(tail)
        XCTAssertEqual(try MuxFrame.parse(&wire), [frames[2]])
        XCTAssertTrue(wire.isEmpty)
        var bad = Data([9, 0, 0, 0, 1, 0, 0])
        XCTAssertThrowsError(try MuxFrame.parse(&bad))
    }

    /// 3 MB each way on two streams at once: flow control, ordering, half-close.
    func testStreamsCarryDataBothWays() {
        let (mac, phone) = linked()
        let ports = Locked<[UInt16]>([])
        phone.onOpen = { port, stream in
            ports.set(ports.get() + [port])
            // Echo everything back, then finish when the Mac finishes.
            func echo() {
                stream.receive(maximumLength: 40_000) { data, complete, _ in
                    if let data { stream.send(data, isComplete: false) { _ in } }
                    if complete { stream.send(nil, isComplete: true) { _ in }; return }
                    echo()
                }
            }
            echo()
        }
        let payload = Data((0..<3_000_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        var expectations: [XCTestExpectation] = []
        var results: [Locked<Data>] = []
        for port: UInt16 in [7890, 7891] {
            let stream = mac.open(port: port)
            let got = Locked(Data()), done = expectation(description: "stream \(port)")
            readAll(stream, into: got, done: done)
            stream.send(payload, isComplete: true) { XCTAssertNil($0) }
            expectations.append(done); results.append(got)
        }
        wait(for: expectations, timeout: 20)
        for got in results { XCTAssertEqual(got.get(), payload) }
        XCTAssertEqual(Set(ports.get()), [7890, 7891])
    }

    /// A long, busy stream must not keep what it already delivered: the phone's
    /// tunnel has a 50 MB memory limit and a speed test moves hundreds of MB.
    func testLongStreamDoesNotHoldDeliveredBytes() throws {
        let (mac, phone) = linked()
        let total = 128 * 1024 * 1024
        let received = Locked(0), done = expectation(description: "drained")
        let before = try XCTUnwrap(PassthroughService.footprintMB())
        let grown = Locked(0)
        phone.onOpen = { _, stream in
            func drain() {
                // Reads smaller than a frame, like a slow uplink: the buffer never empties.
                stream.receive(maximumLength: 5_000) { data, complete, _ in
                    let was = received.get(), now = was + (data?.count ?? 0)
                    received.set(now)
                    // Measure mid-transfer: closing the stream frees whatever it kept.
                    if was < total * 3 / 4, now >= total * 3 / 4 { grown.set((PassthroughService.footprintMB() ?? 0) - before) }
                    complete ? done.fulfill() : drain()
                }
            }
            // Start once the window is full, so the buffer stays partly filled.
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { drain() }
        }
        let stream = mac.open(port: 7890)
        let chunk = Data(repeating: 7, count: 256 * 1024)
        func push(_ left: Int) {
            guard left > 0 else { stream.send(nil, isComplete: true) { _ in }; return }
            stream.send(chunk, isComplete: false) { error in if error == nil { push(left - chunk.count) } }
        }
        push(total)
        wait(for: [done], timeout: 60)
        XCTAssertEqual(received.get(), total)
        XCTAssertLessThan(grown.get(), 16, "memory grew \(grown.get()) MB moving \(total >> 20) MB")
    }

    func testResetAndLinkLossReachTheOtherSide() {
        let (mac, phone) = linked()
        phone.onOpen = { _, stream in stream.cancel() }
        let stream = mac.open(port: 7890)
        let reset = expectation(description: "reset")
        stream.receive(maximumLength: 10) { _, _, error in
            XCTAssertEqual(error as? MuxError, .reset); reset.fulfill()
        }
        wait(for: [reset], timeout: 5)

        let held = expectation(description: "phone stream held")
        let heldStream = Locked<MuxStream?>(nil)
        phone.onOpen = { _, s in heldStream.set(s); held.fulfill() }
        let second = mac.open(port: 7891)
        wait(for: [held], timeout: 5)
        let terminated = expectation(description: "terminated when the link closes")
        heldStream.get()?.onTerminated = { error in
            XCTAssertNotNil(error); terminated.fulfill()
        }
        mac.close()
        wait(for: [terminated], timeout: 5)
        _ = second
    }

    func testQuietLinkTimesOut() {
        let saved = (Mux.pingInterval, Mux.deadAfter)
        Mux.pingInterval = 0.1; Mux.deadAfter = 0.3
        defer { (Mux.pingInterval, Mux.deadAfter) = saved }
        let (a, b) = MemoryStream.pair()   // the far end never answers
        defer { withExtendedLifetime(b) {} }
        let mux = Mux(transport: a, isOpener: true, queue: DispatchQueue(label: "quiet"))
        let closed = expectation(description: "closed")
        mux.onClose = { error in XCTAssertEqual(error as? MuxError, .timeout); closed.fulfill() }
        mux.start()
        wait(for: [closed], timeout: 3)
    }

    /// A 3 MB echo survives the connection breaking halfway: each side keeps
    /// what the other hasn't confirmed and resends exactly the missing part.
    func testStreamsSurviveAReconnect() {
        let (a1, b1) = MemoryStream.pair()
        let mac = Mux(transport: a1, isOpener: true, queue: DispatchQueue(label: "mac"), sessionID: "s", resumable: true)
        let phone = Mux(transport: b1, isOpener: false, queue: DispatchQueue(label: "phone"), sessionID: "s", resumable: true)
        let suspended = expectation(description: "both suspended")
        suspended.expectedFulfillmentCount = 2
        mac.onSuspend = { _ in suspended.fulfill() }
        phone.onSuspend = { _ in suspended.fulfill() }
        phone.onOpen = { _, stream in
            func echo() {
                stream.receive(maximumLength: 40_000) { data, complete, _ in
                    if let data { stream.send(data, isComplete: false) { _ in } }
                    if complete { stream.send(nil, isComplete: true) { _ in }; return }
                    echo()
                }
            }
            echo()
        }
        mac.start(); phone.start()
        let payload = Data((0..<3_000_000).map { UInt8(truncatingIfNeeded: $0 &* 13) })
        let stream = mac.open(port: 7890)
        let got = Locked(Data()), done = expectation(description: "echoed")
        let dropped = Locked(false)
        func read() {
            stream.receive(maximumLength: 65536) { chunk, complete, error in
                if let chunk { got.set(got.get() + chunk) }
                if !dropped.get(), got.get().count > 1_000_000 {
                    dropped.set(true)
                    mac.interruptForTesting()
                }
                if complete || error != nil { XCTAssertNil(error); done.fulfill(); return }
                read()
            }
        }
        read()
        stream.send(payload, isComplete: true) { XCTAssertNil($0) }
        wait(for: [suspended], timeout: 10)
        let (a2, b2) = MemoryStream.pair()
        mac.streamStates { macStates in
            phone.streamStates { phoneStates in
                mac.resume(on: a2, peerStreams: phoneStates)
                phone.resume(on: b2, peerStreams: macStates)
            }
        }
        wait(for: [done], timeout: 20)
        XCTAssertEqual(got.get(), payload)
    }

    func testUnresumedLinkEventuallyCloses() {
        let saved = Mux.suspendTimeout
        Mux.suspendTimeout = 0.3
        defer { Mux.suspendTimeout = saved }
        let (a, b) = MemoryStream.pair()
        defer { withExtendedLifetime(b) {} }
        let mux = Mux(transport: a, isOpener: true, queue: DispatchQueue(label: "m"), resumable: true)
        let closed = expectation(description: "closed")
        mux.onClose = { error in XCTAssertEqual(error as? MuxError, .timeout); closed.fulfill() }
        mux.start()
        let stream = mux.open(port: 7890)
        let failed = expectation(description: "stream failed")
        stream.receive(maximumLength: 10) { _, _, error in XCTAssertNotNil(error); failed.fulfill() }
        mux.interruptForTesting()
        wait(for: [closed, failed], timeout: 3)
    }
}
