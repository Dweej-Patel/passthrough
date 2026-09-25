import XCTest
import Network
import CryptoKit
@testable import PassthroughCore
@testable import PhoneTransport

/// Our certificate for an in-memory key, as an in-memory TLS identity: the
/// system openssl packages key and certificate as PKCS#12 and Security imports
/// it without a keychain (tests can't use the data-protection keychain).
@available(macOS 15, *)
func makeTestIdentity() throws -> MacIdentity {
    let key = P256.Signing.PrivateKey()
    let tbs = CertificateDER.tbs(publicKeyPoint: key.publicKey.x963Representation, commonName: "Passthrough Mac")
    let der = CertificateDER.certificate(tbs: tbs, signature: try key.signature(for: tbs).derRepresentation)
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let pem = "-----BEGIN CERTIFICATE-----\n" + der.base64EncodedString(options: .lineLength64Characters) + "\n-----END CERTIFICATE-----\n"
    try pem.write(to: dir.appendingPathComponent("c.pem"), atomically: true, encoding: .utf8)
    try key.pemRepresentation.write(to: dir.appendingPathComponent("k.pem"), atomically: true, encoding: .utf8)
    let openssl = Process()
    openssl.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
    openssl.currentDirectoryURL = dir
    openssl.arguments = ["pkcs12", "-export", "-inkey", "k.pem", "-in", "c.pem", "-passout", "pass:test", "-out", "id.p12"]
    try openssl.run(); openssl.waitUntilExit()
    let p12 = try Data(contentsOf: dir.appendingPathComponent("id.p12"))
    var items: CFArray?
    let status = SecPKCS12Import(p12 as CFData, [kSecImportExportPassphrase: "test", kSecImportToMemoryOnly: true] as CFDictionary, &items)
    guard status == errSecSuccess, let first = (items as? [[String: Any]])?.first,
          let identity = first[kSecImportItemIdentity as String] else { throw MacIdentity.IdentityError.keychain(status, "p12 import") }
    return MacIdentity(identity: identity as! SecIdentity, certificate: der)
}

/// The whole wireless link over loopback: TLS 1.3 with a pinned self-made
/// certificate, the link-key challenge, and streams spliced to a local port.
@available(macOS 15, *)
final class WirelessLinkTests: XCTestCase {
    private var label = ""
    private var identity: MacIdentity!
    private var echo: NWListener!
    private var echoPort: UInt16 = 0
    private let key = WirelessLink.randomBytes(32)
    private let echoConnections = Locked<[NWConnection]>([])

