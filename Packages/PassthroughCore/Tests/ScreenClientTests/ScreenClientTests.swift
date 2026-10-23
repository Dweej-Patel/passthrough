import CryptoKit
import Foundation
import Network
import XCTest
import PassthroughCore
@testable import ScreenClient

final class ModArithTests: XCTestCase {
    private func hex(_ string: String) -> [UInt8] {
        stride(from: 0, to: string.count, by: 2).map {
            let start = string.index(string.startIndex, offsetBy: $0)
            return UInt8(string[start..<string.index(start, offsetBy: 2)], radix: 16)!
        }
    }

    func testSmallNumbers() {
        XCTAssertEqual(ModArith.modPow(base: [4], exponent: [13], modulus: [0x01, 0xF1]), [0x01, 0xBD])   // 4^13 mod 497 = 445
        XCTAssertEqual(ModArith.modPow(base: [0], exponent: [5], modulus: [7]), [0])
        XCTAssertEqual(ModArith.modPow(base: [3], exponent: [0], modulus: [7]), [1])
    }

    /// 1024 bits, as the Mac's login uses; expected value from Python's `pow`.
    func testMatchesPythonAt1024Bits() {
        let m = hex("a170b33839263059f28c105d1fb17c2390c192cfd3ac94af0f21ddb66cad4a268d116ece1738f7d93d9c172411e20b8f6b0d549b6f03675a1600a35a099950d836f675cc81e74ef5e8e25d940ed904759531985d5d9dc9f81818e811892f902bd23f0824128b2f330c5c7fd0a6a3a4506513270e269e0d37f2a74de452e6b439")
        let b = hex("018f135d5f557203301850c5a38fd547923a736994e3bf911a61dbe22e44158bae97ba94d0eda82f8f6d05584ef8aa38922766581e27a1c08a6a63ec24ede6a46b4cb2424a23d5962217beaddbc496cb8e81973e0becd7b03898d190f9ebdacc0cb1e29c658cda1495e60af593bd04cf0fd630f1f29d0da9953f48f1a09f76b5")
        let e = hex("57ee05e00902c77ebff206867347214cdd2055930d6eaf14f4733f3e7d1bfbc7a2ea20b2f14c942e05319acb5c74273f98e2774cbd87ad5c90a9587403e430ec66a78795e761d17731af10506bf2efc6f877186d76b07e881ed162ae2eb1547f15052434b9b5df9e7769b10f4205b4907a70c31012f037b64ce4228c38fb29")
        let expected = hex("0b243d34ce6ad40c361dba3c62f2b4e6884d4c69d7f4764031122c44454419b51033878e432219d3b819bb6897cb551ba3795472405cae99b797c298c9242ed2228cfcc2bcff566a65f6e06510dccd97a5cdcf534bab309f6b4ca1d013c8b8ecdafb55491e3f9a3ba3481140df6c0fef12e23030a49add33659e3c70b9c182a0")
        XCTAssertEqual(ModArith.modPow(base: b, exponent: e, modulus: m), expected)
    }
}

final class AppleLoginTests: XCTestCase {
    /// The Mac's side of the exchange: it recovers the name and password.
    func testTheMacCanReadTheLogin() throws {
        // RFC 2409's 768-bit group, generator 2: the Mac sends its own, but any safe prime will do.
        let prime = [UInt8](Data(base64Encoded: "///////////JD9qiIWjCNMTGYouA3BzRKQJOCIpnzHQCC76mOxObIlFKCHmONATd75UZs806QxswKwpt8l8UN0/hNW1tUcJF5IW1dmJefsb0TELppjo2IP//////////")!)
        let generator: [UInt8] = [0, 2]
        var macSecret = [UInt8](repeating: 0, count: prime.count - 1)
        _ = SecRandomCopyBytes(kSecRandomDefault, macSecret.count, &macSecret)
        let macPublic = ModArith.modPow(base: generator, exponent: macSecret, modulus: prime)

        let reply = [UInt8](try AppleLogin.response(generator: generator, prime: prime, peerKey: macPublic,
                                                    username: "dweej", password: "correct horse"))
        XCTAssertEqual(reply.count, 128 + prime.count)
        let phonePublic = Array(reply[128...])
        let shared = ModArith.modPow(base: phonePublic, exponent: macSecret, modulus: prime)
        let key = Array(Insecure.MD5.hash(data: shared))
        let fields = try AppleLogin.aes128ECB(Array(reply[0..<128]), key: key, decrypt: true)
        func field(_ offset: Int) -> String { String(decoding: fields[offset...].prefix { $0 != 0 }.prefix(64), as: UTF8.self) }
        XCTAssertEqual(field(0), "dweej")
        XCTAssertEqual(field(64), "correct horse")
    }

