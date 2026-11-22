import Foundation
import PassthroughCore
import ScreenClient
import XCTest
@testable import ScreenEngine

final class ScreenEngineCodesTests: XCTestCase {
    func testEveryEndingCrossesAndComesBackTheSame() {
        let endings: [ScreenEnd] = [
            .closedHere, .connectionLost, .identityMismatch, .signIn(.wrongPassword), .signIn(.passwordExpired),
            .signIn(.accountLocked), .signIn(.accountDisabled), .signIn(.notAllowedRemotely), .signIn(.other(nil)),
            .signIn(.other("why")), .unsupported("Remote Desktop"), .takenOver, .signedOut, .hostEnded("licence"),
            .protocolError("Remote Desktop"),
        ]
        for end in endings {
            let sent = ScreenEngineCodes.code(end)
            XCTAssertEqual(ScreenEngineCodes.end(sent.code, detail: sent.detail), end)
        }
    }

    func testWhatTheHelperCannotBeTrustedOn() {
        // A code this build doesn't know is a lost connection, never a crash or a sign-in prompt.
        XCTAssertEqual(ScreenEngineCodes.end(99, detail: nil), .connectionLost)
        XCTAssertEqual(ScreenEngineCodes.end(-1, detail: "x"), .connectionLost)
        // A detail is cut short.
        XCTAssertEqual(ScreenEngineCodes.end(12, detail: String(repeating: "a", count: 5000)), .hostEnded(String(repeating: "a", count: 64)))
        XCTAssertNil(ScreenEngineCodes.phase(0))
        XCTAssertNil(ScreenEngineCodes.phase(4))
        for phase in [ScreenConnectPhase.negotiating, .identityChecked, .signedIn] {
            XCTAssertEqual(ScreenEngineCodes.phase(ScreenEngineCodes.code(phase)), phase)
        }
    }

    func testCopies() {
        for result in [ScreenCopyResult.text("hello"), .nothing, .tooLong, .notText] {
            let sent = ScreenEngineCodes.code(result)
            XCTAssertEqual(ScreenEngineCodes.copyResult(sent.code, text: sent.text), result)
        }
        XCTAssertEqual(ScreenEngineCodes.copyResult(0, text: nil), .nothing)
        XCTAssertEqual(ScreenEngineCodes.copyResult(0, text: ""), .nothing)
        XCTAssertEqual(ScreenEngineCodes.copyResult(0, text: String(repeating: "a", count: ScreenEngineCodes.maxTextUnits + 1)), .tooLong)
        XCTAssertEqual(ScreenEngineCodes.copyResult(77, text: "x"), .nothing)
    }

    func testSizes() {
        XCTAssertTrue(ScreenEngineCodes.validSize(width: 1920, height: 1200))
        XCTAssertTrue(ScreenEngineCodes.validSize(width: 8192, height: 4096))
        XCTAssertFalse(ScreenEngineCodes.validSize(width: 0, height: 1200))
        XCTAssertFalse(ScreenEngineCodes.validSize(width: -4, height: 1200))
        XCTAssertFalse(ScreenEngineCodes.validSize(width: 16385, height: 100))
        XCTAssertFalse(ScreenEngineCodes.validSize(width: 16384, height: 16384))   // past 50 million pixels
    }

    func testRectanglesAreClippedToTheDesktop() {
        let size = (width: 1000, height: 500)
        XCTAssertEqual(ScreenEngineCodes.clipped(x: 10, y: 20, width: 30, height: 40, in: size), CGRect(x: 10, y: 20, width: 30, height: 40))
        XCTAssertEqual(ScreenEngineCodes.clipped(x: 990, y: 490, width: 500, height: 500, in: size), CGRect(x: 990, y: 490, width: 10, height: 10))
        XCTAssertNil(ScreenEngineCodes.clipped(x: 1000, y: 0, width: 5, height: 5, in: size))
        XCTAssertNil(ScreenEngineCodes.clipped(x: 0, y: 0, width: 0, height: 5, in: size))
        XCTAssertNil(ScreenEngineCodes.clipped(x: 0, y: 0, width: -5, height: 5, in: size))
        // Huge numbers neither overflow nor escape.
        let huge = ScreenEngineCodes.clipped(x: 5, y: 5, width: Int.max, height: Int.max, in: size)
        XCTAssertEqual(huge, CGRect(x: 5, y: 5, width: 995, height: 495))
        let negative = ScreenEngineCodes.clipped(x: Int.min, y: -3, width: 20, height: 20, in: size)
        XCTAssertNotNil(negative)
        XCTAssertTrue(CGRect(x: 0, y: 0, width: 1000, height: 500).contains(negative!))
    }

    func testPointerShapes() {
        XCTAssertTrue(ScreenEngineCodes.validPointer(bytes: 32 * 32 * 4, width: 32, height: 32, hotX: 0, hotY: 0))
        XCTAssertFalse(ScreenEngineCodes.validPointer(bytes: 32 * 32 * 4 - 1, width: 32, height: 32, hotX: 0, hotY: 0))
        XCTAssertFalse(ScreenEngineCodes.validPointer(bytes: 385 * 10 * 4, width: 385, height: 10, hotX: 0, hotY: 0))
        XCTAssertFalse(ScreenEngineCodes.validPointer(bytes: 0, width: 0, height: 0, hotX: 0, hotY: 0))
        XCTAssertFalse(ScreenEngineCodes.validPointer(bytes: 32 * 32 * 4, width: 32, height: 32, hotX: 33, hotY: 0))
        XCTAssertFalse(ScreenEngineCodes.validPointer(bytes: 32 * 32 * 4, width: 32, height: 32, hotX: -1, hotY: 0))
    }
}

