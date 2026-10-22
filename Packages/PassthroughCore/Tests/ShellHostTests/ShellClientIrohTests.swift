#if os(macOS)
import Foundation
import Network
import XCTest
import PassthroughCore
import PhoneTransport
import TestSupport
@testable import IrohTransport
@testable import ShellHost

/// `ShellClient`'s dial race with the iroh candidate, against the Mac's real
/// listeners on loopback (iroh with relays off), and `macInfo`.
@available(macOS 15, *)
final class ShellClientIrohTests: XCTestCase {
    private var directory: URL!
    private var store: TranscriptStore!
    private var manager: ShellSessionManager!
    private var host: IrohEndpointHost!
    private let key = WirelessLink.randomBytes(32)
    private static let irohID = String(repeating: "ab", count: 32)

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShellClientIrohTests-\(UUID().uuidString)", isDirectory: true)
        store = try TranscriptStore(directory: directory)
        manager = ShellSessionManager(
            transcripts: store,
            command: { ("/bin/sh", []) },
            environment: { ["PATH": "/usr/bin:/bin", "TERM": "xterm-256color", "PS1": "$ "] },
            directory: URL(fileURLWithPath: "/tmp"))
        host = try await IrohEndpointHost(secretKey: IrohEndpointHost.newSecretKey(), relayEnabled: false)
    }

    override func tearDown() async throws {
        manager?.closeAll()
        await host?.shutdown()
        host = nil
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    // MARK: Schedule

    private func credential(addresses: [String], irohID: String? = irohID, port: UInt16 = 7893,
                            pin: String = "x") -> ShellCredential {
        ShellCredential(macID: "mac", macName: "Test Mac", certSHA256: pin, shellKey: key, phoneID: "phone-1",
                        port: port, addresses: addresses, irohID: irohID)
    }

    func testScheduleIrohAfterTcp() {
        let port = NWEndpoint.Port(rawValue: 7893)!
        let plan = ShellClient.schedule(for: credential(addresses: ["192.168.1.2", "100.100.1.1"]), discovered: nil, mode: .automatic)
        XCTAssertEqual(plan.map(\.candidate), [.tcp(.hostPort(host: "192.168.1.2", port: port)),
                                               .tcp(.hostPort(host: "100.100.1.1", port: port)), .iroh])
        XCTAssertEqual(plan.map(\.delay), [0, 0.25, 0.75])

        // With more addresses iroh still starts 750 ms after the first, ahead of later ones.
        let many = ShellClient.schedule(for: credential(addresses: ["10.0.0.1", "10.0.0.2", "10.0.0.3", "10.0.0.4", "10.0.0.5"]),
                                        discovered: nil, mode: .automatic)
        XCTAssertEqual(many.map(\.delay), [0, 0.25, 0.5, 0.75, 0.75, 1.0])
        XCTAssertEqual(many[4].candidate, .iroh, "a TLS candidate due at the same time goes first")
    }

    func testScheduleIrohImmediateWhenNoTcp() {
        let plan = ShellClient.schedule(for: credential(addresses: []), discovered: nil, mode: .automatic)
        XCTAssertEqual(plan.map(\.candidate), [.iroh])
        XCTAssertEqual(plan.map(\.delay), [0])
    }

    func testLocalOnlyHasNoIroh() {
        let local = ShellClient.schedule(for: credential(addresses: ["192.168.1.2"]), discovered: nil, mode: .localOnly)
        XCTAssertEqual(local.map(\.candidate), [.tcp(.hostPort(host: "192.168.1.2", port: NWEndpoint.Port(rawValue: 7893)!))])
        XCTAssertTrue(ShellClient.schedule(for: credential(addresses: []), discovered: nil, mode: .localOnly).isEmpty)
        XCTAssertFalse(ShellClient.schedule(for: credential(addresses: [], irohID: nil), discovered: nil, mode: .automatic)
            .contains { $0.candidate == .iroh }, "no iroh without the Mac's endpoint id")
        XCTAssertFalse(ShellClient.schedule(for: credential(addresses: [], irohID: "not-an-id"), discovered: nil, mode: .automatic)
            .contains { $0.candidate == .iroh })
    }

    // MARK: Race

    func testIrohWinsWhenTcpBlackholed() async throws {
        startIrohListener()
        let silent = try await blackhole()
        let iroh = LoopbackIroh(host)
        let probe = Probe()
        let client = ShellClient(credential: credential(addresses: ["127.0.0.1"], irohID: host.endpointID, port: silent.port),
                                 queue: DispatchQueue(label: "probe"), iroh: iroh) { probe.record($0) }
        addTeardownBlock { client.disconnect() }
        let started = Date()
        client.connect()
        await probe.wait("ready over iroh", timeout: 8) { probe.readyPath != nil }
        XCTAssertEqual(probe.readyPath, .direct, "loopback with relays off is a direct path")
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), 0.75 - 0.05,
                                    "iroh waits for the first TLS candidate")
        XCTAssertGreaterThanOrEqual(silent.held.get().count, 1, "the blackholed address was dialled")

        client.list()
        await probe.wait("served over iroh") { probe.sessionLists >= 2 }
        XCTAssertFalse(probe.disconnected)
        XCTAssertEqual(iroh.shutdowns.get(), 0, "the winner's endpoint stays up")

        client.disconnect()
        await probe.wait("disconnected") { probe.disconnected }
        XCTAssertEqual(iroh.shutdowns.get(), 1, "disconnect closes the endpoint")
    }

    /// TLS answers once iroh is already dialling: TLS wins, and the iroh
    /// attempt's stream and endpoint are closed.
    func testIrohLoserClosed() async throws {
        let identity = try (try? makeTestIdentity()) ?? makeTestIdentity()
        let tls = await startTLS(identity: identity)
        let gate = try await GatedProxy(to: tls.port!)
        addTeardownBlock { gate.stop() }
        let fake = FakeIrohMac(host)
        addTeardownBlock { fake.stop() }

        let iroh = LoopbackIroh(host)
        let probe = Probe()
        let client = ShellClient(credential: credential(addresses: [], irohID: host.endpointID, port: gate.port, pin: identity.fingerprint),
                                 queue: DispatchQueue(label: "probe"), iroh: iroh) { probe.record($0) }
        addTeardownBlock { client.disconnect() }
        client.connect(discovered: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: gate.port)!))

        await eventually("iroh said hello", timeout: 8) { fake.hello.get() }
        gate.open()
        await probe.wait("ready over TLS") { probe.readyPath != nil }
        XCTAssertEqual(probe.readyPath, .local)
        await eventually("iroh stream closed", timeout: 5) { fake.closed.get() }
        XCTAssertGreaterThanOrEqual(iroh.shutdowns.get(), 1, "the losing endpoint is shut down")

        client.list()
        await probe.wait("served over TLS") { probe.sessionLists >= 2 }
        XCTAssertFalse(probe.disconnected)
    }

    /// The Mac itself refusing over iroh (authenticated by its endpoint id)
    /// is authoritative before `ready`: the TLS attempts stop too, without
    /// waiting out a silent address.
    func testIrohRefusalStopsEveryAttempt() async throws {
        startIrohListener(key: WirelessLink.randomBytes(32))   // not the phone's key
        let silent = try await blackhole()
        let iroh = LoopbackIroh(host)
        let probe = Probe()
        let client = ShellClient(credential: credential(addresses: ["127.0.0.1"], irohID: host.endpointID, port: silent.port),
                                 queue: DispatchQueue(label: "probe"), iroh: iroh) { probe.record($0) }
        addTeardownBlock { client.disconnect() }
        let started = Date()
        client.connect()
        await probe.wait("refused", timeout: 8) { probe.disconnected }
        XCTAssertLessThan(Date().timeIntervalSince(started), 4,   // ShellClient.attemptTimeout
                          "a refusal over iroh doesn't wait for the silent address")
        XCTAssertNil(probe.readyPath)
        XCTAssertTrue(probe.events.get().contains { if case .failed(.notAuthorized, _) = $0 { true } else { false } })
        XCTAssertEqual(probe.disconnectError as? ShellError, .notAuthorized)
        XCTAssertGreaterThanOrEqual(silent.held.get().count, 1, "the silent address was dialled")
        XCTAssertGreaterThanOrEqual(iroh.shutdowns.get(), 1)
    }

    /// An iroh dial that fails (no route, a broken endpoint) fails only that
    /// candidate: TLS still connects. With iroh the only candidate, its
    /// error comes back as the connection's.
    func testIrohDialFailureLetsTcpContinue() async throws {
        let identity = try (try? makeTestIdentity()) ?? makeTestIdentity()
        let tls = await startTLS(identity: identity)
        let gate = try await GatedProxy(to: tls.port!)
        addTeardownBlock { gate.stop() }
        let iroh = FailingIroh()
        let probe = Probe()
        let client = ShellClient(credential: credential(addresses: ["127.0.0.1"], irohID: Self.irohID, port: gate.port,
                                                        pin: identity.fingerprint),
                                 queue: DispatchQueue(label: "probe"), iroh: iroh) { probe.record($0) }
        addTeardownBlock { client.disconnect() }
        client.connect()
        await eventually("iroh dialled and failed", timeout: 5) { iroh.dials.get() >= 1 }
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertFalse(probe.disconnected, "the TLS attempt carries on")
        gate.open()
        await probe.wait("ready over TLS") { probe.readyPath != nil }
        XCTAssertEqual(probe.readyPath, .local)
        XCTAssertGreaterThanOrEqual(iroh.shutdowns.get(), 1, "the failed endpoint is shut down")

        let only = Probe()
        let irohOnly = ShellClient(credential: credential(addresses: [], irohID: Self.irohID),
                                   queue: DispatchQueue(label: "probe-2"), iroh: FailingIroh()) { only.record($0) }
        addTeardownBlock { irohOnly.disconnect() }
        irohOnly.connect()
        await only.wait("failed") { only.disconnected }
        XCTAssertTrue(only.disconnectError is FailingIroh.Failure)
    }

    /// A Mac that sends `macInfo` after `ready` has it surfaced before the session list.
    func testMacInfoEvent() async throws {
        let identity = try (try? makeTestIdentity()) ?? makeTestIdentity()
        var info = ShellEnvelope(t: ShellEnvelope.macInfo)
        info.irohID = Self.irohID
        info.irohRelay = "https://relay.example.com/"
        info.relayToken = "test-token"
        info.addresses = ["192.168.1.2"]
        let sent = info
        let tls = await startTLS(identity: identity, macInfo: { sent })
        let probe = Probe()
        let client = ShellClient(credential: credential(addresses: [], irohID: nil, port: tls.port!, pin: identity.fingerprint),
                                 queue: DispatchQueue(label: "probe")) { probe.record($0) }
        addTeardownBlock { client.disconnect() }
        client.connect(discovered: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: tls.port!)!))
        await probe.wait("sessions") { probe.sessionLists >= 1 }
        let kinds = probe.events.get().map { event -> String in
            switch event {
            case .ready: "ready"
            case .macInfo: "macInfo"
            case .sessions: "sessions"
            default: "other"
            }
        }
        XCTAssertEqual(kinds.prefix(3), ["ready", "macInfo", "sessions"])
        XCTAssertEqual(probe.events.get().compactMap { if case .macInfo(let m) = $0 { m } else { nil } }, [sent])
        XCTAssertEqual(probe.readyPath, .local)
    }

    // MARK: Helpers

    private func startIrohListener(key: Data? = nil) {
        let key = key ?? self.key
        let listener = IrohShellListener(host: host, manager: manager, transcripts: store,
                                         shellKeys: { $0 == "phone-1" ? [key] : [] }, phoneLabel: { _ in "Test iPhone" })
        listener.start()
        addTeardownBlock { listener.stop() }
    }

    private func startTLS(identity: MacIdentity, macInfo: @escaping @Sendable () -> ShellEnvelope? = { nil }) async -> ShellListener {
        let key = self.key
        let listener = ShellListener(identity: identity, port: 0, advertise: false, manager: manager, transcripts: store,
                                     shellKeys: { $0 == "phone-1" ? [key] : [] }, phoneLabel: { _ in "Test iPhone" },
                                     peerAllowed: { ShellAddressPolicy.isAllowed($0) }, macInfo: macInfo)
        let listening = expectation(description: "listening")
        try! listener.start { _ in listening.fulfill() }
        await fulfillment(of: [listening], timeout: 5)
        addTeardownBlock { listener.stop() }
        return listener
    }

    /// A TCP address that accepts and then never says anything (no TLS).
    private func blackhole() async throws -> (port: UInt16, held: Locked<[NWConnection]>) {
        let listener = try NWListener(using: .tcp)
        let held = Locked<[NWConnection]>([])
        listener.newConnectionHandler = { c in held.set(held.get() + [c]); c.start(queue: .global()) }
        let ready = expectation(description: "blackhole listening")
        listener.stateUpdateHandler = { if case .ready = $0 { ready.fulfill() } }
        listener.start(queue: .global())
        addTeardownBlock { listener.cancel(); held.get().forEach { $0.cancel() } }
        await fulfillment(of: [ready], timeout: 5)
        return (listener.port!.rawValue, held)
    }

    private func eventually(_ what: String, timeout: TimeInterval = 5, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return XCTFail("timed out: \(what)") }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}

