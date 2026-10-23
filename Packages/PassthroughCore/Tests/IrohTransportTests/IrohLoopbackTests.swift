import XCTest
import PassthroughCore
import IrohLib
@testable import IrohTransport

/// Two in-process iroh endpoints talking over loopback UDP, relays off, so
/// nothing here needs the internet.
final class IrohLoopbackTests: XCTestCase {
    private var host: IrohEndpointHost!
    private var dialer: IrohDialer!

    override func setUp() async throws {
        host = try await IrohEndpointHost(secretKey: IrohEndpointHost.newSecretKey(), relayEnabled: false)
        dialer = try await IrohDialer(relayEnabled: false)
    }

    override func tearDown() async throws {
        await dialer?.shutdown()
        await host?.shutdown()
        host = nil
        dialer = nil
    }

    /// Dials the host by id, its direct addresses and its loopback port.
    private func dialHost() async throws -> IrohByteStream {
        try await dialer.connect(to: host.endpointID, relayURL: nil, addresses: host.directAddresses + host.loopbackAddresses, alpn: IrohShell.alpn)
    }

    func testLoopbackEcho() async throws {
        let host = self.host!
        let echoed = Task { () throws -> String in
            let incoming = try await host.accept(alpn: IrohShell.alpn)
            let stream = try await incoming.acceptStream()
            let line = try await stream.readLine()
            try await stream.write(line, isComplete: true)
            // Keep the connection up until the dialer has read the echo.
            _ = try await stream.readToEnd()
            stream.cancel()
            return String(decoding: line, as: UTF8.self)
        }

        let stream = try await dialHost()
        XCTAssertEqual(stream.remoteID, host.endpointID)
        XCTAssertEqual(stream.pathKind, .direct)
        XCTAssertNotNil(stream.remoteIP)
        try await stream.write(Data("hello\n".utf8), isComplete: false)
        let reply = try await stream.readToEnd()
        XCTAssertEqual(String(decoding: reply, as: UTF8.self), "hello\n")
        try await stream.write(nil, isComplete: true)

        let hostSaw = try await echoed.value
        XCTAssertEqual(hostSaw, "hello\n")
        stream.cancel()
    }

    func testStableIDFromSecretKey() async throws {
        let key = IrohEndpointHost.newSecretKey()
        XCTAssertEqual(key.count, 32)
        let first = try await IrohEndpointHost(secretKey: key, relayEnabled: false)
        let id = first.endpointID
        await first.shutdown()
        let second = try await IrohEndpointHost(secretKey: key, relayEnabled: false)
        XCTAssertEqual(second.endpointID, id)
        await second.shutdown()

        let other = try await IrohEndpointHost(secretKey: IrohEndpointHost.newSecretKey(), relayEnabled: false)
        XCTAssertNotEqual(other.endpointID, id)
        await other.shutdown()
    }

    func testBadSecretKeyThrows() async {
        do {
            _ = try await IrohEndpointHost(secretKey: Data(count: 5), relayEnabled: false)
            XCTFail("a 5-byte key must be rejected")
        } catch {}
    }

    func testCancelClosesBothSides() async throws {
        let host = self.host!
        let accepted = Task { () throws -> IrohByteStream in
            let incoming = try await host.accept(alpn: IrohShell.alpn)
            return try await incoming.acceptStream()
        }
        let stream = try await dialHost()
        let localTerminated = expectation(description: "dialer onTerminated must not fire after cancel")
        localTerminated.isInverted = true
        stream.onTerminated = { _ in localTerminated.fulfill() }
        // The host only sees the stream once the dialer has written to it.
        try await stream.write(Data("x".utf8), isComplete: false)
        let remote = try await accepted.value
        let remoteTerminated = expectation(description: "host onTerminated fires, clean (nil) for a cancel")
        remote.onTerminated = { error in
            XCTAssertNil(error)
            remoteTerminated.fulfill()
        }
        _ = try await remote.read(max: 1)

        let remoteRead = expectation(description: "host's pending receive ends")
        remote.receive(maximumLength: 1024) { data, isComplete, error in
            XCTAssertTrue((data ?? Data()).isEmpty)
            XCTAssertTrue(isComplete || error != nil)
            remoteRead.fulfill()
        }

        stream.cancel()
        await fulfillment(of: [remoteRead, remoteTerminated], timeout: 10)

        let sendAfterCancel = expectation(description: "send after cancel fails")
        stream.send(Data("y".utf8), isComplete: false) { error in
            XCTAssertNotNil(error)
            sendAfterCancel.fulfill()
        }
        await fulfillment(of: [sendAfterCancel, localTerminated], timeout: 1)
    }

