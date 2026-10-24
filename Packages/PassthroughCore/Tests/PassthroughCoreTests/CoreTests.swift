import XCTest
import Network
@testable import PassthroughCore
@testable import PhoneTransport

/// Minimal blocking TCP client for exercising the servers from tests.
final class TestClient {
    let connection: NWConnection
    let queue = DispatchQueue(label: "test.client")
    init(port: UInt16) {
        connection = NWConnection(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        let ready = DispatchSemaphore(value: 0)
        connection.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
        connection.start(queue: queue)
        XCTAssertEqual(ready.wait(timeout: .now() + 5), .success)
    }
    func send(_ bytes: [UInt8]) { send(Data(bytes)) }
    func send(_ data: Data) {
        let done = DispatchSemaphore(value: 0)
        connection.send(content: data, completion: .contentProcessed { _ in done.signal() })
        XCTAssertEqual(done.wait(timeout: .now() + 5), .success)
    }
    func read(_ n: Int, timeout: TimeInterval = 5) -> Data {
        let done = DispatchSemaphore(value: 0)
        var out = Data()
        connection.receive(minimumIncompleteLength: n, maximumLength: n) { data, _, _, _ in out = data ?? Data(); done.signal() }
        XCTAssertEqual(done.wait(timeout: .now() + timeout), .success)
        return out
    }
    func readLine(timeout: TimeInterval = 5) -> Data {
        var line = Data()
        while true {
            let b = read(1, timeout: timeout)
            guard !b.isEmpty else { return line }
            if b[0] == 0x0A { return line }
            line.append(b)
        }
    }
    func close() { connection.cancel() }
}

func freePort() -> UInt16 {
    let sock = socket(AF_INET, SOCK_STREAM, 0)
    var addr = sockaddr_in(); addr.sin_family = sa_family_t(AF_INET); addr.sin_port = 0; addr.sin_addr.s_addr = inet_addr("127.0.0.1")
    var len = socklen_t(MemoryLayout<sockaddr_in>.size)
    _ = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(sock, $0, len) } }
    _ = withUnsafeMutablePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(sock, $0, &len) } }
    close(sock)
    return UInt16(bigEndian: addr.sin_port)
}

/// TCP echo server used as a stand-in for "the internet".
final class EchoServer {
    let listener: NWListener
    let port: UInt16
    init() throws {
        port = freePort()
        listener = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: port)!)
        listener.newConnectionHandler = { c in
            c.start(queue: .global())
            func loop() {
                c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, complete, _ in
                    if let data, !data.isEmpty { c.send(content: data, completion: .contentProcessed { _ in complete ? c.cancel() : loop() }) }
                    else if complete { c.cancel() } else { loop() }
                }
            }
            loop()
        }
        listener.start(queue: .global())
    }
}

final class UDPEchoServer {
    let listener: NWListener
    let port: UInt16
    init() throws {
        port = freePort()
        listener = try NWListener(using: .udp, on: NWEndpoint.Port(rawValue: port)!)
        listener.newConnectionHandler = { c in
            c.start(queue: .global())
            func loop() {
                c.receiveMessage { data, _, _, _ in
                    if let data { c.send(content: Data("echo:".utf8) + data, completion: .idempotent) }
                    loop()
                }
            }
            loop()
        }
        listener.start(queue: .global())
    }
}

final class SOCKS5ServerTests: XCTestCase {
    var server: SOCKS5Server!
    var port: UInt16!

    override func setUpWithError() throws {
        port = freePort()
        var config = SOCKS5Server.Configuration()
        config.refuseLocalDestinations = false   // tests talk to loopback echo servers
        config.port = port
        server = SOCKS5Server(configuration: config) { user, pass in user == "mac" && pass == "secret" }
        try server.start()
    }

    override func tearDown() { server.stop() }

    private func handshake(_ client: TestClient, user: String = "mac", pass: String = "secret") {
        client.send([5, 1, 2])
        XCTAssertEqual(Array(client.read(2)), [5, 2])
        client.send([1, UInt8(user.utf8.count)] + Array(user.utf8) + [UInt8(pass.utf8.count)] + Array(pass.utf8))
    }

    func testRejectsBadPassword() {
        let client = TestClient(port: port)
        handshake(client, pass: "wrong")
        XCTAssertEqual(Array(client.read(2)), [1, 1])
        client.close()
    }

