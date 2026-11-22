import Foundation
import XCTest
@testable import PassthroughCore
@testable import RemoteDesktop

final class RDPCertificatePinTests: XCTestCase {
    /// SHA-256 of the five bytes "hello".
    private let helloHash = "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"

    private func pem(_ ders: [Data]) -> Data {
        Data(ders.map { der in
            "-----BEGIN CERTIFICATE-----\n" + der.base64EncodedString(options: .lineLength64Characters) + "\n-----END CERTIFICATE-----\n"
        }.joined().utf8)
    }

    func testTheLeafMatchesItsHash() {
        XCTAssertEqual(RDPCertificatePin.hash(der: Data("hello".utf8)), helloHash)
        XCTAssertTrue(RDPCertificatePin.matches(pem: pem([Data("hello".utf8)]), sha256Hex: helloHash))
    }

    /// The pin is on the leaf: a chain whose issuer matches but whose leaf doesn't is refused.
    func testOnlyTheLeafCounts() {
        let chain = pem([Data("not the one".utf8), Data("hello".utf8)])
        XCTAssertFalse(RDPCertificatePin.matches(pem: chain, sha256Hex: helloHash))
    }

    func testAnythingElseNeverMatches() {
        XCTAssertFalse(RDPCertificatePin.matches(pem: pem([Data("hello".utf8)]), sha256Hex: helloHash.uppercased()))
        XCTAssertFalse(RDPCertificatePin.matches(pem: pem([Data("hello".utf8)]), sha256Hex: String(helloHash.dropLast())))
        XCTAssertFalse(RDPCertificatePin.matches(pem: Data("garbage".utf8), sha256Hex: helloHash))
        XCTAssertFalse(RDPCertificatePin.matches(pem: Data(), sha256Hex: helloHash))
        // A grant made before any listener carries sixty-four zeros: never a pin to accept.
        XCTAssertFalse(RDPCertificatePin.matches(pem: pem([Data("hello".utf8)]), sha256Hex: String(repeating: "0", count: 64)))
    }

    func testRDPReadyHashFormat() {
        XCTAssertTrue(ShellClient.isCertificateHash(helloHash))
        XCTAssertFalse(ShellClient.isCertificateHash(helloHash.uppercased()))
        XCTAssertFalse(ShellClient.isCertificateHash(String(helloHash.dropLast())))
        XCTAssertFalse(ShellClient.isCertificateHash(String(helloHash.dropLast()) + "g"))
    }
}

final class WindowsKeymapTests: XCTestCase {
    typealias Stroke = WindowsKeymap.Stroke

    func testSpecialKeys() {
        XCTAssertEqual(WindowsKeymap.scancode(for: RFBKeys.escape), WindowsKeymap.Scancode(0x01))
        XCTAssertEqual(WindowsKeymap.scancode(for: RFBKeys.left), WindowsKeymap.Scancode(0x4B, extended: true))
        XCTAssertEqual(WindowsKeymap.scancode(for: RFBKeys.delete), WindowsKeymap.Scancode(0x53, extended: true))
        XCTAssertEqual(WindowsKeymap.scancode(for: RFBKeys.function(1)), WindowsKeymap.Scancode(0x3B))
        XCTAssertEqual(WindowsKeymap.scancode(for: RFBKeys.function(10)), WindowsKeymap.Scancode(0x44))
        XCTAssertEqual(WindowsKeymap.scancode(for: RFBKeys.function(12)), WindowsKeymap.Scancode(0x58))
        XCTAssertEqual(WindowsKeymap.scancode(for: RFBKeys.windows), WindowsKeymap.Scancode(0x5B, extended: true))
    }

