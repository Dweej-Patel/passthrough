import CryptoKit
import Foundation

/// The one Remote Desktop a view may sign in to: the one whose leaf
/// certificate hashes to what the host announced in `rdpReady.certSHA256`.
/// Checked before anything of the login leaves (NLA starts only after TLS);
/// there is no prompt and no way to continue past a mismatch.
public enum RDPCertificatePin {
    /// The leaf certificate's DER from a PEM chain (FreeRDP hands the chain leaf first).
    public static func leafDER(pem: Data) -> Data? {
        guard let text = String(data: pem, encoding: .utf8) else { return nil }
        let begin = "-----BEGIN CERTIFICATE-----", end = "-----END CERTIFICATE-----"
        guard let start = text.range(of: begin), let stop = text.range(of: end, range: start.upperBound..<text.endIndex) else {
            return nil
        }
        let body = text[start.upperBound..<stop.lowerBound].filter { !$0.isWhitespace }
        guard let der = Data(base64Encoded: String(body)), !der.isEmpty else { return nil }
        return der
    }

    /// SHA-256 of `der`, 64 lowercase hex.
    public static func hash(der: Data) -> String {
        SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
    }

    /// Whether the chain's leaf is the announced certificate. `expected` is 64
    /// lowercase hex; anything else never matches. Compared in constant time.
    public static func matches(pem: Data, sha256Hex expected: String) -> Bool {
        guard expected.utf8.count == 64, let der = leafDER(pem: pem) else { return false }
        let actual = Array(hash(der: der).utf8), wanted = Array(expected.utf8)
        var difference: UInt8 = 0
        for index in 0..<64 { difference |= actual[index] ^ wanted[index] }
        return difference == 0
    }
}