    func testReceiveHonoursMaximumLength() async throws {
        let host = self.host!
        let accepted = Task { () throws -> IrohByteStream in
            try await host.accept(alpn: IrohShell.alpn).acceptStream()
        }
        let stream = try await dialHost()
        try await stream.write(Data(repeating: 7, count: 100), isComplete: true)
        let remote = try await accepted.value
        var total = 0
        while true {
            let (chunk, complete) = try await remote.receiveChunk(max: 10)
            XCTAssertLessThanOrEqual(chunk.count, 10)
            total += chunk.count
            if complete { break }
        }
        XCTAssertEqual(total, 100)
        remote.cancel()
        stream.cancel()
    }

    /// The phase 1 pattern `send(error, isComplete: true) { stream.cancel() }`
    /// must still deliver the line before the connection goes.
    func testCancelInFinalSendCompletionStillDelivers() async throws {
        let host = self.host!
        let line = Data("{\"t\":\"error\"}\n".utf8)
        let hostDone = Task { () throws -> Void in
            let stream = try await host.accept(alpn: IrohShell.alpn).acceptStream()
            _ = try await stream.read(max: 64)
            stream.send(line, isComplete: true) { _ in stream.cancel() }
        }
        let stream = try await dialHost()
        try await stream.write(Data("hi\n".utf8), isComplete: false)
        try await hostDone.value
        let received = try await stream.readToEnd()
        XCTAssertEqual(received, line)
        stream.cancel()
    }

    func testReadAllocationIsCapped() async throws {
        let host = self.host!
        let accepted = Task { () throws -> IrohByteStream in
            try await host.accept(alpn: IrohShell.alpn).acceptStream()
        }
        let stream = try await dialHost()
        try await stream.write(Data(repeating: 1, count: 200_000), isComplete: true)
        let remote = try await accepted.value
        var total = 0
        while true {
            let (chunk, complete) = try await remote.receiveChunk(max: 1 << 20)
            XCTAssertLessThanOrEqual(chunk.count, IrohByteStream.maxReadLength)
            total += chunk.count
            if complete { break }
        }
        XCTAssertEqual(total, 200_000)
        remote.cancel()
        stream.cancel()
    }

    func testCancelBeforeAcceptStreamRefuses() async throws {
        let host = self.host!
        let incomingTask = Task { try await host.accept(alpn: IrohShell.alpn) }
        let dial = Task { [dialer = dialer!, id = host.endpointID, addresses = host.loopbackAddresses] in
            try await dialer.connect(to: id, relayURL: nil, addresses: addresses, alpn: IrohShell.alpn)
        }
        let incoming = try await incomingTask.value
        incoming.cancel()
        do {
            _ = try await incoming.acceptStream()
            XCTFail("acceptStream after cancel must throw")
        } catch {
            XCTAssertEqual(error as? IrohTransportError, .cancelled)
        }
        do {
            let stream = try await dial.value
            stream.cancel()
            XCTFail("a refused dial must fail")
        } catch {}
    }

    func testRelayModeMapping() throws {
        XCTAssertGreaterThan(try IrohRelayConfig(url: nil).relayMode().relayMap().len(), 0, "n0 defaults")
        let custom = try IrohRelayConfig(url: "https://relay.example.org/", token: "secret").relayMode().relayMap()
        XCTAssertEqual(custom.urls(), ["https://relay.example.org/"])
        XCTAssertEqual(try custom.get(url: "https://relay.example.org/")?.authToken, "secret")
        XCTAssertNil(try IrohRelayConfig(url: "https://relay.example.org/").relayMode().relayMap().get(url: "https://relay.example.org/")?.authToken)
    }

    func testRelayConfigIsCodable() throws {
        let config = IrohRelayConfig(url: "https://relay.example.org/", token: "t")
        let decoded = try JSONDecoder().decode(IrohRelayConfig.self, from: JSONEncoder().encode(config))
        XCTAssertEqual(decoded, config)
        XCTAssertNil(IrohRelayConfig(url: nil, token: nil).url)
        XCTAssertEqual(IrohShell.alpn, "passthrough/shell/1")
    }
}

// MARK: - async helpers over the callback API

private struct StreamEnded: Error {}

extension ByteStream {
    func receiveChunk(max: Int) async throws -> (Data, Bool) {
        try await withCheckedThrowingContinuation { cont in
            receive(maximumLength: max) { data, isComplete, error in
                if let error { cont.resume(throwing: error) } else { cont.resume(returning: (data ?? Data(), isComplete)) }
            }
        }
    }

    func read(max: Int) async throws -> Data {
        let (data, complete) = try await receiveChunk(max: max)
        if data.isEmpty && complete { throw StreamEnded() }
        return data
    }

    func readLine() async throws -> Data {
        var line = Data()
        while !line.contains(UInt8(ascii: "\n")) { line += try await read(max: 64) }
        return line
    }

    func readToEnd() async throws -> Data {
        var all = Data()
        while true {
            let (data, complete) = try await receiveChunk(max: 4096)
            all += data
            if complete { return all }
        }
    }

    func write(_ data: Data?, isComplete: Bool) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            send(data, isComplete: isComplete) { error in
                if let error { cont.resume(throwing: error) } else { cont.resume() }
            }
        }
    }
}
