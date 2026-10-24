import Foundation
import CryptoKit

/// How the Mac and a phone prove a pairing to each other (protocol version 2).
/// The token itself never goes on the wire after pairing: both sides prove
/// they know K = SHA-256(token), which is all the phone keeps, by an HMAC over
/// a fresh nonce from each side. The phone proves first, so a device that
/// merely answers on the phone's port learns nothing from the Mac. The SOCKS5
/// password is derived from K as well, so whoever squats the SOCKS port gets
/// nothing it could use on the control channel. Mirrors ControlAuth.kt.
public enum ControlAuth {
    public static let phoneLabel = "passthrough-control-v2 phone"
    public static let macLabel = "passthrough-control-v2 mac"
    public static let socksLabel = "passthrough-socks-v2"
    public static let nonceLength = 32

    /// K, from the token the Mac keeps.
    public static func key(token: String) -> SymmetricKey {
        SymmetricKey(data: SHA256.hash(data: Data(token.utf8)))
    }

    /// K, from the lowercase hex SHA-256 the phone keeps; nil if it isn't one.
    public static func key(tokenHash: String) -> SymmetricKey? {
        let hex = Array(tokenHash.utf8)
        guard hex.count == 64 else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(32)
        for i in stride(from: 0, to: 64, by: 2) {
            guard let hi = hexValue(hex[i]), let lo = hexValue(hex[i + 1]) else { return nil }
            bytes.append(hi << 4 | lo)
        }
        return SymmetricKey(data: bytes)
    }

    private static func hexValue(_ c: UInt8) -> UInt8? {
        switch c {
        case 0x30...0x39: return c - 0x30
        case 0x61...0x66: return c - 0x61 + 10
        case 0x41...0x46: return c - 0x41 + 10
        default: return nil
        }
    }

    public static func nonce() -> Data {
        var bytes = [UInt8](repeating: 0, count: nonceLength)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes)
    }

    /// A nonce from the wire: base64 of exactly `nonceLength` bytes, else nil.
    public static func decodeNonce(_ text: String?) -> Data? {
        guard let text, let data = Data(base64Encoded: text), data.count == nonceLength else { return nil }
        return data
    }

    /// The phone's proof, in `welcome`: HMAC(K, phoneLabel ‖ clientID ‖ macNonce ‖ phoneNonce).
    public static func phoneProof(key: SymmetricKey, clientID: String, macNonce: Data, phoneNonce: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: message(phoneLabel, clientID, macNonce, phoneNonce), using: key))
    }

    /// The Mac's proof, in `auth`: HMAC(K, macLabel ‖ clientID ‖ phoneNonce ‖ macNonce).
    public static func macProof(key: SymmetricKey, clientID: String, macNonce: Data, phoneNonce: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: message(macLabel, clientID, phoneNonce, macNonce), using: key))
    }

    /// Constant-time check of a phone's proof; false for anything not valid base64.
    public static func isValidPhoneProof(_ proof: String?, key: SymmetricKey, clientID: String, macNonce: Data, phoneNonce: Data) -> Bool {
        guard let proof, let code = Data(base64Encoded: proof) else { return false }
        return HMAC<SHA256>.isValidAuthenticationCode(code, authenticating: message(phoneLabel, clientID, macNonce, phoneNonce), using: key)
    }

    /// Constant-time check of the Mac's proof; false for anything not valid base64.
    public static func isValidMacProof(_ proof: String?, key: SymmetricKey, clientID: String, macNonce: Data, phoneNonce: Data) -> Bool {
        guard let proof, let code = Data(base64Encoded: proof) else { return false }
        return HMAC<SHA256>.isValidAuthenticationCode(code, authenticating: message(macLabel, clientID, phoneNonce, macNonce), using: key)
    }

    /// The SOCKS5 password, HMAC(K, socksLabel), as unpadded URL-safe base64:
    /// the same shape as a token, so it fits where the token used to go.
    public static func socksPassword(key: SymmetricKey) -> String {
        Data(HMAC<SHA256>.authenticationCode(for: Data(socksLabel.utf8), using: key)).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public static func socksPassword(token: String) -> String { socksPassword(key: key(token: token)) }

    /// The nonces have a fixed length and come last, so the variable-length
    /// client ID between the label and them can't be shifted into either.
    private static func message(_ label: String, _ clientID: String, _ first: Data, _ second: Data) -> Data {
        Data(label.utf8) + Data(clientID.utf8) + first + second
    }
}
