import XCTest
import Network
@testable import PassthroughCore
@testable import USBMux

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
    let suite = "dev.dpatel.passthrough.tests.\(UUID().uuidString)"

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
}

final class ControlServerTests: XCTestCase {
    func testHelloPairAndStatus() throws {
        let suite = "dev.dpatel.passthrough.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let registry = PairingRegistry(defaults: defaults)
        let counter = ByteCounter()
        counter.addRx(100)
        let port = freePort()
        let server = ControlServer(port: port, socksPort: 7890, registry: registry, counter: counter) {
            DeviceStatus(deviceName: "Test iPhone", radio: "5G", hosting: "test")
        }
        try server.start()
        defer { server.stop() }

        let client = TestClient(port: port)
        var hello = ControlEnvelope(t: "hello"); hello.protocolVersion = 1; hello.clientID = "mac1"; hello.name = "MacBook"
        client.send(try hello.encodedLine())
        var welcome = try ControlEnvelope.decode(client.readLine())
        XCTAssertEqual(welcome.t, "welcome")
        XCTAssertEqual(welcome.paired, false)
        XCTAssertEqual(welcome.deviceName, "Test iPhone")

        var pair = ControlEnvelope(t: "pair"); pair.clientID = "mac1"; pair.name = "MacBook"; pair.code = "nope"
        client.send(try pair.encodedLine())
        XCTAssertEqual(try ControlEnvelope.decode(client.readLine()).reason, "expired")

        let (code, _) = registry.issueCode()
        pair.code = code
        client.send(try pair.encodedLine())
        let paired = try ControlEnvelope.decode(client.readLine())
        XCTAssertEqual(paired.t, "paired")
        let token = try XCTUnwrap(paired.token)
        XCTAssertTrue(registry.verify(clientID: "mac1", token: token))
        let status = try ControlEnvelope.decode(client.readLine())
        XCTAssertEqual(status.t, "status")
        XCTAssertEqual(status.rxBytes, 100)
        XCTAssertEqual(server.connectedMacs.map(\.name), ["MacBook"])
        client.close()

        // Reconnect with the token: welcome says paired.
        let client2 = TestClient(port: port)
        hello.token = token
        client2.send(try hello.encodedLine())
        welcome = try ControlEnvelope.decode(client2.readLine())
        XCTAssertEqual(welcome.paired, true)
        client2.close()
    }
}
