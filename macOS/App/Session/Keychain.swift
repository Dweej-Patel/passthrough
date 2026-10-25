import Foundation
import Security
import PassthroughCore

/// Stores the per-Mac access token issued by the iPhone.
enum Keychain {
    private static let service = PassthroughProtocol.identifier

    /// Items live in the data-protection keychain, this device only, so they
    /// never ride a keychain export, iCloud sync or Migration Assistant. The
    /// legacy file keychain is never read: any process running as the user
    /// can add an item there, and one planted under our service and account
    /// (a pairing token, a shell key, an iroh secret) would be taken as ours.
    private static func base(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }

    static func read(_ account: String) -> String? {
        var query = base(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Returns false (and logs why) if the item could not be stored, so callers
    /// never claim "saved" for something that isn't.
    @discardableResult
    static func write(_ value: String, account: String) -> Bool {
        let data = Data(value.utf8)
        var status = SecItemUpdate(base(account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = base(account)
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(add as CFDictionary, nil)
        }
        if status != errSecSuccess {
            let why = SecCopyErrorMessageString(status, nil) as String? ?? "\(status)"
            ptLog(.error, "Keychain write for \(account.split(separator: ".").first ?? "item") failed: \(why)")
            return false
        }
        return true
    }

    static func delete(_ account: String) {
        SecItemDelete(base(account) as CFDictionary)
    }
}