    override func setUpWithError() throws {
        label = "passthrough-test-\(UUID().uuidString)"
        // The openssl/PKCS#12 step very rarely fails on a busy machine; retry.
        identity = try (try? makeTestIdentity()) ?? (try? makeTestIdentity()) ?? makeTestIdentity()
        echo = try NWListener(using: .tcp, on: .any)
        let ready = expectation(description: "echo ready")
        echo.stateUpdateHandler = { if case .ready = $0 { ready.fulfill() } }
        // Held until the test ends: a freed NWConnection resets (RST), and the
        // far side then loses whatever it had not read yet.
        let held = echoConnections
        echo.newConnectionHandler = { c in
            held.set(held.get() + [c])
            c.start(queue: .global())
            func loop() {
                c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, complete, _ in
                    if let data { c.send(content: data, completion: .contentProcessed { _ in }) }
                    if complete { c.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .idempotent); return }
                    loop()
                }
            }
            loop()
        }
        echo.start(queue: .global())
        wait(for: [ready], timeout: 5)
        echoPort = echo.port!.rawValue
    }

    override func tearDown() {
        echo?.cancel()
        echoConnections.get().forEach { $0.cancel() }
        MacIdentity.delete(label: label, dataProtection: false)
    }

    /// Personal Hotspot is named from its addresses, whatever the interface is called.
    func testCarrierNames() {
        XCTAssertTrue(WirelessLink.isHotspotAddress(.hostPort(host: "172.20.10.1", port: 1)))
        XCTAssertTrue(WirelessLink.isHotspotAddress(.hostPort(host: "172.20.10.14", port: 1)))
        XCTAssertFalse(WirelessLink.isHotspotAddress(.hostPort(host: "172.20.10.16", port: 1)))
        XCTAssertFalse(WirelessLink.isHotspotAddress(.hostPort(host: "192.168.1.20", port: 1)))
        XCTAssertFalse(WirelessLink.isHotspotAddress(nil))
        XCTAssertEqual(WirelessLink.carrier(interface: "awdl0"), "Peer-to-peer")
        XCTAssertEqual(WirelessLink.carrier(interface: "bridge100"), "Hotspot")
        XCTAssertEqual(WirelessLink.carrier(interface: "en0", onPhoneHotspot: true), "Hotspot")
        XCTAssertEqual(WirelessLink.carrier(interface: "en0"), "Wi-Fi network")
        XCTAssertEqual(WirelessLink.carrier(interface: "anpi0"), "USB")
    }

    func testCertificateIsWellFormedAndKeychainIdentityIsStable() throws {
        XCTAssertNotNil(SecCertificateCreateWithData(nil, identity.certificate as CFData))
        let stored = try MacIdentity.loadOrCreate(label: label, dataProtection: false)
        let again = try MacIdentity.loadOrCreate(label: label, dataProtection: false)
        XCTAssertEqual(again.fingerprint, stored.fingerprint, "loaded, not regenerated")
        XCTAssertEqual(stored.fingerprint.count, 64)
    }

    /// Starts a listener and dials it; returns the Mac's mux if a link forms.
    private func link(pin: String? = nil, dialKey: Data? = nil, timeout: TimeInterval = 5) -> Mux? {
        let key = self.key
        let listener = WirelessListener(identity: identity, macTag: "t", advertise: false) { $0 == "phone-1" ? key : nil }
        let linked = expectation(description: "linked")
        linked.isInverted = pin != nil || dialKey != nil
        let muxBox = Locked<Mux?>(nil)
        listener.onLink = { link in muxBox.set(link.mux); link.mux.start(); linked.fulfill() }
        let listening = expectation(description: "listening")
        try! listener.start { _ in listening.fulfill() }
        wait(for: [listening], timeout: 5)
        let dialer = WirelessDialer(allowedPorts: [echoPort]) { [] }
        let credential = LinkCredential(macTag: "t", certSHA256: pin ?? identity.fingerprint, linkKey: dialKey ?? key, phoneID: "phone-1")
        dialer.dial(.hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: listener.port!)!), credential: credential, peerToPeer: false)
        wait(for: [linked], timeout: timeout)
        addTeardownBlock { dialer.stop(); listener.stop() }
        return muxBox.get()
    }

    func testStreamsReachThePhonesLocalPort() {
        guard let mux = link() else { return XCTFail("no link") }
        let payload = Data((0..<1_000_000).map { UInt8(truncatingIfNeeded: $0 &* 7) })
        let opened = expectation(description: "stream")
        let got = Locked(Data()), done = expectation(description: "echoed")
        MuxLink(mux: mux).connect(port: echoPort, queue: .global()) { result in
            guard case .success(let stream) = result else { return XCTFail() }
            opened.fulfill()
            readAll(stream, into: got, done: done)
            stream.send(payload, isComplete: true) { XCTAssertNil($0) }
        }
        wait(for: [opened, done], timeout: 15)
        XCTAssertEqual(got.get(), payload)
    }

    /// Break the real TLS link mid-transfer: the phone redials, the Mac
    /// resumes the same session, and every byte still arrives once.
    func testLinkResumesAfterADrop() {
        guard let mux = link() else { return XCTFail("no link") }
        let payload = Data((0..<3_000_000).map { UInt8(truncatingIfNeeded: $0 &* 11) })
        let got = Locked(Data()), done = expectation(description: "echoed")
        let dropped = Locked(false)
        MuxLink(mux: mux).connect(port: echoPort, queue: .global()) { result in
            guard case .success(let stream) = result else { return XCTFail() }
            func read() {
                stream.receive(maximumLength: 65536) { chunk, complete, error in
                    if let chunk { got.set(got.get() + chunk) }
                    if !dropped.get(), got.get().count > 500_000 { dropped.set(true); mux.interruptForTesting() }
                    if complete || error != nil { XCTAssertNil(error); done.fulfill(); return }
                    read()
                }
            }
            read()
            stream.send(payload, isComplete: true) { XCTAssertNil($0) }
        }
        wait(for: [done], timeout: 20)
        XCTAssertTrue(dropped.get())
        XCTAssertEqual(got.get(), payload)
    }

    /// Hundreds of open streams make the resume handshake line long; the
    /// link must still resume, keeping old streams and taking new ones.
    func testResumeWithManyOpenStreams() {
        guard let mux = link() else { return XCTFail("no link") }
        let link = MuxLink(mux: mux)
        var streams: [ByteStream] = []
        let opened = expectation(description: "opened")
        opened.expectedFulfillmentCount = 300
        // In batches, as real traffic arrives: 300 connects in one instant
        // would overflow the echo server's listen backlog (128).
        for batch in 0..<6 {
            for _ in 0..<50 {
                link.connect(port: echoPort, queue: .global()) { result in
                    if case .success(let s) = result { streams.append(s) }
                    opened.fulfill()
                }
            }
            if batch < 5 { Thread.sleep(forTimeInterval: 0.2) }
        }
        wait(for: [opened], timeout: 10)
        // Let the phone see all 300 before the drop.
        let settled = expectation(description: "settled")
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) { settled.fulfill() }
        wait(for: [settled], timeout: 3)
        mux.interruptForTesting()
        // While it waits to resume, new streams are refused at once.
        for _ in 0..<50 where !mux.isSuspended { Thread.sleep(forTimeInterval: 0.01) }
        let refused = expectation(description: "refused while suspended")
        link.connect(port: echoPort, queue: .global()) { result in
            if case .failure = result { refused.fulfill() }
        }
        wait(for: [refused], timeout: 1)
        func roundTrip(_ stream: ByteStream, _ text: String) -> XCTestExpectation {
            let done = expectation(description: text)
            stream.send(Data(text.utf8), isComplete: false) { _ in }
            stream.receive(maximumLength: 100) { data, _, error in
                XCTAssertNil(error); XCTAssertEqual(data.map { String(decoding: $0, as: UTF8.self) }, text); done.fulfill()
            }
            return done
        }
        let old = roundTrip(streams[150], "still here")
        wait(for: [old], timeout: 15)
        var fresh: ByteStream?
        let newOne = expectation(description: "new stream")
        link.connect(port: echoPort, queue: .global()) { result in
            if case .success(let s) = result { fresh = s }
            newOne.fulfill()
        }
        wait(for: [newOne], timeout: 5)
        wait(for: [roundTrip(fresh!, "and new")], timeout: 10)
    }

    func testOnlyAllowedPortsCanBeOpened() {
        guard let mux = link() else { return XCTFail("no link") }
        let refused = expectation(description: "refused")
        MuxLink(mux: mux).connect(port: 22, queue: .global()) { result in
            guard case .success(let stream) = result else { return XCTFail() }
            stream.receive(maximumLength: 10) { _, _, error in XCTAssertNotNil(error); refused.fulfill() }
        }
        wait(for: [refused], timeout: 5)
    }

    func testWrongPinIsRefused() {
        XCTAssertNil(link(pin: String(repeating: "0", count: 64), timeout: 3))
    }

    func testWrongLinkKeyIsRefused() {
        XCTAssertNil(link(dialKey: WirelessLink.randomBytes(32), timeout: 3))
    }

    /// A Mac forgotten on the phone (in the app, another process) loses its
    /// link as soon as the dialer looks again, not whenever the link next drops.
    func testForgottenMacLosesItsLink() {
        let key = self.key
        let listener = WirelessListener(identity: identity, macTag: "t", advertise: false) { $0 == "phone-1" ? key : nil }
        let linked = expectation(description: "linked"), dropped = expectation(description: "dropped")
        listener.onLink = { link in
            link.mux.onSuspend = { _ in dropped.fulfill() }
            link.mux.start()
            linked.fulfill()
        }
        let listening = expectation(description: "listening")
        try! listener.start { _ in listening.fulfill() }
        wait(for: [listening], timeout: 5)
        let credential = LinkCredential(macTag: "t", certSHA256: identity.fingerprint, linkKey: key, phoneID: "phone-1")
        let known = Locked([credential])
        let dialer = WirelessDialer(allowedPorts: [echoPort]) { known.get() }
        addTeardownBlock { dialer.stop(); listener.stop() }
        dialer.start()
        dialer.dial(.hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: listener.port!)!), credential: credential, peerToPeer: false)
        wait(for: [linked], timeout: 5)
        known.set([])
        dialer.refresh()
        wait(for: [dropped], timeout: 5)
    }

    private func startListener() -> WirelessListener {
        let listener = WirelessListener(identity: identity, macTag: "t", advertise: false) { _ in nil }
        let listening = expectation(description: "listening")
        try! listener.start { _ in listening.fulfill() }
        wait(for: [listening], timeout: 5)
        addTeardownBlock { listener.stop() }
        return listener
    }

    /// Anyone on the network can connect: one address may hold two
    /// handshakes, and a third from it is refused at once.
    func testOneAddressCannotHoldEveryHandshakeSlot() {
        let port = NWEndpoint.Port(rawValue: startListener().port!)!
        let held = Locked<[NWConnection]>([])
        addTeardownBlock { held.get().forEach { $0.cancel() } }
        func connect(_ closed: XCTestExpectation) {
            let c = NWConnection(host: "127.0.0.1", port: port, using: .tcp)   // never starts TLS
            held.set(held.get() + [c])
            c.stateUpdateHandler = { state in
                guard case .ready = state else { return }
                c.receive(minimumIncompleteLength: 1, maximumLength: 1) { _, _, complete, error in
                    if complete || error != nil { closed.fulfill() }
                }
            }
            c.start(queue: .global())
        }
        let first = expectation(description: "first kept"), second = expectation(description: "second kept")
        first.isInverted = true; second.isInverted = true
        connect(first); connect(second)
        Thread.sleep(forTimeInterval: 0.3)   // both accepted before the third arrives
        let third = expectation(description: "third refused")
        connect(third)
        wait(for: [third], timeout: 3)
        wait(for: [first, second], timeout: 0.5)
    }

    /// Before it has proved anything, a connection may not send more than a
    /// proof's worth: it is closed long before the handshake would time out.
    func testOversizedFirstLineIsRefused() {
        let port = NWEndpoint.Port(rawValue: startListener().port!)!
        let connection = NWConnection(to: .hostPort(host: "127.0.0.1", port: port),
                                      using: WirelessLink.pinnedClientParameters(pin: identity.fingerprint, peerToPeer: false))
        let stream = ConnectionStream(connection, queue: .global())
        addTeardownBlock { stream.cancel() }
        let closed = expectation(description: "closed")
        WirelessLink.readLine(stream) { result in   // the challenge
            guard case .success = result else { return XCTFail("no challenge") }
            stream.send(Data(repeating: 0x61, count: WirelessListener.proofLineLimit + 4096), isComplete: false) { _ in }
            func drain() {
                stream.receive(maximumLength: 65536) { _, complete, error in
                    if complete || error != nil { closed.fulfill() } else { drain() }
                }
            }
            drain()
        }
        wait(for: [closed], timeout: WirelessLink.handshakeTimeout / 2)
    }
}