    func testRefusesParametersOutOfRange() {
        XCTAssertThrowsError(try AppleLogin.response(generator: [0, 2], prime: [UInt8](repeating: 0xFF, count: 15) + [0xFE],
                                                     peerKey: [UInt8](repeating: 1, count: 16), username: "a", password: "b"),
                             "an even modulus")
        XCTAssertThrowsError(try AppleLogin.response(generator: [0, 2], prime: [UInt8](repeating: 0x7F, count: 16),
                                                     peerKey: [UInt8](repeating: 0xFF, count: 16), username: "a", password: "b"),
                             "a peer key above the prime")
    }
}

final class FramebufferTests: XCTestCase {
    private func cpixel(_ value: UInt32) -> [UInt8] { [UInt8(value & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value >> 16 & 0xFF)] }

    func testZRLETileKinds() throws {
        let fb = Framebuffer(width: 4, height: 2)
        // Solid.
        try fb.zrle(x: 0, y: 0, w: 4, h: 2, Data([1] + cpixel(0x112233)))
        XCTAssertEqual(fb.pixel(x: 3, y: 1), 0x112233)
        // Raw.
        try fb.zrle(x: 0, y: 0, w: 2, h: 1, Data([0] + cpixel(0xAA0000) + cpixel(0x00BB00)))
        XCTAssertEqual([fb.pixel(x: 0, y: 0), fb.pixel(x: 1, y: 0)], [0xAA0000, 0x00BB00])
        // Packed palette, 2 colours, 1 bit each: rows 1010 and 0101.
        try fb.zrle(x: 0, y: 0, w: 4, h: 2, Data([2] + cpixel(0x000001) + cpixel(0x000002) + [0b1010_0000, 0b0101_0000]))
        XCTAssertEqual((0..<4).map { fb.pixel(x: $0, y: 0) }, [2, 1, 2, 1])
        XCTAssertEqual((0..<4).map { fb.pixel(x: $0, y: 1) }, [1, 2, 1, 2])
        // Plain RLE: 5 of one, 3 of another.
        try fb.zrle(x: 0, y: 0, w: 4, h: 2, Data([128] + cpixel(7) + [4] + cpixel(9) + [2]))
        XCTAssertEqual((0..<4).map { fb.pixel(x: $0, y: 0) } + (0..<4).map { fb.pixel(x: $0, y: 1) }, [7, 7, 7, 7, 7, 9, 9, 9])
        // Palette RLE: palette of 2; index 0 run of 6, then index 1 once, index 0 once.
        try fb.zrle(x: 0, y: 0, w: 4, h: 2, Data([130] + cpixel(5) + cpixel(6) + [0x80, 5, 1, 0]))
        XCTAssertEqual((0..<4).map { fb.pixel(x: $0, y: 0) } + (0..<4).map { fb.pixel(x: $0, y: 1) }, [5, 5, 5, 5, 5, 5, 6, 5])
    }

    func testZRLESpansTilesAndRejectsBadInput() throws {
        let fb = Framebuffer(width: 70, height: 3)
        // Two tiles across (64 + 6), each solid.
        try fb.zrle(x: 0, y: 0, w: 70, h: 3, Data([1] + cpixel(1) + [1] + cpixel(2)))
        XCTAssertEqual(fb.pixel(x: 63, y: 2), 1)
        XCTAssertEqual(fb.pixel(x: 64, y: 0), 2)
        XCTAssertThrowsError(try fb.zrle(x: 0, y: 0, w: 70, h: 3, Data([1] + cpixel(1))), "second tile missing")
        XCTAssertThrowsError(try fb.zrle(x: 0, y: 0, w: 4, h: 2, Data([128] + cpixel(7) + [20])), "run past the tile")
        XCTAssertThrowsError(try fb.zrle(x: 68, y: 0, w: 4, h: 1, Data([1] + cpixel(1))), "outside the screen")
    }

    func testCopyRectOverlapping() throws {
        let fb = Framebuffer(width: 3, height: 3)
        var raw = [UInt8]()
        for value in UInt32(1)...9 { raw += [UInt8(value), 0, 0, 0] }
        try raw.withUnsafeBytes { try fb.raw(x: 0, y: 0, w: 3, h: 3, $0) }
        try fb.copy(fromX: 0, fromY: 0, x: 1, y: 1, w: 2, h: 2)
        XCTAssertEqual((0..<3).map { fb.pixel(x: $0, y: 1) }, [4, 1, 2])
        XCTAssertEqual((0..<3).map { fb.pixel(x: $0, y: 2) }, [7, 4, 5])
    }

