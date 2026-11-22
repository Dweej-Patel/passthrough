import Foundation
import Security
import CryptoKit
import PassthroughCore

/// This Mac's identity key as a computer that reaches others (stage 7): it
/// signs every shell proof this Mac makes with access a phone handed it, so
/// a copied credential opens nothing. A P-256 key in the data-protection
/// Keychain under `label`, made in the Secure Enclave, or, where that can't
/// be done (a VM, CI), a software key that can't be exported. It is never
/// the TLS key or the iroh key, and it asks for no Touch ID: it signs on
/// every reconnect (Touch ID guards the window, not the proof).
final class ComputerIdentity: ComputerIdentitySigning, @unchecked Sendable {
    static let label = "computer.identity"

    struct SigningFailed: Error {}

    private let key: SecKey
    /// The 65-byte uncompressed point, what hosts record (sent as `host.idKey`).
    let publicKey: Data
    /// Made in the Secure Enclave (else a software key).
    let inSecureEnclave: Bool

    private init(key: SecKey, publicKey: Data, inSecureEnclave: Bool) {
        self.key = key; self.publicKey = publicKey; self.inSecureEnclave = inSecureEnclave
    }

    /// `host.idKey`: the public key as lowercase hex.
    var publicKeyHex: String { publicKey.map { String(format: "%02x", $0) }.joined() }

    /// The stored key, or a new one stored first; nil when neither works (logged).
    static func loadOrCreate() -> ComputerIdentity? {
        if let found = load() { return found }
        if let made = create(secureEnclave: true) {
            ptLog(.info, "computers: made this Mac's identity key in the Secure Enclave")
            return made
        }
        if let made = create(secureEnclave: false) {
            ptLog(.warning, "computers: the Secure Enclave can't hold this Mac's identity key; made a software key")
            return made
        }
        ptLog(.error, "computers: could not make this Mac's identity key")
        return nil
    }

    func sign(_ message: Data) throws -> Data {
        var error: Unmanaged<CFError>?
        guard let der = SecKeyCreateSignature(key, .ecdsaSignatureMessageX962SHA256, message as CFData, &error) as Data? else {
            if let error { throw error.takeRetainedValue() as Error }
            throw SigningFailed()
        }
        return try P256.Signing.ECDSASignature(derRepresentation: der).rawRepresentation
    }

    private static func load() -> ComputerIdentity? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassKey, kSecAttrKeyClass: kSecAttrKeyClassPrivate, kSecAttrLabel: label,
            kSecUseDataProtectionKeychain: true, kSecReturnRef: true, kSecReturnAttributes: true,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let attributes = item as? [CFString: Any], let ref = attributes[kSecValueRef] else { return nil }
        let key = ref as! SecKey
        let token = attributes[kSecAttrTokenID] as? String
        return identity(for: key, inSecureEnclave: token == (kSecAttrTokenIDSecureEnclave as String))
    }

    private static func create(secureEnclave: Bool) -> ComputerIdentity? {
        var error: Unmanaged<CFError>?
        var privateAttributes: [CFString: Any] = [kSecAttrIsPermanent: true, kSecAttrLabel: label]
        if secureEnclave {
            guard let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly, .privateKeyUsage, &error) else {
                return nil
            }
            privateAttributes[kSecAttrAccessControl] = access
        } else {
            privateAttributes[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            privateAttributes[kSecAttrIsExtractable] = false
        }
        var attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits: 256,
            kSecUseDataProtectionKeychain: true,
            kSecPrivateKeyAttrs: privateAttributes,
        ]
        if secureEnclave { attributes[kSecAttrTokenID] = kSecAttrTokenIDSecureEnclave }
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            ptLog(.info, "computers: identity key not made \(secureEnclave ? "in the Secure Enclave" : "in software"): "
                  + (error?.takeRetainedValue().localizedDescription ?? "?"))
            return nil
        }
        return identity(for: key, inSecureEnclave: secureEnclave)
    }

    private static func identity(for key: SecKey, inSecureEnclave: Bool) -> ComputerIdentity? {
        var error: Unmanaged<CFError>?
        guard let publicKey = SecKeyCopyPublicKey(key),
              let point = SecKeyCopyExternalRepresentation(publicKey, &error) as Data?, ComputerProof.isPoint(point) else { return nil }
        return ComputerIdentity(key: key, publicKey: point, inSecureEnclave: inSecureEnclave)
    }
}