    func testRejectsClientsWithoutPasswordMethod() {
        let client = TestClient(port: port)
        client.send([5, 1, 0])
        XCTAssertEqual(Array(client.read(2)), [5, 0xFF])
        client.close()
    }

    func testConnectEchoesThroughProxy() throws {
        let echo = try EchoServer()
        let client = TestClient(port: port)
        handshake(client)
        XCTAssertEqual(Array(client.read(2)), [1, 0])
        client.send([5, 1, 0, 1, 127, 0, 0, 1, UInt8(echo.port >> 8), UInt8(echo.port & 0xFF)])
        let reply = client.read(10)
        XCTAssertEqual(Array(reply.prefix(2)), [5, 0])
        let payload = Data((0..<20000).map { UInt8($0 % 251) })
        client.send(payload)
        XCTAssertEqual(client.read(payload.count), payload)
        let snap = server.counter.snapshot()
        XCTAssertEqual(snap.rx, Int64(payload.count))
        XCTAssertEqual(snap.tx, Int64(payload.count))
        XCTAssertEqual(snap.active, 1)
        client.close()
    }

    func testConnectByDomainName() throws {
        let echo = try EchoServer()
        let client = TestClient(port: port)
        handshake(client)
        XCTAssertEqual(Array(client.read(2)), [1, 0])
        let name = Array("localhost".utf8)
        client.send([5, 1, 0, 3, UInt8(name.count)] + name + [UInt8(echo.port >> 8), UInt8(echo.port & 0xFF)])
        XCTAssertEqual(Array(client.read(10).prefix(2)), [5, 0])
        client.send(Data("hi".utf8))
        XCTAssertEqual(client.read(2), Data("hi".utf8))
        client.close()
    }

    func testConnectionRefusedIsReported() throws {
        let dead = freePort()
        let client = TestClient(port: port)
        handshake(client)
        XCTAssertEqual(Array(client.read(2)), [1, 0])
        client.send([5, 1, 0, 1, 127, 0, 0, 1, UInt8(dead >> 8), UInt8(dead & 0xFF)])
        let reply = client.read(10, timeout: 20)
        XCTAssertEqual(reply.count, 10)
        XCTAssertNotEqual(reply[1], 0)
        client.close()
    }

    func testUDPOverStream() throws {
        let udp = try UDPEchoServer()
        let client = TestClient(port: port)
        handshake(client)
        XCTAssertEqual(Array(client.read(2)), [1, 0])
        client.send([5, 5, 0, 1, 0, 0, 0, 0, 0, 0])
        XCTAssertEqual(Array(client.read(10).prefix(2)), [5, 0])
        let address = SOCKS5.Address.ipv4([127, 0, 0, 1], port: udp.port)
        let payload = Data("ping".utf8)
        client.send(SOCKS5.frameDatagram(address: address, payload: payload))
        let head = client.read(3)
        let length = Int(head[0]) << 8 | Int(head[1])
        XCTAssertEqual(Int(head[2]), 3 + address.count)
        XCTAssertEqual(client.read(address.count), address)
        XCTAssertEqual(client.read(length), Data("echo:ping".utf8))
        client.close()
    }
}

/// The phone's default: destinations nothing on its uplink can answer are refused.
final class SOCKS5LocalRefusalTests: XCTestCase {
    var server: SOCKS5Server!
    var port: UInt16!

    override func setUpWithError() throws {
        port = freePort()
        var config = SOCKS5Server.Configuration()
        config.port = port
        server = SOCKS5Server(configuration: config, authenticator: nil)
        try server.start()
    }

    override func tearDown() { server.stop() }

    private func connectReply(_ request: [UInt8]) -> [UInt8] {
        let client = TestClient(port: port)
        defer { client.close() }
        client.send([5, 1, 0])
        XCTAssertEqual(Array(client.read(2)), [5, 0])
        client.send(request)
        return Array(client.read(10).prefix(2))
    }

    func testRefusesLoopbackSpelledAsAName() throws {
        let echo = try EchoServer()
        let portBytes = [UInt8(echo.port >> 8), UInt8(echo.port & 0xFF)]
        for spelling in ["127.0.0.1", "127.1", "2130706433", "[::1]", "localhost."] {
            let name = Array(spelling.utf8)
            XCTAssertEqual(connectReply([5, 1, 0, 3, UInt8(name.count)] + name + portBytes), [5, SOCKS5.Reply.networkUnreachable], spelling)
        }
        XCTAssertEqual(connectReply([5, 1, 0, 1, 127, 0, 0, 1] + portBytes), [5, SOCKS5.Reply.networkUnreachable])
    }
}

