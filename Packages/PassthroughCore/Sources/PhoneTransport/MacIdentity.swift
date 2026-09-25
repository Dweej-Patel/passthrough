import Foundation
import Security
import CryptoKit

/// The Mac's TLS identity for the wireless link: a P-256 key in the Keychain
/// and a self-signed certificate for it. Phones pin the certificate's SHA-256,
/// learned over the cable, so no CA is involved; the certificate only has to
/// be well-formed. Apple's frameworks can't create certificates, hence the
/// small DER writer below.
public struct MacIdentity {
    public let identity: SecIdentity
    /// The certificate's DER bytes.
    public let certificate: Data

    /// Lowercase hex SHA-256 of the certificate, what phones pin.
    public var fingerprint: String { Self.fingerprint(of: certificate) }

    public static func fingerprint(of certificate: Data) -> String {
        SHA256.hash(data: certificate).map { String(format: "%02x", $0) }.joined()
    }

    public enum IdentityError: LocalizedError {
        case keychain(OSStatus, String)
        public var errorDescription: String? {
            switch self { case .keychain(let status, let step): return "Keychain \(step) failed (\(status))" }
        }
    }

    /// The identity stored under `label`, created on first use. The app uses
    /// the data-protection keychain; tests use the login keychain.
    public static func loadOrCreate(label: String, dataProtection: Bool = true) throws -> MacIdentity {
        if let existing = try? load(label: label, dataProtection: dataProtection) { return existing }
        delete(label: label, dataProtection: dataProtection)
        return try create(label: label, dataProtection: dataProtection)
    }

    public static func delete(label: String, dataProtection: Bool = true) {
        for cls in [kSecClassKey, kSecClassCertificate] {
            var query: [CFString: Any] = [kSecClass: cls, kSecAttrLabel: label]
            if dataProtection { query[kSecUseDataProtectionKeychain] = true }
            SecItemDelete(query as CFDictionary)
        }
    }

    private static func load(label: String, dataProtection: Bool) throws -> MacIdentity {
        var query: [CFString: Any] = [kSecClass: kSecClassIdentity, kSecAttrLabel: label, kSecReturnRef: true]
        if dataProtection { query[kSecUseDataProtectionKeychain] = true }
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let item else { throw IdentityError.keychain(status, "lookup") }
        let identity = item as! SecIdentity
        var cert: SecCertificate?
        let copied = SecIdentityCopyCertificate(identity, &cert)
        guard copied == errSecSuccess, let cert else { throw IdentityError.keychain(copied, "certificate") }
        return MacIdentity(identity: identity, certificate: SecCertificateCopyData(cert) as Data)
    }

    private static func create(label: String, dataProtection: Bool) throws -> MacIdentity {
        var keyAttributes: [CFString: Any] = [kSecAttrIsPermanent: true, kSecAttrLabel: label]
        if dataProtection { keyAttributes[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly }
        var attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits: 256,
            kSecPrivateKeyAttrs: keyAttributes,
        ]
        if dataProtection { attributes[kSecUseDataProtectionKeychain] = true }
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error),
              let publicKey = SecKeyCopyPublicKey(key),
              let point = SecKeyCopyExternalRepresentation(publicKey, &error) as Data? else {
            throw IdentityError.keychain(errSecParam, "key creation: \(error?.takeRetainedValue().localizedDescription ?? "?")")
        }
        let tbs = CertificateDER.tbs(publicKeyPoint: point, commonName: "Passthrough Mac")
        guard let signature = SecKeyCreateSignature(key, .ecdsaSignatureMessageX962SHA256, tbs as CFData, &error) as Data? else {
            throw IdentityError.keychain(errSecParam, "signing")
        }
        let der = CertificateDER.certificate(tbs: tbs, signature: signature)
        guard let cert = SecCertificateCreateWithData(nil, der as CFData) else {
            throw IdentityError.keychain(errSecDecode, "certificate parse")
        }
        var add: [CFString: Any] = [kSecClass: kSecClassCertificate, kSecValueRef: cert, kSecAttrLabel: label]
        if dataProtection { add[kSecUseDataProtectionKeychain] = true }
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess || status == errSecDuplicateItem else { throw IdentityError.keychain(status, "certificate add") }
        return try load(label: label, dataProtection: dataProtection)
    }
}

/// Just enough DER to write a self-signed X.509 v3 certificate for a P-256 key.
enum CertificateDER {
    static func tbs(publicKeyPoint: Data, commonName: String, now: Date = Date()) -> Data {
        var serial = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, serial.count, &serial)
        serial[0] &= 0x7F                     // positive
        serial[0] |= 0x40                     // no leading zero byte needed
        let name = sequence(set(sequence(oid([2, 5, 4, 3]) + tlv(0x0C, Data(commonName.utf8)))))
        let validity = sequence(time(now.addingTimeInterval(-86_400)) + time(now.addingTimeInterval(20 * 365 * 86_400)))
        let spki = sequence(sequence(oid([1, 2, 840, 10045, 2, 1]) + oid([1, 2, 840, 10045, 3, 1, 7])) + bitString(publicKeyPoint))
        return sequence(
            tlv(0xA0, tlv(0x02, Data([2])))   // [0] version v3
            + tlv(0x02, Data(serial))
            + ecdsaWithSHA256
            + name + validity + name + spki
        )
    }

    static func certificate(tbs: Data, signature: Data) -> Data {
        sequence(tbs + ecdsaWithSHA256 + bitString(signature))
    }

    static let ecdsaWithSHA256 = sequence(oid([1, 2, 840, 10045, 4, 3, 2]))

    static func tlv(_ tag: UInt8, _ content: Data) -> Data {
        var out = Data([tag])
        if content.count < 0x80 {
            out.append(UInt8(content.count))
        } else {
            var length = content.count, bytes: [UInt8] = []
            while length > 0 { bytes.insert(UInt8(length & 0xFF), at: 0); length >>= 8 }
            out.append(0x80 | UInt8(bytes.count)); out.append(contentsOf: bytes)
        }
        return out + content
    }

    static func sequence(_ content: Data) -> Data { tlv(0x30, content) }
    static func set(_ content: Data) -> Data { tlv(0x31, content) }
    static func bitString(_ bytes: Data) -> Data { tlv(0x03, Data([0]) + bytes) }

    static func oid(_ arcs: [UInt]) -> Data {
        var body = Data([UInt8(arcs[0] * 40 + arcs[1])])
        for arc in arcs.dropFirst(2) {
            var chunk = [UInt8(arc & 0x7F)], rest = arc >> 7
            while rest > 0 { chunk.insert(UInt8(rest & 0x7F) | 0x80, at: 0); rest >>= 7 }
            body.append(contentsOf: chunk)
        }
        return tlv(0x06, body)
    }

    /// UTCTime "YYMMDDHHMMSSZ" (valid through 2049).
    static func time(_ date: Date) -> Data {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyMMddHHmmss'Z'"
        return tlv(0x17, Data(f.string(from: date).utf8))
    }
}