    func testUSPositions() {
        XCTAssertEqual(WindowsKeymap.scancode(for: 0x60), WindowsKeymap.Scancode(0x29))              // `
        XCTAssertEqual(WindowsKeymap.scancode(for: 0x31), WindowsKeymap.Scancode(0x02))              // 1
        XCTAssertEqual(WindowsKeymap.scancode(for: 0x30), WindowsKeymap.Scancode(0x0B))              // 0
        XCTAssertEqual(WindowsKeymap.scancode(for: 0x3D), WindowsKeymap.Scancode(0x0D))              // =
        XCTAssertEqual(WindowsKeymap.scancode(for: 0x2B), WindowsKeymap.Scancode(0x0D, shift: true)) // +
        XCTAssertEqual(WindowsKeymap.scancode(for: 0x71), WindowsKeymap.Scancode(0x10))              // q
        XCTAssertEqual(WindowsKeymap.scancode(for: 0x5D), WindowsKeymap.Scancode(0x1B))              // ]
        XCTAssertEqual(WindowsKeymap.scancode(for: 0x61), WindowsKeymap.Scancode(0x1E))              // a
        XCTAssertEqual(WindowsKeymap.scancode(for: 0x27), WindowsKeymap.Scancode(0x28))              // '
        XCTAssertEqual(WindowsKeymap.scancode(for: 0x7A), WindowsKeymap.Scancode(0x2C))              // z
        XCTAssertEqual(WindowsKeymap.scancode(for: 0x2F), WindowsKeymap.Scancode(0x35))              // /
        XCTAssertEqual(WindowsKeymap.scancode(for: 0x3F), WindowsKeymap.Scancode(0x35, shift: true)) // ?
        XCTAssertEqual(WindowsKeymap.scancode(for: 0x41), WindowsKeymap.Scancode(0x1E, shift: true)) // A
        XCTAssertEqual(WindowsKeymap.scancode(for: 0x7C), WindowsKeymap.Scancode(0x2B, shift: true)) // |
        XCTAssertEqual(WindowsKeymap.scancode(for: 0x20), WindowsKeymap.Scancode(0x39))              // space
    }

    func testPlainTextIsUnicode() {
        XCTAssertEqual(WindowsKeymap.strokes(for: 0x61, modifiers: []), [.unicode(0x61, down: true), .unicode(0x61, down: false)])
        XCTAssertEqual(WindowsKeymap.strokes(for: 0x41, modifiers: .shift), [.unicode(0x41, down: true), .unicode(0x41, down: false)])
        XCTAssertEqual(WindowsKeymap.strokes(for: 0x0100_00E9, modifiers: []), [.unicode(0xE9, down: true), .unicode(0xE9, down: false)])
    }

    /// Ctrl+Shift+C: modifiers down in order, the key, then up in reverse.
    func testChordsAreScancodes() {
        let c = WindowsKeymap.Scancode(0x2E)
        XCTAssertEqual(WindowsKeymap.strokes(for: 0x63, modifiers: [.control, .shift]), [
            .key(WindowsKeymap.control, down: true), .key(WindowsKeymap.shift, down: true),
            .key(c, down: true), .key(c, down: false),
            .key(WindowsKeymap.shift, down: false), .key(WindowsKeymap.control, down: false),
        ])
        // ⌘ is Control on a PC.
        XCTAssertEqual(WindowsKeymap.strokes(for: 0x76, modifiers: .command).first, .key(WindowsKeymap.control, down: true))
        // A shifted character under Control takes Shift too.
        XCTAssertTrue(WindowsKeymap.strokes(for: 0x3F, modifiers: .control).contains(.key(WindowsKeymap.shift, down: true)))
        // No US position: nothing at all, not even the modifiers.
        XCTAssertEqual(WindowsKeymap.strokes(for: 0x0100_00E9, modifiers: .control), [])
    }

    func testTextReturnAndTabAreKeys() {
        XCTAssertEqual(WindowsKeymap.strokes(forText: "a\n\t"), [
            .unicode(0x61, down: true), .unicode(0x61, down: false),
            .key(WindowsKeymap.returnKey, down: true), .key(WindowsKeymap.returnKey, down: false),
            .key(WindowsKeymap.tab, down: true), .key(WindowsKeymap.tab, down: false),
        ])
        // An emoji is two UTF-16 units.
        XCTAssertEqual(WindowsKeymap.strokes(forText: "😀").count, 4)
    }
}

final class RemoteDesktopEngineTests: XCTestCase {
    /// With the engine linked, its versions are the ones scripts/build-freerdp.sh pins.
    func testEngineVersionsMatchTheLock() throws {
        guard let versions = RemoteDesktop.engineVersions else { throw XCTSkip("Built without Vendor/FreeRDP/FreeRDP.xcframework") }
        XCTAssertTrue(versions.freeRDP.hasPrefix("3.33.1"), versions.freeRDP)
        XCTAssertTrue(versions.openSSL.contains("3.5.9"), versions.openSSL)
        XCTAssertTrue(versions.videoToolbox)
    }
}