final class LogPrivacyTests: XCTestCase {
    func testPrivatePartsAreRedactedOnlyWhenAsked() {
        let marked = "connect to \(ptPrivate("example.com:443")) failed: \(ptPrivate(42)) timed out"
        let shown = PassthroughLog.render(marked, redacting: false)
        XCTAssertEqual(shown.text, "connect to example.com:443 failed: 42 timed out")
        XCTAssertEqual(shown.hidden, [])
        let hidden = PassthroughLog.render(marked, redacting: true)
        XCTAssertEqual(hidden.text, "connect to <private> failed: <private> timed out")
        XCTAssertEqual(hidden.hidden, ["example.com:443", "42"])
        XCTAssertEqual(PassthroughLog.render("plain", redacting: true).text, "plain")
    }
}

final class ProtocolTests: XCTestCase {
    func testAddressParsing() {
        XCTAssertNil(SOCKS5.Address(raw: Data([1, 1, 2, 3])))
        let v4 = SOCKS5.Address(raw: Data([1, 10, 0, 0, 1, 0x1F, 0x90]))
        XCTAssertEqual(v4?.port.rawValue, 8080)
        XCTAssertEqual("\(v4!.host)", "10.0.0.1")
        let name = SOCKS5.Address(raw: Data([3, 3] + Array("a.b".utf8) + [0, 53]))
        XCTAssertEqual(name?.port.rawValue, 53)
        if case .name(let n, _)? = name?.host { XCTAssertEqual(n, "a.b") } else { XCTFail() }
        XCTAssertNil(SOCKS5.Address(raw: Data([3, 5] + Array("a.b".utf8) + [0, 53])))
        XCTAssertNotNil(SOCKS5.Address(raw: Data([4] + [UInt8](repeating: 0, count: 15) + [1] + [0, 80])))
    }

    func testControlEnvelopeRoundTrip() throws {
        var m = ControlEnvelope(t: "hello")
        m.clientID = "abc"; m.protocolVersion = 1; m.rxBytes = 42
        let line = try m.encodedLine()
        XCTAssertEqual(line.last, 0x0A)
        XCTAssertEqual(try ControlEnvelope.decode(line.dropLast()), m)
    }

    func testUSBMuxPacketFraming() throws {
        let packet = try USBMux.packet(["MessageType": "Listen"], tag: 7)
        let header = USBMux.parseHeader(packet.prefix(16))
        XCTAssertEqual(header?.length, packet.count)
        XCTAssertEqual(header?.tag, 7)
        let plist = try PropertyListSerialization.propertyList(from: packet.dropFirst(16), format: nil) as? [String: Any]
        XCTAssertEqual(plist?["MessageType"] as? String, "Listen")
        XCTAssertEqual(plist?["kLibUSBMuxVersion"] as? Int, 3)
    }
}

final class PairingTests: XCTestCase {
    var defaults: UserDefaults!
    var registry: PairingRegistry!
    let suite = "\(PassthroughProtocol.identifier).tests.\(UUID().uuidString)"

    override func setUp() {
        defaults = UserDefaults(suiteName: suite)
        registry = PairingRegistry(defaults: defaults)
    }

    override func tearDown() { defaults.removePersistentDomain(forName: suite) }

    func testPairVerifyRevoke() {
        let (code, _) = registry.issueCode()
        XCTAssertEqual(code.count, 6)
        XCTAssertEqual(registry.pair(code: "000000" == code ? "111111" : "000000", clientID: "m1", name: "Mac"), .failure(.badCode))
        guard case .success(let token) = registry.pair(code: code, clientID: "m1", name: "Mac") else { return XCTFail() }
        XCTAssertNil(registry.activeCode, "code is single use")
        XCTAssertTrue(registry.verify(clientID: "m1", token: token))
        XCTAssertFalse(registry.verify(clientID: "m1", token: token + "x"))
        XCTAssertFalse(registry.verify(clientID: "m2", token: token))
        XCTAssertEqual(registry.clients.map(\.name), ["Mac"])
        registry.revoke(clientID: "m1")
        XCTAssertFalse(registry.verify(clientID: "m1", token: token))
    }

