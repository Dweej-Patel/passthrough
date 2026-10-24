import XCTest
import Network
@testable import PassthroughCore
@testable import PhoneTransport

/// Whatever answers on the phone's control port, scripted by the test: the
/// real phone, an impostor, or a phone from an older release.
final class FakePhone: @unchecked Sendable {
    let port: UInt16
    private let listener: NWListener
    private let queue = DispatchQueue(label: "test.fake-phone")
    private var connection: NWConnection?
    /// What the Mac sent, read continuously so a receive that timed out
    /// never swallows the bytes after it.
    private var buffer = Data()
    private let lock = NSLock()
    private let arrived = DispatchSemaphore(value: 0)

    init() throws {
        port = freePort()
        listener = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: port)!)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
        listener.newConnectionHandler = { [weak self] c in
            guard let self else { return }
            self.connection = c
            c.start(queue: self.queue)
            self.pump(c)
        }
        listener.start(queue: queue)
        XCTAssertEqual(ready.wait(timeout: .now() + 5), .success)
    }

    private func pump(_ c: NWConnection) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.lock.lock(); self.buffer.append(data); self.lock.unlock()
                self.arrived.signal()
            }
            if isComplete || error != nil { return }
            self.pump(c)
        }
    }

    /// The next message from the Mac; nil if none arrives in time.
    func receive(timeout: TimeInterval = 5) -> ControlEnvelope? {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            lock.lock()
            let line = buffer.firstIndex(of: 0x0A).map { newline in
                defer { buffer.removeSubrange(buffer.startIndex...newline) }
                return buffer.subdata(in: buffer.startIndex..<newline)
            }
            lock.unlock()
            if let line { return try? ControlEnvelope.decode(line) }
            guard arrived.wait(timeout: .now() + max(0, deadline.timeIntervalSinceNow)) == .success else { return nil }
        }
    }

    func send(_ m: ControlEnvelope) {
        let done = DispatchSemaphore(value: 0)
        connection?.send(content: try? m.encodedLine(), completion: .contentProcessed { _ in done.signal() })
        _ = done.wait(timeout: .now() + 5)
    }

    func close() {
        connection?.cancel()
        listener.cancel()
    }
}

final class ControlClientAuthTests: XCTestCase {
    private let token = PairingToken.generate()
    private let cert = String(repeating: "b", count: 64)

    private func client(_ phone: FakePhone, token: String?, guess: Bool = false,
                        onEvent: @escaping @Sendable (ControlClient.Event) -> Void) -> ControlClient {
        let device = PhoneDevice(id: "test", kind: .iPhone, label: "test", pairingSlot: "t", link: LoopbackLink())
        let client = ControlClient(device: device, port: phone.port, identity: .init(clientID: "mac1", name: "MacBook", token: token, tokenIsGuess: guess), handler: onEvent)
        client.connect()
        return client
    }

    /// The phone's side of the hello: the Mac's nonce, and a welcome to send.
    private func welcome(to hello: ControlEnvelope?, paired: Bool, proofKey: String?) throws -> ControlEnvelope {
        let hello = try XCTUnwrap(hello)
        XCTAssertEqual(hello.t, "hello")
        XCTAssertEqual(hello.protocolVersion, 2)
        XCTAssertNil(hello.token, "the token never goes on the wire")
        let macNonce = try XCTUnwrap(ControlAuth.decodeNonce(hello.nonce))
        let phoneNonce = ControlAuth.nonce()
        var w = ControlEnvelope(t: "welcome")
        w.protocolVersion = 2
        w.paired = paired
        w.nonce = phoneNonce.base64EncodedString()
        w.deviceName = "Phone"
        if let proofKey {
            w.proof = ControlAuth.phoneProof(key: ControlAuth.key(token: proofKey), clientID: "mac1", macNonce: macNonce, phoneNonce: phoneNonce).base64EncodedString()
        }
        return w
    }

    /// Tries to hand over the link and a shell key.
    private func offerSecrets(_ client: ControlClient) {
        client.link(linkKey: WirelessLink.randomBytes(32), certificateSHA256: cert)
        client.grantShell(shellKey: WirelessLink.randomBytes(32), certificateSHA256: cert, port: 7893, addresses: [], macName: "M")
    }