/// The app's dialer with relays off, aimed at the test host's loopback sockets
/// (the client passes no addresses: in the field iroh finds them via the relay).
private final class LoopbackIroh: ShellIrohDialing, @unchecked Sendable {
    private let inner = IrohShellDialer { _ in try await IrohDialer(relayEnabled: false) }
    private let addresses: [String]
    let shutdowns = Locked(0)

    init(_ host: IrohEndpointHost) { addresses = host.directAddresses + host.loopbackAddresses }

    func connect(irohID: String, relayURL: String?, relayToken: String?, addresses _: [String]) async throws -> any ByteStream {
        try await inner.connect(irohID: irohID, relayURL: nil, relayToken: nil, addresses: addresses)
    }

    func path(of stream: any ByteStream) -> ShellPath { inner.path(of: stream) }

    func shutdown() {
        shutdowns.set(shutdowns.get() + 1)
        inner.shutdown()
    }
}

/// A dialer whose every connect fails.
private final class FailingIroh: ShellIrohDialing, @unchecked Sendable {
    struct Failure: Error {}
    let dials = Locked(0)
    let shutdowns = Locked(0)

    func connect(irohID: String, relayURL: String?, relayToken: String?, addresses: [String]) async throws -> any ByteStream {
        dials.set(dials.get() + 1)
        throw Failure()
    }