/// A stream in memory: what is sent to it is kept, and what `deliver` gives it is received.
private final class MemoryStream: ByteStream, @unchecked Sendable {
    private let lock = NSLock()
    private var inbox: [Data] = []
    private var finished = false
    private var waiting: (@Sendable (Data?, Bool, Error?) -> Void)?
    private(set) var sent = Data()
    private(set) var cancelled = false
    var onSent: (@Sendable (Int) -> Void)?
    var onTerminated: (@Sendable (Error?) -> Void)?

    func deliver(_ data: Data?) {
        lock.lock()
        if let data { inbox.append(data) } else { finished = true }
        lock.unlock()
        drain()
    }

    private func drain() {
        lock.lock()
        guard let completion = waiting else { return lock.unlock() }
        if !inbox.isEmpty {
            let next = inbox.removeFirst()
            waiting = nil
            lock.unlock()
            completion(next, false, nil)
        } else if finished {
            waiting = nil
            lock.unlock()
            completion(nil, true, nil)
        } else {
            lock.unlock()
        }
    }

    func receive(maximumLength: Int, completion: @escaping @Sendable (Data?, Bool, Error?) -> Void) {
        lock.lock(); waiting = completion; lock.unlock()
        drain()
    }

    func send(_ data: Data?, isComplete: Bool, completion: @escaping @Sendable (Error?) -> Void) {
        lock.lock()
        if let data { sent.append(data) }
        let count = sent.count, onSent = self.onSent
        lock.unlock()
        completion(nil)
        onSent?(count)
    }

    func cancel() { lock.lock(); cancelled = true; lock.unlock() }

    var sentCopy: Data { lock.lock(); defer { lock.unlock() }; return sent }
    var wasCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
}

final class FileDescriptorStreamTests: XCTestCase {
    /// The path a PC's bytes take on a Mac: the network's stream, spliced to one end of a socket pair in the app;
    /// the other end read and written by the helper.
    func testBytesCrossASocketPairBothWaysInOrder() throws {
        let pair = try XCTUnwrap(FileDescriptorStream.socketPair())
        let network = MemoryStream()
        let appEnd = FileDescriptorStream(descriptor: pair.0), helperEnd = FileDescriptorStream(descriptor: pair.1)
        let splice = StreamSplice(network, initialBytes: Data("first".utf8), appEnd) { _ in }

        // Network → helper: the bytes that came with the hand-over first, then 3 MiB more than the socket holds at once.
        var big = Data(count: 3 << 20)
        for index in stride(from: 0, to: big.count, by: 4093) { big[index] = UInt8(truncatingIfNeeded: index) }
        network.deliver(big)
        let expected = Data("first".utf8) + big
        let all = expectation(description: "the helper read everything")
        let received = Locked(Data())
        @Sendable func read() {
            helperEnd.receive(maximumLength: 64 * 1024) { data, complete, error in
                if let data { received.mutate { $0.append(data) } }
                if received.get().count >= expected.count { return all.fulfill() }
                if !complete, error == nil { read() }
            }
        }
        read()
        wait(for: [all], timeout: 20)
        XCTAssertEqual(received.get(), expected)

        // Helper → network.
        let back = expectation(description: "the network got the helper's bytes")
        back.assertForOverFulfill = false
        network.onSent = { count in if count >= 2 << 20 { back.fulfill() } }
        let reply = Data(repeating: 0x5A, count: 2 << 20)
        helperEnd.send(reply, isComplete: false) { XCTAssertNil($0) }
        wait(for: [back], timeout: 20)
        XCTAssertEqual(network.sentCopy, reply)
        splice.cancel()
        XCTAssertTrue(network.wasCancelled)
    }

    func testOneEndClosingEndsTheSplice() throws {
        let pair = try XCTUnwrap(FileDescriptorStream.socketPair())
        let network = MemoryStream()
        let appEnd = FileDescriptorStream(descriptor: pair.0), helperEnd = FileDescriptorStream(descriptor: pair.1)
        let ended = expectation(description: "the splice ended")
        let splice = StreamSplice(network, appEnd) { _ in ended.fulfill() }
        // The helper goes away (it crashed, or its session ended): the app's side learns at once.
        helperEnd.cancel()
        wait(for: [ended], timeout: 10)
        XCTAssertTrue(network.wasCancelled)
        _ = splice
    }

    func testTheNetworkEndingEndsTheHelpersRead() throws {
        let pair = try XCTUnwrap(FileDescriptorStream.socketPair())
        let network = MemoryStream()
        let appEnd = FileDescriptorStream(descriptor: pair.0), helperEnd = FileDescriptorStream(descriptor: pair.1)
        let splice = StreamSplice(network, appEnd) { _ in }
        let closed = expectation(description: "the helper's read ended")
        helperEnd.receive(maximumLength: 1024) { data, complete, error in
            if data == nil, complete || error != nil { closed.fulfill() }
        }
        network.deliver(nil)
        wait(for: [closed], timeout: 10)
        _ = splice
    }
}

/// A value behind a lock, for the tests' callbacks.
private final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func get() -> Value { lock.lock(); defer { lock.unlock() }; return value }
    func mutate(_ body: (inout Value) -> Void) { lock.lock(); body(&value); lock.unlock() }
}