    func testValidProofPairsAndTheMacProvesBack() throws {
        let phone = try FakePhone()
        defer { phone.close() }
        let welcomed = expectation(description: "welcomed")
        let paired = Locked<Bool?>(nil)
        let client = client(phone, token: token) { if case .welcomed(let p) = $0 { paired.set(p); welcomed.fulfill() } }
        defer { client.close() }
        let hello = phone.receive()
        let w = try welcome(to: hello, paired: true, proofKey: token)
        phone.send(w)
        wait(for: [welcomed], timeout: 5)
        XCTAssertEqual(paired.get(), true)

        let auth = try XCTUnwrap(phone.receive())
        XCTAssertEqual(auth.t, "auth", "the Mac's proof comes before anything else")
        XCTAssertTrue(ControlAuth.isValidMacProof(auth.proof, key: try XCTUnwrap(ControlAuth.key(tokenHash: PairingToken.hash(token))), clientID: "mac1",
                                                  macNonce: try XCTUnwrap(ControlAuth.decodeNonce(hello?.nonce)), phoneNonce: try XCTUnwrap(ControlAuth.decodeNonce(w.nonce))))
        offerSecrets(client)
        XCTAssertEqual(phone.receive()?.t, "link")
        XCTAssertEqual(phone.receive()?.t, "shellGrant")
    }

    /// A phone that says it is paired but can't prove it (an impostor that
    /// answered on the port) gets nothing, and the connection ends.
    func testBadOrMissingProofEndsTheConnectionAndSendsNothing() throws {
        for proofKey in [PairingToken.generate(), nil] {
            let phone = try FakePhone()
            defer { phone.close() }
            let ended = expectation(description: "ended")
            let events = Locked<[ControlClient.Event]>([])
            let client = client(phone, token: token) { event in
                events.set(events.get() + [event])
                if case .disconnected(let error) = event {
                    XCTAssertEqual(error as? ControlClient.ControlError, .proofFailed(kind: "iPhone"))
                    ended.fulfill()
                }
            }
            defer { client.close() }
            phone.send(try welcome(to: phone.receive(), paired: true, proofKey: proofKey))
            wait(for: [ended], timeout: 5)
            offerSecrets(client)
            XCTAssertNil(phone.receive(timeout: 0.5), "no auth, link or shell key")
            XCTAssertFalse(events.get().contains { if case .welcomed = $0 { return true } else { return false } }, "not offered pairing either")
        }
    }

    /// A token from the slot every iPhone once shared may be another
    /// iPhone's: a phone that can't prove it is just unpaired.
    func testGuessedTokenThatFailsCountsAsUnpaired() throws {
        let phone = try FakePhone()
        defer { phone.close() }
        let welcomed = expectation(description: "welcomed")
        let paired = Locked<Bool?>(nil)
        let client = client(phone, token: token, guess: true) { if case .welcomed(let p) = $0 { paired.set(p); welcomed.fulfill() } }
        defer { client.close() }
        phone.send(try welcome(to: phone.receive(), paired: true, proofKey: PairingToken.generate()))
        wait(for: [welcomed], timeout: 5)
        XCTAssertEqual(paired.get(), false)
        offerSecrets(client)
        XCTAssertNil(phone.receive(timeout: 0.5))
    }

    /// Only the answer to this Mac's own `pair` counts, and only once: a
    /// `paired` sent unasked would plant a token (and unlock the secrets).
    func testUnsolicitedPairedIsIgnored() throws {
        let phone = try FakePhone()
        defer { phone.close() }
        let welcomed = expectation(description: "welcomed"), pairedOnce = expectation(description: "paired")
        let tokens = Locked<[String]>([])
        let client = client(phone, token: nil) { event in
            switch event {
            case .welcomed: welcomed.fulfill()
            case .paired(let t): tokens.set(tokens.get() + [t]); pairedOnce.fulfill()
            default: break
            }
        }
        defer { client.close() }
        phone.send(try welcome(to: phone.receive(), paired: false, proofKey: nil))
        wait(for: [welcomed], timeout: 5)

        var planted = ControlEnvelope(t: "paired"); planted.token = PairingToken.generate()
        phone.send(planted)
        offerSecrets(client)
        XCTAssertNil(phone.receive(timeout: 0.5), "nothing handed over")

        client.pair(code: "123456")
        XCTAssertEqual(phone.receive()?.code, "123456")
        var answer = ControlEnvelope(t: "paired"); answer.token = token
        phone.send(answer)
        phone.send(planted)
        wait(for: [pairedOnce], timeout: 5)
        offerSecrets(client)
        XCTAssertEqual(phone.receive()?.t, "link", "a completed pairing authenticates the channel")
        XCTAssertEqual(tokens.get(), [token], "the answer counts, once; the extra one does not")
    }

