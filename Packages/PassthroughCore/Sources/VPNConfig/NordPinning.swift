import Foundation
// CommonCrypto lives in libSystem, so the root helper (which links this
// target) loads no extra framework for a hash it never computes.
import CommonCrypto

/// Identity pinning for NordVPN's downloaded manual-setup profiles: the
/// profile must carry Nord's own CA and pin the very server that was asked
/// for, whatever the transport said.
public enum NordPinning {
    /// SHA-256 of the <ca> block Nord ships in every manual-setup profile
    /// ("NordVPN Root CA").
    public static let caSHA256 = "0f3e5da3a16471b1885bc1cfbc1965796e0c23b95c4af5beaa75bb4bab629a03"

    public enum Failure: Error, Equatable {
        case invalidProfile
        case missingCA
        case wrongCA
        case notPinned(String)
    }

    /// Checked on the parsed profile (what the helper hands openvpn), not the raw
    /// text, so a second <ca> or verify-x509-name can't slip past a substring match.
    public static func verify(profileText text: String, host: String, expectedCASHA256: String = caSHA256) throws {
        guard let profile = try? OpenVPNProfile(text: text) else { throw Failure.invalidProfile }
        guard let ca = profile.inlineCA else { throw Failure.missingCA }
        guard sha256Hex(ca.trimmingCharacters(in: .whitespacesAndNewlines)) == expectedCASHA256 else { throw Failure.wrongCA }
        guard profile.lines.contains("remote-cert-tls server"), profile.lines.contains("verify-x509-name CN=\(host)") else {
            throw Failure.notPinned(host)
        }
    }

    private static func sha256Hex(_ text: String) -> String {
        let data = Data(text.utf8)
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes { _ = CC_SHA256($0.baseAddress, CC_LONG(data.count), &digest) }
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