    func testExpiredCodeRejected() {
        registry.issueCode()
        defaults.set(Date().timeIntervalSince1970 - 1, forKey: PairingRegistry.codeExpiryKey)
        XCTAssertEqual(registry.pair(code: defaults.string(forKey: PairingRegistry.codeKey) ?? "", clientID: "m", name: "Mac"), .failure(.expired))
    }

    /// The iOS app issues codes and the tunnel extension checks them: two
    /// registries on one set of defaults. Five wrong guesses lock code entry
    /// for 30 s, even for the right code; the code itself stays.
    func testWrongGuessesLockCodeEntryAcrossProcesses() {
        let app = registry!
        let tunnel = PairingRegistry(defaults: defaults)
        func wrong(_ code: String) -> String { code == "000000" ? "111111" : "000000" }

        let code = app.issueCode().code
        for _ in 0..<4 { XCTAssertEqual(tunnel.pair(code: wrong(code), clientID: "m", name: "Mac"), .failure(.badCode)) }
        XCTAssertEqual(tunnel.pair(code: wrong(code), clientID: "m", name: "Mac"), .failure(.locked), "the fifth wrong guess locks code entry")
        XCTAssertEqual(defaults.double(forKey: PairingRegistry.lockedUntilKey), Date().timeIntervalSince1970 + PassthroughProtocol.pairingLockout, accuracy: 2)
        XCTAssertEqual(app.activeCode?.code, code, "the code is not withdrawn")
        XCTAssertEqual(tunnel.pair(code: code, clientID: "m", name: "Mac"), .failure(.locked), "not even the right code while locked")
        XCTAssertEqual(app.pair(code: code, clientID: "m", name: "Mac"), .failure(.locked))

        // The lock runs out: the count starts over and the right code works.
        defaults.set(Date().timeIntervalSince1970 - 1, forKey: PairingRegistry.lockedUntilKey)
        XCTAssertEqual(tunnel.pair(code: wrong(code), clientID: "m", name: "Mac"), .failure(.badCode))
        guard case .success = tunnel.pair(code: code, clientID: "m", name: "Mac") else { return XCTFail() }
    }

    /// The SOCKS5 password is derived from the pairing, never the token itself.
    func testSOCKSPasswordIsDerivedFromThePairing() {
        let (code, _) = registry.issueCode()
        guard case .success(let token) = registry.pair(code: code, clientID: "m1", name: "Mac") else { return XCTFail() }
        XCTAssertTrue(registry.verifySOCKS(clientID: "m1", password: ControlAuth.socksPassword(token: token)))
        XCTAssertFalse(registry.verifySOCKS(clientID: "m1", password: token), "the token is not the password")
        XCTAssertFalse(registry.verifySOCKS(clientID: "m2", password: ControlAuth.socksPassword(token: token)))
        XCTAssertFalse(registry.verifySOCKS(clientID: "m1", password: ControlAuth.socksPassword(token: PairingToken.generate())))
    }
}

final class ControlServerTests: XCTestCase {
    private var defaults: UserDefaults!
    private var registry: PairingRegistry!
    private var server: ControlServer!
    private var port: UInt16 = 0
    private let suite = "\(PassthroughProtocol.identifier).tests.\(UUID().uuidString)"

    override func tearDown() {
        server?.stop()
        defaults?.removePersistentDomain(forName: suite)
    }

    private func start(unauthenticatedTimeout: TimeInterval = PassthroughProtocol.unauthenticatedTimeout,
                       cableSilenceLimit: TimeInterval = PassthroughProtocol.cableSilenceLimit) throws {
        defaults = UserDefaults(suiteName: suite)!
        registry = PairingRegistry(defaults: defaults, secrets: InMemorySecrets())
        let counter = ByteCounter()
        counter.addRx(100)
        port = freePort()
        server = ControlServer(port: port, socksPort: 7890, registry: registry, counter: counter,
                               unauthenticatedTimeout: unauthenticatedTimeout, cableSilenceLimit: cableSilenceLimit) {
            DeviceStatus(deviceName: "Test iPhone", radio: "5G", hosting: "test")
        }
        try server.start()
    }

    private func send(_ m: ControlEnvelope, on client: TestClient) throws { client.send(try m.encodedLine()) }
    private func receive(_ client: TestClient) throws -> ControlEnvelope { try ControlEnvelope.decode(client.readLine()) }