    /// The phone's status counts only on an authenticated channel: whatever
    /// answers on the port can't put a name or radio of its choosing on screen.
    func testStatusCountsOnlyOnceAuthenticated() throws {
        for paired in [false, true] {
            let phone = try FakePhone()
            defer { phone.close() }
            let welcomed = expectation(description: "welcomed"), status = expectation(description: "status")
            status.isInverted = !paired
            let names = Locked<[String]>([])
            let client = client(phone, token: token) { event in
                switch event {
                case .welcomed: welcomed.fulfill()
                case .status(let s, _, _, _): names.set(names.get() + [s.deviceName]); status.fulfill()
                default: break
                }
            }
            defer { client.close() }
            phone.send(try welcome(to: phone.receive(), paired: paired, proofKey: paired ? token : nil))
            wait(for: [welcomed], timeout: 5)
            var s = ControlEnvelope(t: "status"); s.deviceName = "Phone"; s.radio = "5G"
            phone.send(s)
            wait(for: [status], timeout: paired ? 5 : 0.5)
            XCTAssertEqual(names.get(), paired ? ["Phone"] : [])
        }
    }

    /// A code typed before the phone's welcome waits for it.
    func testCodeEnteredBeforeWelcomeIsSentAfterIt() throws {
        let phone = try FakePhone()
        defer { phone.close() }
        let client = client(phone, token: nil) { _ in }
        defer { client.close() }
        let hello = phone.receive()
        client.pair(code: "654321")
        XCTAssertNil(phone.receive(timeout: 0.3), "not before the welcome")
        phone.send(try welcome(to: hello, paired: false, proofKey: nil))
        XCTAssertEqual(phone.receive()?.code, "654321")
    }

    /// Phones from before version 2 refuse the hello without saying their
    /// version; one that answers with another version is refused too.
    func testOtherProtocolVersionsAreRefused() throws {
        for (reply, phoneIsOlder) in [("error", true), ("welcome1", true), ("welcome3", false)] {
            let phone = try FakePhone()
            defer { phone.close() }
            let ended = expectation(description: "ended")
            let client = client(phone, token: token) { event in
                if case .disconnected(let error) = event {
                    XCTAssertEqual(error as? ControlClient.ControlError, .incompatible(kind: "iPhone", phoneIsOlder: phoneIsOlder), reply)
                    ended.fulfill()
                }
            }
            defer { client.close() }
            _ = phone.receive()
            var m: ControlEnvelope
            switch reply {
            case "error": m = ControlEnvelope(t: "error"); m.reason = "unsupported_version"
            default: m = ControlEnvelope(t: "welcome"); m.protocolVersion = reply == "welcome1" ? 1 : 3; m.paired = true
            }
            phone.send(m)
            wait(for: [ended], timeout: 5)
            XCTAssertTrue(ControlClient.ControlError.incompatible(kind: "iPhone", phoneIsOlder: phoneIsOlder).localizedDescription
                .contains(phoneIsOlder ? "on the iPhone" : "on this Mac"))
        }
    }

    /// Against the real phone server: proof both ways, then the link goes through.
    func testRealServerProvesBothWays() throws {
        let suite = "\(PassthroughProtocol.identifier).tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let registry = PairingRegistry(defaults: defaults, secrets: InMemorySecrets())
        let (code, _) = registry.issueCode()
        guard case .success(let token) = registry.pair(code: code, clientID: "mac1", name: "MacBook") else { return XCTFail() }
        let port = freePort()
        let server = ControlServer(port: port, socksPort: 7890, registry: registry, counter: ByteCounter()) { DeviceStatus(deviceName: "P", hosting: "test") }
        try server.start()
        defer { server.stop() }
        for (attempt, expectPaired) in [(token, true), (PairingToken.generate(), false)] {
            let welcomed = expectation(description: "welcomed"), linked = expectation(description: "linked")
            linked.isInverted = !expectPaired
            let paired = Locked<Bool?>(nil)
            let device = PhoneDevice(id: "test", kind: .iPhone, label: "test", pairingSlot: "t", link: LoopbackLink())
            // A guess, so the wrong token reads as unpaired rather than ending the channel.
            let client = ControlClient(device: device, port: port, identity: .init(clientID: "mac1", name: "MacBook", token: attempt, tokenIsGuess: true)) { event in
                switch event {
                case .welcomed(let p): paired.set(p); welcomed.fulfill()
                case .linked: linked.fulfill()
                default: break
                }
            }
            client.connect()
            wait(for: [welcomed], timeout: 5)
            XCTAssertEqual(paired.get(), expectPaired)
            client.link(linkKey: WirelessLink.randomBytes(32), certificateSHA256: cert)
            wait(for: [linked], timeout: expectPaired ? 5 : 1)
            client.close()
        }
    }
}

