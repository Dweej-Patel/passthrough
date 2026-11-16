import XCTest
import Network
@testable import PassthroughCore
@testable import PhoneTransport
import TestSupport

/// QR pairing: the invitation the iPad shows, and the iPhone dialing the
/// iPad's pairing listener to hand over a token and link key.
@available(macOS 15, *)
final class IPadEnrollmentTests: XCTestCase {
    func testInvitationRoundTripsThroughItsURL() throws {
        let invitation = IPadEnrollment.Invitation(clientID: "ipad-1", name: "iPad Pro", certSHA256: String(repeating: "ab", count: 32))
        let parsed = try XCTUnwrap(IPadEnrollment.Invitation(url: invitation.url))
        XCTAssertEqual(parsed.clientID, "ipad-1")
        XCTAssertEqual(parsed.name, "iPad Pro")
        XCTAssertEqual(parsed.certSHA256, invitation.certSHA256)
        XCTAssertEqual(parsed.secret, invitation.secret)
        XCTAssertEqual(Int(parsed.expiry.timeIntervalSince1970), Int(invitation.expiry.timeIntervalSince1970))
    }

    func testMalformedInvitationsAreRejected() {
        XCTAssertNil(IPadEnrollment.Invitation(url: URL(string: "passthrough://pair-ipad?v=2&c=a&n=b&f=\(String(repeating: "a", count: 64))&s=AA&e=1")!))
        XCTAssertNil(IPadEnrollment.Invitation(url: URL(string: "passthrough://pair-ipad?v=1&c=a&n=b&f=zz&s=AA&e=1")!))
        XCTAssertNil(IPadEnrollment.Invitation(url: URL(string: "https://example.com/pair-ipad?v=1")!))
    }

    func testProofNeedsTheSecretAndTheNonce() {
        let secret = WirelessLink.randomBytes(32), nonce = WirelessLink.randomBytes(32)
        let proof = IPadEnrollment.proof(secret: secret, nonce: nonce)
        XCTAssertTrue(IPadEnrollment.proofIsValid(proof, secret: secret, nonce: nonce))
        XCTAssertFalse(IPadEnrollment.proofIsValid(proof, secret: WirelessLink.randomBytes(32), nonce: nonce))
        XCTAssertFalse(IPadEnrollment.proofIsValid(proof, secret: secret, nonce: WirelessLink.randomBytes(32)))
    }

    private func listen(_ invitation: IPadEnrollment.Invitation, identity: MacIdentity, kept: Locked<[UpstreamPhone]>) throws -> EnrollmentListener {
        let listener = EnrollmentListener(invitation: invitation, identity: identity)
        listener.onEnrolled = { phone in kept.set(kept.get() + [phone]); return true }
        let ready = expectation(description: "listening")
        try listener.start { _ in ready.fulfill() }
        wait(for: [ready], timeout: 5)
        return listener
    }

    private func enroll(_ invitation: IPadEnrollment.Invitation, token: String, linkKey: Data) -> Result<Void, IPadEnrollment.EnrollmentError> {
        let done = expectation(description: "enrolled")
        let outcome = Locked<Result<Void, IPadEnrollment.EnrollmentError>?>(nil)
        IPadEnrollment.enroll(invitation, phoneID: "phone-1", phoneName: "Test iPhone", token: token, linkKey: linkKey,
                              timeout: 10, queue: .global()) { result in outcome.set(result); done.fulfill() }
        wait(for: [done], timeout: 15)
        return outcome.get() ?? .failure(.notFound)
    }

    func testTheIPadKeepsWhatTheIPhoneIssued() throws {
        let identity = try makeTestIdentity()
        let invitation = IPadEnrollment.Invitation(clientID: "ipad-\(UUID().uuidString.prefix(6))", name: "iPad", certSHA256: identity.fingerprint)
        let kept = Locked<[UpstreamPhone]>([])
        let listener = try listen(invitation, identity: identity, kept: kept)
        defer { listener.stop() }
        let token = PairingToken.generate(), linkKey = WirelessLink.randomBytes(32)
        guard case .success = enroll(invitation, token: token, linkKey: linkKey) else { return XCTFail("enrollment failed") }
        XCTAssertEqual(kept.get().count, 1)
        XCTAssertEqual(kept.get().first?.token, token)
        XCTAssertEqual(kept.get().first?.linkKey, linkKey)
        XCTAssertEqual(kept.get().first?.phoneID, "phone-1")
        XCTAssertEqual(kept.get().first?.name, "Test iPhone")

        // The code works once.
        guard case .failure = enroll(invitation, token: PairingToken.generate(), linkKey: linkKey) else { return XCTFail("a used code paired again") }
        XCTAssertEqual(kept.get().count, 1)
    }

    func testAWrongSecretIsRefused() throws {
        let identity = try makeTestIdentity()
        let invitation = IPadEnrollment.Invitation(clientID: "ipad-\(UUID().uuidString.prefix(6))", name: "iPad", certSHA256: identity.fingerprint)
        let kept = Locked<[UpstreamPhone]>([])
        let listener = try listen(invitation, identity: identity, kept: kept)
        defer { listener.stop() }
        var forged = invitation
        forged.secret = WirelessLink.randomBytes(32)   // knows where the iPad is, not what the code says
        guard case .failure(.refused) = enroll(forged, token: PairingToken.generate(), linkKey: WirelessLink.randomBytes(32)) else {
            return XCTFail("a wrong secret paired")
        }
        XCTAssertTrue(kept.get().isEmpty)
    }
}
