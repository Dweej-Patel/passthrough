#if os(macOS)
import Foundation
import Network
import XCTest
import PassthroughCore
import PhoneTransport
import TestSupport
@testable import IrohTransport
@testable import ShellHost

/// The remote shell over iroh, end to end on loopback with relays off: the
/// `hello` line, the shell-key challenge shared with the TLS listener, and a
/// real `/bin/sh` behind it.
@available(macOS 15, *)
final class IrohShellListenerTests: XCTestCase {
    private var directory: URL!
    private var store: TranscriptStore!
    private var manager: ShellSessionManager!
    private var host: IrohEndpointHost!
    private var dialer: IrohDialer!
    private let key = WirelessLink.randomBytes(32)

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("IrohShellListenerTests-\(UUID().uuidString)", isDirectory: true)
        store = try TranscriptStore(directory: directory)
        manager = ShellSessionManager(
            transcripts: store,
            command: { ("/bin/sh", []) },
            environment: { ["PATH": "/usr/bin:/bin", "TERM": "xterm-256color", "PS1": "$ "] },
            directory: URL(fileURLWithPath: "/tmp"))
        host = try await IrohEndpointHost(secretKey: IrohEndpointHost.newSecretKey(), relayEnabled: false)
        dialer = try await IrohDialer(relayEnabled: false)
    }

    override func tearDown() async throws {
        manager?.closeAll()
        await dialer?.shutdown()
        await host?.shutdown()
        dialer = nil
        host = nil
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    // MARK: Helpers

    private static let sampleInfo: ShellEnvelope = {
        var info = ShellEnvelope(t: ShellEnvelope.macInfo)
        info.irohID = String(repeating: "ab", count: 32)
        info.irohRelay = "https://relay.example.com/"
        info.relayToken = "test-token"
        info.addresses = ["192.168.1.2"]
        return info
    }()

    private func startIroh(keys: Locked<[String: Data]>? = nil, events: Locked<[String]>? = nil,
                           macInfo: @escaping @Sendable () -> ShellEnvelope? = { nil },
                           handshakeTimeout: TimeInterval = WirelessLink.handshakeTimeout) -> IrohShellListener {
        let keys = keys ?? Locked(["phone-1": key])
        let listener = IrohShellListener(host: host, manager: manager, transcripts: store,
                                         shellKeys: { keys.get()[$0].map { [$0] } ?? [] },
                                         phoneLabel: { $0 == "phone-1" ? "Test iPhone" : "Other Phone" },
                                         macInfo: macInfo, handshakeTimeout: handshakeTimeout)
        if let events { listener.onSessionEvent = { events.set(events.get() + [$0]) } }
        listener.start()
        addTeardownBlock { listener.stop() }
        return listener
    }

    private func startTLS(identity: MacIdentity, macInfo: @escaping @Sendable () -> ShellEnvelope? = { nil }) async -> ShellListener {
        let key = self.key
        let listener = ShellListener(identity: identity, port: 0, advertise: false, manager: manager, transcripts: store,
                                     shellKeys: { $0 == "phone-1" ? [key] : [] },
                                     phoneLabel: { _ in "Test iPhone" },
                                     peerAllowed: ShellAddressPolicy.isAllowed, macInfo: macInfo)
        let listening = expectation(description: "listening")
        try! listener.start { _ in listening.fulfill() }
        await fulfillment(of: [listening], timeout: 5)
        addTeardownBlock { listener.stop() }
        return listener
    }

    /// A raw iroh stream to the host (nothing written yet).
    private func dial() async throws -> IrohByteStream {
        let stream = try await dialer.connect(to: host.endpointID, relayURL: nil,
                                              addresses: host.directAddresses + host.loopbackAddresses, alpn: IrohShell.alpn)
        addTeardownBlock { stream.cancel() }
        return stream
    }

    private func irohPeer() async throws -> LinePeer {
        LinePeer(try await dial())
    }

    private func tlsPeer(_ listener: ShellListener, identity: MacIdentity) -> LinePeer {
        let connection = NWConnection(to: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: listener.port!)!),
                                      using: WirelessLink.pinnedClientParameters(pin: identity.fingerprint, peerToPeer: false))
        let stream = ConnectionStream(connection, queue: .global())
        addTeardownBlock { stream.cancel() }
        return LinePeer(stream)
    }

    /// Answers the challenge (after `hello` on iroh) and waits for `ready`.
    private func authorize(_ peer: LinePeer, hello: Bool = true, phoneID: String = "phone-1", key: Data? = nil) async {
        if hello { peer.send(ShellEnvelope(t: ShellEnvelope.hello)) }
        await eventually("challenge") { peer.first(ShellEnvelope.challenge) != nil }
        guard let nonce = peer.first(ShellEnvelope.challenge)?.nonce.flatMap({ Data(base64Encoded: $0) }) else { return }
        var proof = ShellEnvelope(t: ShellEnvelope.proof)
        proof.phoneID = phoneID
        proof.mac = RemoteShell.proof(shellKey: key ?? self.key, nonce: nonce).base64EncodedString()
        peer.send(proof)
    }

    private func ready(_ peer: LinePeer, phoneID: String = "phone-1", key: Data? = nil, hello: Bool = true) async {
        await authorize(peer, hello: hello, phoneID: phoneID, key: key)
        await eventually("ready") { peer.first(ShellEnvelope.ready) != nil }
    }

    private func eventually(_ what: String, timeout: TimeInterval = 5, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return XCTFail("timed out: \(what)") }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private func pause(_ seconds: TimeInterval) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    // MARK: Handshake

    func testIrohHandshakeOpenInputOutput() async throws {
        let events = Locked<[String]>([])
        _ = startIroh(events: events)
        let peer = try await irohPeer()
        await ready(peer)
        await eventually("session list") { peer.first(ShellEnvelope.sessions) != nil }
        XCTAssertEqual(peer.kinds.prefix(3), [ShellEnvelope.challenge, ShellEnvelope.ready, ShellEnvelope.sessions],
                       "no macInfo when the Mac has none to give")

        var open = ShellEnvelope(t: ShellEnvelope.open)
        open.cols = 80; open.rows = 24
        peer.send(open)
        await eventually("opened") { peer.first(ShellEnvelope.opened) != nil }
        let id = try XCTUnwrap(peer.first(ShellEnvelope.opened)?.session)
        var input = ShellEnvelope(t: ShellEnvelope.input)
        input.session = id
        input.data = Data("echo over-iroh-$((6*7))\n".utf8).base64EncodedString()
        peer.send(input)
        await eventually("output", timeout: 10) { peer.output(id).contains("over-iroh-42\r\n") }
        XCTAssertTrue(events.get().contains("Test iPhone opened a session"))
        XCTAssertFalse(events.get().joined().contains("over-iroh"), "events never carry terminal bytes")
        XCTAssertFalse(peer.closed)
    }

    func testWrongKeyRefusedOverIroh() async throws {
        _ = startIroh()
        let peer = try await irohPeer()
        await authorize(peer, key: WirelessLink.randomBytes(32))
        await eventually("closed", timeout: 8) { peer.closed }
        XCTAssertNil(peer.first(ShellEnvelope.ready))
        XCTAssertEqual(peer.lines.get().filter { $0.t == ShellEnvelope.error }.map(\.reason), [ShellError.notAuthorized.rawValue])

        let stranger = try await irohPeer()
        await authorize(stranger, phoneID: "stranger")
        await eventually("stranger closed", timeout: 8) { stranger.closed }
        XCTAssertNil(stranger.first(ShellEnvelope.ready))
    }

    /// Without `hello` first there is no challenge at all; nor for a first
    /// line longer than a proof's worth.
    func testMissingHelloRefused() async throws {
        _ = startIroh()
        let skipped = try await irohPeer()
        skipped.send(ShellEnvelope(t: ShellEnvelope.ping))
        await eventually("closed without hello", timeout: 5) { skipped.closed }
        XCTAssertTrue(skipped.lines.get().isEmpty, "not even a challenge")

        let proofFirst = try await irohPeer()
        var proof = ShellEnvelope(t: ShellEnvelope.proof)
        proof.phoneID = "phone-1"
        proof.mac = Data(count: 32).base64EncodedString()
        proofFirst.send(proof)
        await eventually("closed on proof first", timeout: 5) { proofFirst.closed }
        XCTAssertTrue(proofFirst.lines.get().isEmpty)

        let overlong = try await irohPeer()
        overlong.sendRaw(Data(repeating: 0x61, count: ShellListener.proofLineLimit + 4096))
        await eventually("closed on an overlong first line", timeout: WirelessLink.handshakeTimeout / 2) { overlong.closed }
        XCTAssertTrue(overlong.lines.get().isEmpty)
    }

    /// `message` as one newline-terminated line over the proof limit: valid
    /// JSON, padded with whitespace, so only the length is wrong.
    private static func padded(_ message: ShellEnvelope) -> Data {
        let line = try! message.encodedLine()
        return Data("{".utf8) + Data(repeating: 0x20, count: ShellListener.proofLineLimit + 100) + line.dropFirst()
    }

    /// The 4096-byte limit on `hello` and the proof is hard: a line that ends
    /// in a newline but runs over it is refused even though it is otherwise
    /// valid (one read can deliver more than readLine's soft limit).
    func testOversizedNewlineTerminatedLinesAreRefused() async throws {
        _ = startIroh()
        let longHello = try await irohPeer()
        longHello.sendRaw(Self.padded(ShellEnvelope(t: ShellEnvelope.hello)))
        await eventually("closed on a long hello", timeout: WirelessLink.handshakeTimeout / 2) { longHello.closed }
        XCTAssertNil(longHello.first(ShellEnvelope.challenge), "no challenge for an oversized hello")

        let identity = try (try? makeTestIdentity()) ?? makeTestIdentity()
        let tls = await startTLS(identity: identity)
        for (name, peer, hello) in [("iroh", try await irohPeer(), true), ("TLS", tlsPeer(tls, identity: identity), false)] {
            if hello { peer.send(ShellEnvelope(t: ShellEnvelope.hello)) }
            await eventually("\(name) challenge") { peer.first(ShellEnvelope.challenge) != nil }
            guard let nonce = peer.first(ShellEnvelope.challenge)?.nonce.flatMap({ Data(base64Encoded: $0) }) else { continue }
            var proof = ShellEnvelope(t: ShellEnvelope.proof)
            proof.phoneID = "phone-1"
            proof.mac = RemoteShell.proof(shellKey: key, nonce: nonce).base64EncodedString()
            peer.sendRaw(Self.padded(proof))
            await eventually("\(name) closed on a long proof", timeout: WirelessLink.handshakeTimeout / 2) { peer.closed }
            XCTAssertNil(peer.first(ShellEnvelope.ready), "\(name): a correct but oversized proof is not accepted")
        }
    }

    /// A peer that connects and never writes (so the stream is never even
    /// accepted), or says hello and never proves anything, loses its slot at
    /// the timeout; a late write after that reaches nobody.
    func testSilentIrohPeerReleasesSlot() async throws {
        let listener = startIroh(handshakeTimeout: 1)
        let silent = try await dial()
        let silentPeer = LinePeer(silent, reading: false)
        let mute = try await irohPeer()
        mute.send(ShellEnvelope(t: ShellEnvelope.hello))
        await eventually("both hold a slot") { listener.pendingHandshakes == 2 }
        await eventually("mute peer challenged") { mute.first(ShellEnvelope.challenge) != nil }

        await eventually("slots released at the timeout", timeout: 4) { listener.pendingHandshakes == 0 }
        await eventually("mute peer closed") { mute.closed }

        // The silent peer's accept is abandoned: writing now gets no challenge.
        silentPeer.send(ShellEnvelope(t: ShellEnvelope.hello))
        silentPeer.startReading()
        await eventually("late peer closed", timeout: 5) { silentPeer.closed }
        XCTAssertTrue(silentPeer.lines.get().isEmpty)
        XCTAssertEqual(listener.pendingHandshakes, 0)

        // The listener still serves others.
        let fresh = try await irohPeer()
        await ready(fresh)
    }

    /// Relayed attempts share one bucket of 8; direct ones get 2 per address
    /// (a public one: per /24); 12 at most in all, plus 4 for proven addresses.
    func testRelayBucketCap() {
        XCTAssertEqual(IrohShellListener.bucket(path: .relay, ip: nil).key, "relay")
        XCTAssertEqual(IrohShellListener.bucket(path: .relay, ip: nil).max, 8)
        XCTAssertEqual(IrohShellListener.bucket(path: .unknown, ip: nil).key, "relay", "an unknown path counts as relayed")
        XCTAssertEqual(IrohShellListener.bucket(path: .direct, ip: "203.0.113.5").key, "203.0.113.5")
        XCTAssertNil(IrohShellListener.bucket(path: .direct, ip: "203.0.113.5").max, "direct paths use the per-host cap")

        let queue = DispatchQueue(label: "limiter")
        queue.sync {
            let limiter = HandshakeLimiter(queue: queue, timeout: 60)
            func take(_ path: IrohPath, _ ip: String?) -> HandshakeLimiter.Slot? {
                let (key, max) = IrohShellListener.bucket(path: path, ip: ip)
                return limiter.acquire(host: key, maxForHost: max) {}
            }
            let relayed = (0..<8).map { _ in take(.relay, nil) }
            XCTAssertTrue(relayed.allSatisfy { $0 != nil }, "eight relayed handshakes at once")
            XCTAssertNil(take(.relay, nil), "a ninth relayed one is refused")
            XCTAssertNotNil(take(.direct, "203.0.113.5"))
            XCTAssertNotNil(take(.direct, "203.0.113.5"))
            XCTAssertNil(take(.direct, "203.0.113.5"), "a third from one address is refused")
            XCTAssertNil(take(.direct, "203.0.113.6"), "or from its /24")
            for i in 0..<2 { XCTAssertNotNil(take(.direct, "198.51.\(i).1")) }
            XCTAssertEqual(limiter.count, 12)
            XCTAssertNil(take(.direct, "192.0.2.1"), "12 in all for addresses not proven lately")
            relayed[0]?.release()
            XCTAssertNotNil(take(.relay, nil), "a freed relay slot can be taken again")
            limiter.proven("192.0.2.1")
            for _ in 0..<2 { XCTAssertNotNil(take(.direct, "192.0.2.1")) }
            XCTAssertEqual(limiter.count, 14)
        }
    }

    // MARK: macInfo

    func testMacInfoAfterReady() async throws {
        let identity = try (try? makeTestIdentity()) ?? makeTestIdentity()
        let info = Self.sampleInfo

        let tls = await startTLS(identity: identity, macInfo: { info })
        let overTLS = tlsPeer(tls, identity: identity)
        await ready(overTLS, hello: false)
        await eventually("TLS sessions") { overTLS.first(ShellEnvelope.sessions) != nil }
        XCTAssertEqual(overTLS.kinds.prefix(4), [ShellEnvelope.challenge, ShellEnvelope.ready, ShellEnvelope.macInfo, ShellEnvelope.sessions])
        XCTAssertEqual(overTLS.first(ShellEnvelope.macInfo), info)

        _ = startIroh(macInfo: { info })
        let overIroh = try await irohPeer()
        await ready(overIroh)
        await eventually("iroh sessions") { overIroh.first(ShellEnvelope.sessions) != nil }
        XCTAssertEqual(overIroh.kinds.prefix(4), [ShellEnvelope.challenge, ShellEnvelope.ready, ShellEnvelope.macInfo, ShellEnvelope.sessions])
        XCTAssertEqual(overIroh.first(ShellEnvelope.macInfo), info)

        // Refused phones never see it.
        let refused = try await irohPeer()
        await authorize(refused, key: WirelessLink.randomBytes(32))
        await eventually("refused closed", timeout: 8) { refused.closed }
        XCTAssertNil(refused.first(ShellEnvelope.macInfo))
    }

    // MARK: Status

    private func paths(_ listener: IrohShellListener) async -> [String: IrohPath] {
        await withCheckedContinuation { done in listener.connectionPaths { done.resume(returning: $0) } }
    }

    func testConnectionPathsPerPhone() async throws {
        let listener = startIroh()
        let empty = await paths(listener)
        XCTAssertEqual(empty, [:])
        let peer = try await irohPeer()
        await ready(peer)
        var current: [String: IrohPath] = [:]
        let deadline = Date().addingTimeInterval(5)
        repeat {
            current = await paths(listener)
            if current["phone-1"] == .direct { break }
            await pause(0.05)
        } while Date() < deadline
        XCTAssertEqual(current, ["phone-1": .direct], "loopback with relays off is a direct path")

        listener.disconnect(phoneID: "phone-1")
        await eventually("closed") { peer.closed }
        let after = await paths(listener)
        XCTAssertEqual(after, [:])
    }

    func testPreferredPath() {
        XCTAssertEqual(IrohShellListener.preferred(.relay, .direct), .direct)
        XCTAssertEqual(IrohShellListener.preferred(.unknown, .relay), .relay)
        XCTAssertEqual(IrohShellListener.preferred(.unknown, .unknown), .unknown)
    }

    // MARK: Disconnect and stop

    func testDisconnectPhoneCoversIroh() async throws {
        let other = WirelessLink.randomBytes(32)
        let keys = Locked(["phone-1": key, "phone-2": other])
        let listener = startIroh(keys: keys)
        let a = try await irohPeer()
        await ready(a)
        let b = try await irohPeer()
        await ready(b, phoneID: "phone-2", key: other)

        keys.set(["phone-2": other])
        listener.disconnect(phoneID: "phone-1")
        await eventually("phone-1 cut") { a.closed }

        b.send(ShellEnvelope(t: ShellEnvelope.ping))
        await eventually("phone-2 still served") { b.first(ShellEnvelope.pong) != nil }
        XCTAssertFalse(b.closed)

        let again = try await irohPeer()
        await authorize(again)
        await eventually("revoked phone refused", timeout: 8) { again.closed }
        XCTAssertNil(again.first(ShellEnvelope.ready))
    }

    func testStopClosesIrohConnections() async throws {
        let listener = startIroh()
        let proven = try await irohPeer()
        await ready(proven)
        let unproven = try await irohPeer()
        unproven.send(ShellEnvelope(t: ShellEnvelope.hello))
        await eventually("unproven challenged") { unproven.first(ShellEnvelope.challenge) != nil }

        let stopped = expectation(description: "stopped")
        listener.stop { stopped.fulfill() }
        await fulfillment(of: [stopped], timeout: 5)
        await eventually("proven closed") { proven.closed }
        await eventually("unproven closed") { unproven.closed }
        XCTAssertEqual(listener.pendingHandshakes, 0)

        // Nothing is served after stop.
        if let late = try? await irohPeer() {
            late.send(ShellEnvelope(t: ShellEnvelope.hello))
            await eventually("late peer closed", timeout: 5) { late.closed }
            XCTAssertNil(late.first(ShellEnvelope.challenge))
        }
    }

    // MARK: Sessions across transports

    func testTlsAndIrohShareSessions() async throws {
        let identity = try (try? makeTestIdentity()) ?? makeTestIdentity()
        let tls = await startTLS(identity: identity)
        _ = startIroh()

        let overTLS = tlsPeer(tls, identity: identity)
        await ready(overTLS, hello: false)
        var open = ShellEnvelope(t: ShellEnvelope.open)
        open.cols = 80; open.rows = 24
        overTLS.send(open)
        await eventually("opened over TLS") { overTLS.first(ShellEnvelope.opened) != nil }
        let id = try XCTUnwrap(overTLS.first(ShellEnvelope.opened)?.session)

        let overIroh = try await irohPeer()
        await ready(overIroh)
        await eventually("iroh lists the TLS session") {
            overIroh.first(ShellEnvelope.sessions)?.sessions?.contains { $0.id == id } ?? false
        }
        var attach = ShellEnvelope(t: ShellEnvelope.attach)
        attach.session = id; attach.cols = 100; attach.rows = 30
        overIroh.send(attach)
        await eventually("TLS taken over") { overTLS.lines.get().contains { $0.t == ShellEnvelope.detached && $0.session == id } }
        await eventually("iroh attached") { overIroh.lines.get().contains { $0.t == ShellEnvelope.attached && $0.session == id } }

        var input = ShellEnvelope(t: ShellEnvelope.input)
        input.session = id
        input.data = Data("echo via-iroh-$((6*7))\n".utf8).base64EncodedString()
        overIroh.send(input)
        await eventually("iroh output", timeout: 10) { overIroh.output(id).contains("via-iroh-42\r\n") }
        XCTAssertFalse(overTLS.output(id).contains("via-iroh-42"), "the TLS phone no longer gets output")

        // And back: TLS takes it over again and gets the replay.
        overTLS.send(attach)
        await eventually("iroh taken over") { overIroh.lines.get().contains { $0.t == ShellEnvelope.detached && $0.session == id } }
        await eventually("TLS replay", timeout: 10) { overTLS.output(id).contains("via-iroh-42\r\n") }
    }
}