final class PairingSlotsTests: XCTestCase {
    final class MemoryTokens: PairingTokenStore, @unchecked Sendable {
        var items: [String: String] = [:]
        var refuseWrites = false
        func read(_ slot: String) -> String? { items[slot] }
        func write(_ token: String, slot: String) -> Bool { if refuseWrites { return false }; items[slot] = token; return true }
        func delete(_ slot: String) { items[slot] = nil }
    }

    private let iPhone = PhoneDevice.iPhone(deviceID: 1, udid: "00008110-AAAA")

    /// An iPhone paired before each had its own slot keeps its pairing: the
    /// shared token is tried, and moves to the phone's slot once proved.
    func testSharediPhoneTokenMovesOnceProved() throws {
        let store = MemoryTokens()
        store.items["token"] = "legacy"
        let stored = try XCTUnwrap(PairingSlots.lookup(for: iPhone, in: store))
        XCTAssertEqual(stored, PairingSlots.Stored(token: "legacy", slot: "token"))
        XCTAssertTrue(stored.isShared)
        XCTAssertTrue(PairingSlots.adopt(stored, for: iPhone, in: store))
        XCTAssertEqual(store.items, ["token.iphone.00008110-AAAA": "legacy"], "copied, and the shared slot gone")
        let again = try XCTUnwrap(PairingSlots.lookup(for: iPhone, in: store))
        XCTAssertFalse(again.isShared)
        XCTAssertFalse(PairingSlots.adopt(again, for: iPhone, in: store), "nothing left to move")

        // Another iPhone finds nothing now: it pairs into its own slot.
        XCTAssertNil(PairingSlots.lookup(for: .iPhone(deviceID: 2, udid: "OTHER"), in: store))
    }

    func testOwnSlotWinsAndOnlyCableiPhonesUseTheSharedOne() {
        let store = MemoryTokens()
        store.items = ["token": "legacy", iPhone.pairingSlot: "own"]
        XCTAssertEqual(PairingSlots.lookup(for: iPhone, in: store)?.token, "own")
        XCTAssertNil(PairingSlots.lookup(for: .android(serial: "R58M", model: nil), in: store))
        let overAir = PhoneDevice.wireless(phoneID: "p", kind: .iPhone, label: "i", pairingSlot: "token.iphone.X", link: LoopbackLink())
        XCTAssertNil(PairingSlots.lookup(for: overAir, in: store))
        // A wireless phone linked through the shared slot still reads it (it is its own slot).
        let oldLink = PhoneDevice.wireless(phoneID: "p", kind: .iPhone, label: "i", pairingSlot: "token", link: LoopbackLink())
        XCTAssertEqual(PairingSlots.lookup(for: oldLink, in: store)?.isShared, true)
        XCTAssertFalse(PairingSlots.adopt(PairingSlots.Stored(token: "legacy", slot: "token"), for: oldLink, in: store), "moves only over the cable, where the UDID is known")
    }

    /// The shared token may be another iPhone's: an iPhone that hasn't proved
    /// it doesn't count as paired through it, and forgetting its pairing
    /// leaves it alone. Once proved (and still there, the move having failed)
    /// it is this iPhone's.
    func testSharedTokenIsOnlyAniPhonesOnceProved() {
        let store = MemoryTokens()
        store.items["token"] = "legacy"
        XCTAssertNotNil(PairingSlots.lookup(for: iPhone, in: store), "still tried, as a guess")
        XCTAssertEqual(PairingSlots.provenSlots(for: iPhone, provedShared: false, in: store), [], "but not paired: unproven")
        XCTAssertEqual(PairingSlots.provenSlots(for: iPhone, provedShared: true, in: store), ["token"])

        store.items[iPhone.pairingSlot] = "own"
        XCTAssertEqual(PairingSlots.provenSlots(for: iPhone, provedShared: false, in: store), [iPhone.pairingSlot], "its own slot only")
        XCTAssertEqual(PairingSlots.provenSlots(for: .android(serial: "R58M", model: nil), provedShared: true, in: store), [],
                       "never the shared slot for an Android phone")
        // A wireless phone linked through the shared slot: that slot is its own.
        let oldLink = PhoneDevice.wireless(phoneID: "p", kind: .iPhone, label: "i", pairingSlot: "token", link: LoopbackLink())
        XCTAssertEqual(PairingSlots.provenSlots(for: oldLink, provedShared: false, in: store), ["token"])
    }

    /// The shared copy stays until the phone's own copy is stored.
    func testFailedCopyKeepsTheSharedToken() {
        let store = MemoryTokens()
        store.items["token"] = "legacy"
        store.refuseWrites = true
        XCTAssertFalse(PairingSlots.adopt(PairingSlots.Stored(token: "legacy", slot: "token"), for: iPhone, in: store))
        XCTAssertEqual(store.items, ["token": "legacy"])
    }
}