    func testKeysyms() {
        XCTAssertEqual(RFBKeys.keysym(for: "a"), 0x61)
        XCTAssertEqual(RFBKeys.keysym(for: "é"), 0xE9)
        XCTAssertEqual(RFBKeys.keysym(for: "\n"), RFBKeys.returnKey)
        XCTAssertEqual(RFBKeys.keysym(for: "€"), 0x0100_20AC)
        XCTAssertEqual(RFBKeys.function(12), 0xFFC9)
    }
}

/// The client against a fake Screen Sharing over loopback: login, pixel
/// format and encodings, a ZRLE and a Raw update, then input.
final class RFBClientTests: XCTestCase {
    /// A scripted server: answers what the client sends with the next step.
    private final class FakeServer: @unchecked Sendable {
        let listener: NWListener
        let received = Locked(Data())
        let connection = Locked<NWConnection?>(nil)
        var port: NWEndpoint.Port { listener.port! }

        init(_ test: XCTestCase, script: @escaping @Sendable (NWConnection, FakeServer) -> Void) throws {
            let params = NWParameters.tcp
            params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
            listener = try NWListener(using: params)
            let ready = test.expectation(description: "listening")
            listener.stateUpdateHandler = { if case .ready = $0 { ready.fulfill() } }
            listener.newConnectionHandler = { [self] connection in
                self.connection.set(connection)
                connection.start(queue: .global())
                script(connection, self)
                read(connection)
            }
            listener.start(queue: .global())
            test.wait(for: [ready], timeout: 5)
        }

        private func read(_ connection: NWConnection) {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [self] data, _, complete, error in
                if let data { received.set(received.get() + data) }
                if !complete && error == nil { read(connection) }
            }
        }

        /// Waits (polling) until the client has sent `count` bytes in all.
        func waitFor(_ count: Int) {
            let deadline = Date().addingTimeInterval(5)
            while received.get().count < count && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        }