/// Reads newline-delimited envelopes from any `ByteStream` into a list.
private final class LinePeer: @unchecked Sendable {
    let stream: any ByteStream
    let lines = Locked<[ShellEnvelope]>([])
    private let buffer = Locked(Data())
    private let isClosed = Locked(false)

    init(_ stream: any ByteStream, reading: Bool = true) {
        self.stream = stream
        if reading { read() }
    }

    func startReading() { read() }

    var closed: Bool { isClosed.get() }
    var kinds: [String] { lines.get().map(\.t) }
    func first(_ kind: String) -> ShellEnvelope? { lines.get().first { $0.t == kind } }

    func output(_ session: String) -> String {
        String(decoding: lines.get().reduce(Data()) { acc, line in
            guard line.t == ShellEnvelope.output, line.session == session,
                  let data = line.data.flatMap({ Data(base64Encoded: $0) }) else { return acc }
            return acc + data
        }, as: UTF8.self)
    }

    func send(_ message: ShellEnvelope) { sendRaw(try! message.encodedLine()) }
    func sendRaw(_ data: Data) { stream.send(data, isComplete: false) { _ in } }

    private func read() {
        stream.receive(maximumLength: 65536) { [self] data, complete, error in
            if let data, !data.isEmpty {
                var pending = buffer.get() + data
                var parsed: [ShellEnvelope] = []
                while let newline = pending.firstIndex(of: 0x0A) {
                    if let line = try? ShellEnvelope.decode(Data(pending[..<newline])) { parsed.append(line) }
                    pending = Data(pending[pending.index(after: newline)...])
                }
                buffer.set(pending)
                lines.set(lines.get() + parsed)
            }
            if complete || error != nil { isClosed.set(true); return }
            read()
        }
    }
}
#endif