    /// Says hello as the Mac would; returns the welcome and the nonce sent.
    private func hello(_ client: TestClient, clientID: String = "mac1") throws -> (welcome: ControlEnvelope, macNonce: Data) {
        let nonce = ControlAuth.nonce()
        var hello = ControlEnvelope(t: "hello"); hello.protocolVersion = 2; hello.clientID = clientID; hello.name = "MacBook"
        hello.nonce = nonce.base64EncodedString()
        try send(hello, on: client)
        return (try receive(client), nonce)
    }

    private func paired(_ clientID: String = "mac1") -> String {
        let (code, _) = registry.issueCode()
        guard case .success(let token) = registry.pair(code: code, clientID: clientID, name: "MacBook") else { XCTFail(); return "" }
        return token
    }

    private func auth(_ client: TestClient, token: String, welcome: ControlEnvelope, macNonce: Data, clientID: String = "mac1") throws {
        var auth = ControlEnvelope(t: "auth")
        auth.proof = ControlAuth.macProof(key: ControlAuth.key(token: token), clientID: clientID, macNonce: macNonce,
                                          phoneNonce: try XCTUnwrap(ControlAuth.decodeNonce(welcome.nonce))).base64EncodedString()
        try send(auth, on: client)
    }

    /// Everything sent before it has been handled; returns what came first.
    private func sync(_ client: TestClient) throws -> [ControlEnvelope] {
        try send(ControlEnvelope(t: "ping"), on: client)
        var seen: [ControlEnvelope] = []
        while true {
            let m = try receive(client)
            if m.t == "pong" { return seen }
            seen.append(m)
        }
    }

    func testHelloPairAndStatus() throws {
        try start()
        let client = TestClient(port: port)
        let (welcome, _) = try hello(client)
        XCTAssertEqual(welcome.t, "welcome")
        XCTAssertEqual(welcome.paired, false)
        XCTAssertNil(welcome.proof)
        XCTAssertNotNil(ControlAuth.decodeNonce(welcome.nonce), "a nonce even when unpaired")
        XCTAssertEqual(welcome.deviceName, "Test iPhone")

        var pair = ControlEnvelope(t: "pair"); pair.clientID = "mac1"; pair.name = "MacBook"; pair.code = "nope"
        try send(pair, on: client)
        XCTAssertEqual(try receive(client).reason, "expired")

        let (code, _) = registry.issueCode()
        pair.code = code
        try send(pair, on: client)
        let paired = try receive(client)
        XCTAssertEqual(paired.t, "paired")
        let token = try XCTUnwrap(paired.token)
        XCTAssertTrue(registry.verify(clientID: "mac1", token: token))
        let status = try receive(client)
        XCTAssertEqual(status.t, "status")
        XCTAssertEqual(status.rxBytes, 100)
        XCTAssertEqual(server.connectedMacs.map(\.name), ["MacBook"])
        client.close()

        // Reconnect: the phone proves the pairing first, then the Mac does.
        let client2 = TestClient(port: port)
        let (again, macNonce) = try hello(client2)
        XCTAssertEqual(again.paired, true)
        XCTAssertNil(again.token)
        let phoneNonce = try XCTUnwrap(ControlAuth.decodeNonce(again.nonce))
        XCTAssertTrue(ControlAuth.isValidPhoneProof(again.proof, key: ControlAuth.key(token: token), clientID: "mac1", macNonce: macNonce, phoneNonce: phoneNonce))
        XCTAssertFalse(ControlAuth.isValidPhoneProof(again.proof, key: ControlAuth.key(token: token), clientID: "mac1", macNonce: ControlAuth.nonce(), phoneNonce: phoneNonce),
                       "the proof is bound to this connection's nonce")
        try auth(client2, token: token, welcome: again, macNonce: macNonce)
        XCTAssertEqual(try receive(client2).t, "status", "authenticated: status flows")
        client2.close()
    }

    /// A Mac from before version 2 (token in hello) is refused, with our version so it knows who to update.
    func testRefusesOldProtocolVersion() throws {
        try start()
        let token = paired()
        let client = TestClient(port: port)
        var hello = ControlEnvelope(t: "hello"); hello.protocolVersion = 1; hello.clientID = "mac1"; hello.name = "MacBook"; hello.token = token
        try send(hello, on: client)
        let reply = try receive(client)
        XCTAssertEqual(reply.t, "error")
        XCTAssertEqual(reply.reason, "unsupported_version")
        XCTAssertEqual(reply.protocolVersion, 2)
        XCTAssertTrue(client.readLine().isEmpty, "and the connection is closed")
        XCTAssertTrue(server.connectedMacs.isEmpty)
    }