        func stop() { connection.get()?.cancel(); listener.cancel() }
    }

    private func dial(_ server: FakeServer) -> ConnectionStream {
        ConnectionStream(NWConnection(host: "127.0.0.1", port: server.port, using: .tcp), queue: .global())
    }

    private final class Events: @unchecked Sendable {
        let lock = NSLock()
        var all: [RFBClient.Event] = []
        func add(_ event: RFBClient.Event) { lock.lock(); all.append(event); lock.unlock() }
        var snapshot: [RFBClient.Event] { lock.lock(); defer { lock.unlock() }; return all }
    }

    private func waitUntil(_ message: String, _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(5)
        while !condition() {
            if Date() > deadline { return XCTFail("timed out: \(message)") }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
    }

    func testSessionWithoutLogin() throws {
        let deflater = Deflater()
        let server = try FakeServer(self) { connection, server in
            DispatchQueue.global().async {
                connection.send(content: Data("RFB 003.008\n".utf8), completion: .idempotent)
                server.waitFor(12)
                connection.send(content: Data([1, 1]), completion: .idempotent)          // one type: None
                server.waitFor(13)
                connection.send(content: Data([0, 0, 0, 0]), completion: .idempotent)    // OK
                server.waitFor(14)                                                         // ClientInit
                var serverInit: [UInt8] = [0, 70, 0, 2] + [UInt8](repeating: 0, count: 16) + [0, 0, 0, 3]
                serverInit += Array("Mac".utf8)
                connection.send(content: Data(serverInit), completion: .idempotent)
                // SetPixelFormat (20) + SetEncodings (4 + 4·5) + FramebufferUpdateRequest (10).
                server.waitFor(14 + 20 + 24 + 10)
                // One update: a ZRLE rect over both tiles (solid, solid) and a 1×1 raw pixel.
                let zrle = deflater.deflated(Data([1, 0x33, 0x22, 0x11, 1, 0x66, 0x55, 0x44]))
                var update: [UInt8] = [0, 0, 0, 2]
                update += [0, 0, 0, 0, 0, 70, 0, 2] + RFBClient.bytes(UInt32(16)) + RFBClient.bytes(UInt32(zrle.count)) + [UInt8](zrle)
                update += [0, 1, 0, 1, 0, 1, 0, 1] + RFBClient.bytes(UInt32(0)) + [0xCC, 0xBB, 0xAA, 0]
                connection.send(content: Data(update), completion: .idempotent)
            }
        }
        addTeardownBlock { server.stop() }
        let events = Events()
        let client = RFBClient(stream: dial(server), login: .init(username: "", password: ""), queue: .global()) { events.add($0) }
        client.start()
        waitUntil("a frame") { events.snapshot.contains { if case .frame = $0 { true } else { false } } }
        guard case .connected(70, 2, "Mac")? = events.snapshot.first else { return XCTFail("\(events.snapshot)") }
        guard case .frame(let image)? = events.snapshot.last else { return XCTFail("no frame") }
        XCTAssertEqual(image.width, 70)
        let pixels = image.dataProvider!.data! as Data
        func pixel(_ x: Int, _ y: Int) -> [UInt8] { Array(pixels[(y * 70 + x) * 4..<(y * 70 + x) * 4 + 3]) }
        XCTAssertEqual(pixel(0, 0), [0x33, 0x22, 0x11])
        XCTAssertEqual(pixel(65, 0), [0x66, 0x55, 0x44])
        XCTAssertEqual(pixel(1, 1), [0xCC, 0xBB, 0xAA])

        let sent = [UInt8](server.received.get())
        XCTAssertEqual(Array(sent[0..<12]), Array("RFB 003.008\n".utf8))
        XCTAssertEqual(Array(sent[12..<14]), [1, 1], "chose None, then shared ClientInit")
        XCTAssertEqual(Array(sent[14..<18]), [0, 0, 0, 0])
        XCTAssertEqual(Array(sent[18..<22]), [32, 24, 0, 1], "32 bpp, depth 24, little-endian, true colour")

        // After the update: another (incremental) request, then input.
        server.waitFor(14 + 20 + 24 + 10 + 10)
        client.pointer(x: 5, y: 1, buttons: .left)
        client.key(RFBKeys.returnKey, down: true)
        server.waitFor(14 + 20 + 24 + 10 + 10 + 6 + 8)
        let tail = [UInt8](server.received.get().suffix(14))
        XCTAssertEqual(tail, [5, 1, 0, 5, 0, 1] + [4, 1, 0, 0, 0, 0, 0xFF, 0x0D])

        client.close()
        waitUntil("closed") { events.snapshot.contains { if case .closed(nil) = $0 { true } else { false } } }
    }

    func testLoginRefusalCarriesTheReason() throws {
        let server = try FakeServer(self) { connection, server in
            DispatchQueue.global().async {
                connection.send(content: Data("RFB 003.889\n".utf8), completion: .idempotent)
                server.waitFor(12)
                connection.send(content: Data([1, 30]), completion: .idempotent)
                server.waitFor(13)
                let prime = [UInt8](repeating: 0xFF, count: 16)
                let params: [UInt8] = [0, 2, 0, 16] + prime + [UInt8](repeating: 0x01, count: 16)
                connection.send(content: Data(params), completion: .idempotent)
                server.waitFor(13 + 128 + 16)
                let reason = Array("Authentication failure".utf8)
                connection.send(content: Data([0, 0, 0, 1] + RFBClient.bytes(UInt32(reason.count)) + reason), completion: .idempotent)
            }
        }
        addTeardownBlock { server.stop() }
        let events = Events()
        let client = RFBClient(stream: dial(server), login: .init(username: "me", password: "wrong"), queue: .global()) { events.add($0) }
        client.start()
        waitUntil("refused") { !events.snapshot.isEmpty }
        guard case .closed(.loginFailed("Authentication failure"))? = events.snapshot.first else { return XCTFail("\(events.snapshot)") }
    }

    func testAnUnknownMessageIsAProtocolError() throws {
        let server = try FakeServer(self) { connection, server in
            DispatchQueue.global().async {
                connection.send(content: Data("RFB 003.008\n".utf8), completion: .idempotent)
                server.waitFor(12)
                connection.send(content: Data([1, 1, 0, 0, 0, 0]), completion: .idempotent)
                server.waitFor(14)
                connection.send(content: Data([0, 1, 0, 1] + [UInt8](repeating: 0, count: 16) + [0, 0, 0, 0] + [99]), completion: .idempotent)
            }
        }
        addTeardownBlock { server.stop() }
        let events = Events()
        let client = RFBClient(stream: dial(server), login: .init(username: "", password: ""), queue: .global()) { events.add($0) }
        client.start()
        waitUntil("failed") { events.snapshot.contains { if case .closed = $0 { true } else { false } } }
        XCTAssertTrue(events.snapshot.contains { if case .closed(.protocolError("message 99")) = $0 { true } else { false } })
    }
}
