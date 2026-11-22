#if canImport(FreeRDP)
import Foundation
import PassthroughCore
import ScreenClient
import XCTest
@testable import RemoteDesktop

/// A stream that keeps what was sent and delivers nothing until told to end.
private final class RecordingStream: ByteStream, @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = Data()
    private var pending: (@Sendable (Data?, Bool, Error?) -> Void)?
    private var onSent: (@Sendable (Int) -> Void)?
    var onTerminated: (@Sendable (Error?) -> Void)?

    var sent: Data { lock.lock(); defer { lock.unlock() }; return bytes }

    func whenSent(_ body: @escaping @Sendable (Int) -> Void) { lock.lock(); onSent = body; lock.unlock() }

    func receive(maximumLength: Int, completion: @escaping @Sendable (Data?, Bool, Error?) -> Void) {
        lock.lock(); pending = completion; lock.unlock()
    }

    func send(_ data: Data?, isComplete: Bool, completion: @escaping @Sendable (Error?) -> Void) {
        lock.lock()
        if let data { bytes.append(data) }
        let count = bytes.count, onSent = self.onSent
        lock.unlock()
        onSent?(count)
        completion(nil)
    }

    func cancel() {}

    /// The far side sends nothing more.
    func end() {
        lock.lock(); let pending = self.pending; self.pending = nil; lock.unlock()
        pending?(nil, true, nil)
    }
}

/// The engine's connect over the in-process bridge: nothing else runs `freerdp_connect`, so a setting that makes
/// FreeRDP ask for a channel the engine leaves out (PreConnect fails, no byte is sent) would otherwise pass every test.
final class RemoteDesktopConnectTests: XCTestCase {
    /// The first bytes out are one X.224 connection request offering CredSSP: what a PC checks before it lets the
    /// phone through to Remote Desktop (windows/src/Passthrough.Core/Screen/RdpNegotiation.cs, `OffersNla`).
    func testTheFirstBytesAreAConnectionRequestOfferingNLA() {
        firstBytesOfferNLA(slowLink: false)
    }

    /// The same over a relay, where network auto-detect is on (patch 0002): it must not make the engine ask for a
    /// channel it leaves out, which stopped the connection before a byte went (edd933b).
    func testOverARelayTheConnectionStartsTheSame() {
        firstBytesOfferNLA(slowLink: true)
    }

    private func firstBytesOfferNLA(slowLink: Bool) {
        let stream = RecordingStream()
        let request = expectation(description: "a first PDU, or the end")
        request.assertForOverFulfill = false
        stream.whenSent { count in if count >= 19 { request.fulfill() } }
        let ended = expectation(description: "ended")
        let backend = RemoteDesktopBackend(
            stream: stream, certSHA256: String(repeating: "0", count: 64),
            login: ScreenLogin(username: "someone", password: "not a real password"),
            layout: .init(width: 1180, height: 820), clientName: "iPhone", slowLink: slowLink, queue: .main
        ) { event in
            guard case .ended = event else { return }
            request.fulfill()
            ended.fulfill()
        }
        backend.start()
        wait(for: [request], timeout: 10)

        let pdu = [UInt8](stream.sent)
        backend.close()
        stream.end()
        wait(for: [ended], timeout: 10)

        XCTAssertGreaterThanOrEqual(pdu.count, 4 + 7 + 8, "the engine sent \(pdu.count) bytes before the view ended")
        guard pdu.count >= 4 + 7 + 8 else { return }
        // TPKT: version 3, its whole length in bytes 2–3 (11 to 1024 for a first PDU).
        XCTAssertEqual(pdu[0], 0x03)
        let length = Int(pdu[2]) << 8 | Int(pdu[3])
        XCTAssertEqual(length, pdu.count, "one PDU and nothing after it")
        XCTAssertTrue((11...1024).contains(length))
        // X.224: a connection request whose length indicator covers the rest.
        XCTAssertEqual(Int(pdu[4]), length - 5)
        XCTAssertEqual(pdu[5] & 0xF0, 0xE0)
        // The last 8 bytes: an RDP negotiation request (type 1, length 8) whose protocols offer CredSSP.
        let tail = Array(pdu.suffix(8))
        XCTAssertEqual(tail[0], 0x01)
        XCTAssertEqual(Int(tail[2]) | Int(tail[3]) << 8, 8)
        let protocols = UInt32(tail[4]) | UInt32(tail[5]) << 8 | UInt32(tail[6]) << 16 | UInt32(tail[7]) << 24
        XCTAssertNotEqual(protocols & (0x2 | 0x8), 0, "protocols \(protocols) offer neither HYBRID nor HYBRID_EX")
    }
}
#endif
