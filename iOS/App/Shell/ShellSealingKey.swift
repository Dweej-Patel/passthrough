import CryptoKit
import Foundation
import LocalAuthentication
import os
import Security
import PassthroughCore

/// The app's sealing key for shell keys waiting in the shared store
/// (`ShellKeySeal`). The tunnel extension seals each key a Mac grants to its
/// public half, which the app publishes in the App Group
/// (`PairingRegistry.publishShellSealingKey`); only the app can open them, and
/// only with the user present.
///
/// The private half is a Secure Enclave P-256 key whose use needs user
/// presence (`.privateKeyUsage` + `.userPresence`), only on this device and
/// only while a passcode is set; its handle (useless off this phone's Secure
/// Enclave) is a plain data-protection Keychain item. Without a Secure Enclave
/// (the simulator) it is a software key kept in a user-presence Keychain item,
/// like the shell keys themselves. Either way it is used with the app lock's
/// evaluated `LAContext`, so opening never prompts a second time.
enum ShellSealingKey {
    private static let service = "\(PassthroughProtocol.identifier).shell-sealing"
    private static let enclaveAccount = "secure-enclave"
    private static let softwareAccount = "software"
    private static let log = Logger(subsystem: "app.passthrough", category: "ShellSealingKey")

    /// Opens what the extension sealed: the key's public half and its key agreement.
    struct Opener {
        let publicKey: P256.KeyAgreement.PublicKey
        let agree: (P256.KeyAgreement.PublicKey) throws -> SharedSecret

        func adopt(_ stored: Data, clientID: String) -> ShellKeySeal.Adoption {
            ShellKeySeal.adopt(stored, clientID: clientID, recipient: publicKey, agree: agree)
        }
    }

    /// The sealing key, created on first use, with its public half published
    /// for the extension. Nil when there is none and none can be made (no
    /// passcode): the extension then keeps no shell keys at all.
    static func prepare(registry: PairingRegistry, context: LAContext) -> Opener? {
        context.interactionNotAllowed = true
        guard let opener = load(context: context) ?? create(context: context) else { return nil }
        if registry.shellSealingKey?.x963Representation != opener.publicKey.x963Representation {
            registry.publishShellSealingKey(opener.publicKey)
            log.info("Shell sealing key published")
        }
        return opener
    }

    // MARK: Private

    private static func load(context: LAContext) -> Opener? {
        if let handle = read(enclaveAccount, context: nil),
           let key = try? SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: handle, authenticationContext: context) {
            return Opener(publicKey: key.publicKey, agree: { try key.sharedSecretFromKeyAgreement(with: $0) })
        }
        if let raw = read(softwareAccount, context: context), let key = try? P256.KeyAgreement.PrivateKey(rawRepresentation: raw) {
            return Opener(publicKey: key.publicKey, agree: { try key.sharedSecretFromKeyAgreement(with: $0) })
        }
        return nil
    }

    private static func create(context: LAContext) -> Opener? {
        if SecureEnclave.isAvailable,
           let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly, [.privateKeyUsage, .userPresence], nil) {
            do {
                let key = try SecureEnclave.P256.KeyAgreement.PrivateKey(accessControl: access, authenticationContext: context)
                // The handle needs no protection of its own: only this Secure Enclave can use it, and only with the user.
                if write(key.dataRepresentation, account: enclaveAccount, access: nil, context: nil) {
                    return Opener(publicKey: key.publicKey, agree: { try key.sharedSecretFromKeyAgreement(with: $0) })
                }
            } catch {
                log.error("Secure Enclave sealing key unavailable: \(error.localizedDescription, privacy: .public)")
            }
        }
        guard let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly, .userPresence, nil) else { return nil }
        let key = P256.KeyAgreement.PrivateKey()
        guard write(key.rawRepresentation, account: softwareAccount, access: access, context: context) else { return nil }
        return Opener(publicKey: key.publicKey, agree: { try key.sharedSecretFromKeyAgreement(with: $0) })
    }

    private static func query(_ account: String) -> [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account, kSecUseDataProtectionKeychain: true]
    }

    private static func read(_ account: String, context: LAContext?) -> Data? {
        var q = query(account)
        q[kSecReturnData] = true
        q[kSecMatchLimit] = kSecMatchLimitOne
        if let context { q[kSecUseAuthenticationContext] = context }
        var item: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &item)
        if status != errSecSuccess, status != errSecItemNotFound { log.info("Sealing key not read (\(status, privacy: .public))") }
        return status == errSecSuccess ? item as? Data : nil
    }

    private static func write(_ data: Data, account: String, access: SecAccessControl?, context: LAContext?) -> Bool {
        SecItemDelete(query(account) as CFDictionary)
        var add = query(account)
        add[kSecValueData] = data
        if let access { add[kSecAttrAccessControl] = access } else { add[kSecAttrAccessible] = kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly }
        if let context { add[kSecUseAuthenticationContext] = context }
        let status = SecItemAdd(add as CFDictionary, nil)
        if status != errSecSuccess { log.error("Sealing key not stored (\(status, privacy: .public))") }
        return status == errSecSuccess
    }
}
