import Foundation
import CryptoKit

/// Identity pinning for NordVPN's downloaded manual-setup profiles: the
/// profile must carry Nord's own CA and pin the very server that was asked
/// for, whatever the transport said.
public enum NordPinning {
    /// SHA-256 of the <ca> block Nord ships in every manual-setup profile
    /// ("NordVPN Root CA").
    public static let caSHA256 = "0f3e5da3a16471b1885bc1cfbc1965796e0c23b95c4af5beaa75bb4bab629a03"

    public enum Failure: Error, Equatable {
        case missingCA
        case wrongCA
        case notPinned(String)
    }

    public static func verify(profileText text: String, host: String, expectedCASHA256: String = caSHA256) throws {
        guard let caStart = text.range(of: "<ca>\n"), let caEnd = text.range(of: "</ca>", range: caStart.upperBound..<text.endIndex) else {
            throw Failure.missingCA
        }
        let ca = String(text[caStart.upperBound..<caEnd.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard sha256Hex(ca) == expectedCASHA256 else { throw Failure.wrongCA }
        guard text.contains("remote-cert-tls server"), text.contains("verify-x509-name CN=\(host)") else {
            throw Failure.notPinned(host)
        }
    }

    private static func sha256Hex(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
