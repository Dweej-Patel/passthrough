import XCTest
import CryptoKit
@testable import PassthroughCore

/// A computer's proof (stage 7 a.1): the signed message, and what makes it fail.
final class ComputerProofTests: XCTestCase {
    private let nonce = Data(repeating: 7, count: 32)
    private let binding = Data(repeating: 0xAB, count: 32)
    private let id = "computer.0b1e2a3c-4d5e-4f60-8a71-92b3c4d5e6f7"

    func testTheMessageIsLabelPathNonceBindingAndID() {
        let message = ComputerProof.message(nonce: nonce, path: .iroh, hostBinding: binding, computerID: id)
        XCTAssertEqual(message, Data("passthrough-computer-v1".utf8) + [0x00, 0x02] + nonce + binding + Data(id.utf8))
    }

    func testASignatureHoldsForOneHostPathAndIDOnly() throws {
        let key = P256.Signing.PrivateKey()
        let point = key.publicKey.x963Representation
        XCTAssertTrue(ComputerProof.isPoint(point))
        let message = ComputerProof.message(nonce: nonce, path: .tls, hostBinding: binding, computerID: id)
        let sig = try key.signature(for: message).rawRepresentation
        XCTAssertEqual(sig.count, 64)
        XCTAssertTrue(ComputerProof.isValid(sig, publicKey: point, message: message))
        for altered in [
            ComputerProof.message(nonce: nonce, path: .iroh, hostBinding: binding, computerID: id),
            ComputerProof.message(nonce: nonce, path: .tls, hostBinding: Data(repeating: 0, count: 32), computerID: id),
            ComputerProof.message(nonce: nonce, path: .tls, hostBinding: binding, computerID: id + "0"),
        ] {
            XCTAssertFalse(ComputerProof.isValid(sig, publicKey: point, message: altered))
        }
        XCTAssertFalse(ComputerProof.isValid(sig, publicKey: P256.Signing.PrivateKey().publicKey.x963Representation, message: message))
        XCTAssertFalse(ComputerProof.isValid(sig.prefix(63), publicKey: point, message: message))
    }

    func testTheDecoyIsARealPoint() throws {
        XCTAssertTrue(ComputerProof.isPoint(ComputerProof.decoyKey))
        XCTAssertNoThrow(try P256.Signing.PublicKey(x963Representation: ComputerProof.decoyKey))
        XCTAssertFalse(ComputerProof.isValid(ComputerProof.decoySignature, publicKey: ComputerProof.decoyKey, message: Data("x".utf8)))
    }

    func testBindingsAreThirtyTwoBytesOfHex() {
        XCTAssertEqual(ComputerProof.binding(hex: String(repeating: "aB", count: 32)), Data(repeating: 0xAB, count: 32))
        XCTAssertNil(ComputerProof.binding(hex: String(repeating: "a", count: 62)))
        XCTAssertNil(ComputerProof.binding(hex: String(repeating: "g", count: 64)))
        let point = P256.Signing.PrivateKey().publicKey.x963Representation
        let hex = point.map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(ComputerProof.publicKey(hex: hex), point)
        // What `host.idKey` keeps after `cleaned()` is what a phone reads back.
        XCTAssertEqual(HostInfo(kind: HostInfo.kindMac, idKey: hex).cleaned()?.idKey, hex)
        XCTAssertNil(ComputerProof.publicKey(hex: String(hex.dropLast(2))))
    }

    func testIDsAndScopes() {
        XCTAssertTrue(Computers.isComputerID(Computers.newID()))
        XCTAssertFalse(Computers.isComputerID("viewer.abc"))
        XCTAssertEqual(Computers.validScopes(["screen", "shell"]), ["shell", "screen"])
        XCTAssertNil(Computers.validScopes([]))
        XCTAssertNil(Computers.validScopes(["shell", "files"]))
        let pass = ShellCredential(macID: "pc", macName: "Office-PC", certSHA256: String(repeating: "a", count: 64),
                                   shellKey: Data(repeating: 1, count: 32), phoneID: Computers.newID(), port: 7893, addresses: [])
        XCTAssertTrue(Computers.isUsable(pass))
        var viewer = pass
        viewer.phoneID = "viewer.abc"
        XCTAssertFalse(Computers.isUsable(viewer))
    }
}
