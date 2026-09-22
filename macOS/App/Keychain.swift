import Foundation
import Security

/// Stores the per-Mac access token issued by the iPhone.
enum Keychain {
    private static let service = "dev.dpatel.passthrough"

    /// Items live in the data-protection keychain, this device only, so they
    /// never ride a keychain export, iCloud sync or Migration Assistant.
    private static func base(_ account: String, modern: Bool = true) -> [String: Any] {
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if modern { q[kSecUseDataProtectionKeychain as String] = true }
        return q
    }

    static func read(_ account: String) -> String? {
        var query = base(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data {
            return String(data: data, encoding: .utf8)
        }
        // One-time migration from the legacy file keychain.
        var legacy = base(account, modern: false)
        legacy[kSecReturnData as String] = true
        legacy[kSecMatchLimit as String] = kSecMatchLimitOne
        guard SecItemCopyMatching(legacy as CFDictionary, &item) == errSecSuccess, let data = item as? Data,
              let value = String(data: data, encoding: .utf8) else { return nil }
        write(value, account: account)
        SecItemDelete(base(account, modern: false) as CFDictionary)
        return value
    }

    static func write(_ value: String, account: String) {
        let data = Data(value.utf8)
        let status = SecItemUpdate(base(account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = base(account)
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    static func delete(_ account: String) {
        SecItemDelete(base(account) as CFDictionary)
        SecItemDelete(base(account, modern: false) as CFDictionary)
    }
}