/// The Mac's watcher must replace a phone that links again with a new session,
/// not keep handing out the closed link under the same device ID.
@available(macOS 15, *)
@MainActor
final class WirelessWatcherTests: XCTestCase {
    func testRelinkedPhoneIsReportedAsNew() async throws {
        let identity = try makeTestIdentity()
        let key = WirelessLink.randomBytes(32)
        let phone = WirelessPhone(phoneID: "P", linkKey: key, isAndroid: false, label: "iPhone", pairingSlot: "token")
        let watcher = WirelessWatcher(macTag: { "t" }, identity: { identity }, phones: { [phone] })
        let directory = DeviceDirectory(watchers: [watcher])
        var changes: [String] = []
        var devices: [PhoneDevice] = []
        directory.onChange = { change in
            switch change {
            case .attached(let d): changes.append("+"); devices.append(d)
            case .detached: changes.append("-")
            }
        }
        watcher.start()
        defer { watcher.stop() }
        // Find the listener's port, then dial twice with fresh dialers (a phone restart).
        var port: UInt16?
        for _ in 0..<50 where port == nil {
            try await Task.sleep(nanoseconds: 50_000_000)
            port = Mirror(reflecting: watcher).descendant("listener", "some", "port") as? UInt16
        }
        let endpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: try XCTUnwrap(port))!)
        let credential = LinkCredential(macTag: "t", certSHA256: identity.fingerprint, linkKey: key, phoneID: "P")
        for round in 1...2 {
            let dialer = WirelessDialer(allowedPorts: []) { [] }
            dialer.dial(endpoint, credential: credential, peerToPeer: false)
            for _ in 0..<100 where changes.filter({ $0 == "+" }).count < round {
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            if round == 1 { withExtendedLifetime(dialer) {} }
        }
        XCTAssertEqual(changes, ["+", "-", "+"])
        XCTAssertEqual(devices.count, 2)
        XCTAssertFalse(devices[0].link as? MuxLink == nil)
        XCTAssertTrue((devices[0].link as! MuxLink).mux.isClosed, "the first link was closed")
        XCTAssertFalse((devices[1].link as! MuxLink).mux.isClosed, "the new link is live")
    }
}