    /// Before the Mac proves the pairing, nothing privileged is acted on; a wrong proof ends the connection.
    func testPrivilegedMessagesNeedTheMacsProof() throws {
        try start()
        let token = paired()
        let client = TestClient(port: port)
        let (welcome, macNonce) = try hello(client)
        XCTAssertEqual(welcome.paired, true)

        var link = ControlEnvelope(t: "link"); link.linkKey = WirelessLink.randomBytes(32).base64EncodedString(); link.certSHA256 = String(repeating: "b", count: 64)
        var grant = ControlEnvelope(t: "shellGrant"); grant.shellKey = WirelessLink.randomBytes(32).base64EncodedString()
        grant.certSHA256 = String(repeating: "b", count: 64); grant.shellPort = 7893; grant.addresses = []; grant.macName = "M"
        try send(link, on: client)
        try send(grant, on: client)
        XCTAssertEqual(try sync(client).map(\.t), [], "no linked, shellGranted or status before auth")
        XCTAssertTrue(registry.linkCredentials().isEmpty)
        XCTAssertNil(registry.sealedPendingShellKey(clientID: "mac1"))
        XCTAssertTrue(server.connectedMacs.isEmpty)

        // A proof made with another token (or over other nonces) is refused.
        try auth(client, token: PairingToken.generate(), welcome: welcome, macNonce: macNonce)
        let refused = try receive(client)
        XCTAssertEqual(refused.t, "error")
        XCTAssertEqual(refused.reason, "not_authenticated")
        XCTAssertTrue(client.readLine().isEmpty, "and the connection is closed")
        XCTAssertTrue(server.connectedMacs.isEmpty)

        // The right proof lets the same messages through.
        let good = TestClient(port: port)
        let (w, n) = try hello(good)
        try auth(good, token: token, welcome: w, macNonce: n)
        try send(link, on: good)
        XCTAssertTrue(try sync(good).contains { $0.t == "linked" })
        XCTAssertEqual(registry.linkCredentials().count, 1)
        good.close()
    }

    /// A connection that proves nothing is closed after the timeout, unless a
    /// code is showing; once it goes, so does the extra time.
    func testUnauthenticatedConnectionsAreClosed() throws {
        try start(unauthenticatedTimeout: 1)
        let silent = TestClient(port: port)
        let start = Date()
        XCTAssertTrue(silent.readLine(timeout: 5).isEmpty)
        XCTAssertLessThan(Date().timeIntervalSince(start), 4)

        registry.issueCode()
        let pairing = TestClient(port: port)
        _ = try hello(pairing, clientID: "mac2")
        Thread.sleep(forTimeInterval: 2.5)
        XCTAssertEqual(try sync(pairing).count, 0, "still open while the code shows")
        registry.clearCode()
        XCTAssertTrue(pairing.readLine(timeout: 5).isEmpty)
    }

    /// An authenticated Mac that stops talking is dropped.
    func testSilentMacIsDropped() throws {
        try start(cableSilenceLimit: 1)
        let token = paired()
        let client = TestClient(port: port)
        let (welcome, macNonce) = try hello(client)
        try auth(client, token: token, welcome: welcome, macNonce: macNonce)
        _ = try sync(client)
        XCTAssertEqual(server.connectedMacs.count, 1)
        var lines = 0
        while !client.readLine(timeout: 5).isEmpty { lines += 1 }
        XCTAssertLessThan(lines, 5, "closed after a second or two of silence")
        XCTAssertTrue(server.connectedMacs.isEmpty)
    }

    /// A pair before hello (which checks the version) is not taken.
    func testPairNeedsHello() throws {
        try start()
        let (code, _) = registry.issueCode()
        let client = TestClient(port: port)
        var pair = ControlEnvelope(t: "pair"); pair.clientID = "mac1"; pair.name = "MacBook"; pair.code = code
        try send(pair, on: client)
        XCTAssertEqual(try receive(client).reason, "not_authenticated")
        XCTAssertTrue(registry.clients.isEmpty)
        XCTAssertNotNil(registry.activeCode)
        client.close()
    }
}
