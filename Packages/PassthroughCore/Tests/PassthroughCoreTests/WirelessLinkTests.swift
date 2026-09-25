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
        identity = try makeTestIdentity()
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
}