    func path(of stream: any ByteStream) -> ShellPath { .unknown }

    func shutdown() { shutdowns.set(shutdowns.get() + 1) }
}

/// An iroh "Mac" that takes the phone's stream, notes its `hello` and then
/// never answers, so the phone's iroh attempt stays in progress.
private final class FakeIrohMac: @unchecked Sendable {
    let hello = Locked(false)
    let closed = Locked(false)
    private var task: Task<Void, Never>?

    init(_ host: IrohEndpointHost) {
        task = Task { [hello, closed] in
            guard let incoming = try? await host.accept(alpn: IrohShell.alpn),
                  let stream = try? await incoming.acceptStream() else { return }
            var received = Data()
            while true {
                let (data, done) = await withCheckedContinuation { (k: CheckedContinuation<(Data?, Bool), Never>) in
                    stream.receive(maximumLength: 65536) { data, complete, error in k.resume(returning: (data, complete || error != nil)) }
                }
                if let data { received += data }
                if received.contains(0x0A), let line = try? ShellEnvelope.decode(Data(received.prefix { $0 != 0x0A })),
                   line.t == ShellEnvelope.hello { hello.set(true) }
                if done { closed.set(true); return }
            }
        }
    }

    func stop() { task?.cancel() }
}

/// A TCP port that holds connections until `open()`, then joins them to the
/// TLS listener on `target`.
private final class GatedProxy: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "gated-proxy")
    private var isOpen = false
    private var waiting: [NWConnection] = []
    private var splices: [Splice] = []
    private let target: UInt16
    var port: UInt16 { listener.port!.rawValue }

    init(to target: UInt16) async throws {
        self.target = target
        listener = try NWListener(using: .tcp)
        listener.newConnectionHandler = { [self] c in queue.async { self.isOpen ? self.join(c) : self.waiting.append(c) } }
        await withCheckedContinuation { (k: CheckedContinuation<Void, Never>) in
            let once = Locked(false)
            listener.stateUpdateHandler = { state in
                if case .ready = state, !once.get() { once.set(true); k.resume() }
            }
            listener.start(queue: queue)
        }
    }

    func open() {
        queue.async { [self] in
            isOpen = true
            waiting.forEach(join)
            waiting = []
        }
    }

    private func join(_ inbound: NWConnection) {
        let upstream = NWConnection(to: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: target)!), using: .tcp)
        let splice = Splice(ConnectionStream(inbound, queue: queue), ConnectionStream(upstream, queue: queue), queue: queue) {}
        splices.append(splice)
        splice.start()
    }

    func stop() {
        queue.async { [self] in
            listener.cancel()
            waiting.forEach { $0.cancel() }
            splices.forEach { $0.close() }
        }
    }
}

/// Collects a client's events.
private final class Probe: @unchecked Sendable {
    private let lock = NSLock()
    private var _events: [ShellClient.Event] = []
    var events: Locked<[ShellClient.Event]> { lock.lock(); defer { lock.unlock() }; return Locked(_events) }

    func record(_ event: ShellClient.Event) { lock.lock(); _events.append(event); lock.unlock() }

    var readyPath: ShellPath? {
        for case .ready(let path) in events.get() { return path }
        return nil
    }
    var sessionLists: Int { events.get().filter { if case .sessions = $0 { true } else { false } }.count }
    var disconnected: Bool { events.get().contains { if case .disconnected = $0 { true } else { false } } }
    var disconnectError: Error? {
        for case .disconnected(let error) in events.get() { return error }
        return nil
    }

    func wait(_ what: String, timeout: TimeInterval = 5, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return XCTFail("timed out: \(what)") }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}
#endif
