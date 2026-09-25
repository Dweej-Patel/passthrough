import Foundation
import Security

/// Where the phone keeps secrets that must not sit in plain preferences (the
/// wireless link keys). The apps use the Keychain; tests use memory.
public protocol SecretStore: AnyObject, Sendable {
    func read(_ account: String) -> Data?
    /// False when the secret could not be stored.
    @discardableResult func write(_ data: Data, account: String) -> Bool
    func delete(_ account: String)
}

public final class InMemorySecrets: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: Data] = [:]
    public init() {}
    public func read(_ account: String) -> Data? { lock.lock(); defer { lock.unlock() }; return items[account] }
    public func write(_ data: Data, account: String) -> Bool { lock.lock(); items[account] = data; lock.unlock(); return true }
    public func delete(_ account: String) { lock.lock(); items[account] = nil; lock.unlock() }
}

/// Generic passwords readable after the first unlock (the tunnel extension
/// runs while the phone is locked), this device only, shared through
/// `accessGroup` (the App Group) between the app and the extension.
public final class KeychainSecrets: SecretStore, @unchecked Sendable {
    private let service = "dev.dpatel.passthrough.link"
    private let accessGroup: String?

    public init(accessGroup: String?) { self.accessGroup = accessGroup }

    private func query(_ account: String) -> [CFString: Any] {
        var q: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account]
        if let accessGroup { q[kSecAttrAccessGroup] = accessGroup }
        return q
    }

    public func read(_ account: String) -> Data? {
        var q = query(account)
        q[kSecReturnData] = true
        var item: CFTypeRef?
        return SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess ? item as? Data : nil
    }

    public func write(_ data: Data, account: String) -> Bool {
        let q = query(account)
        let update: [CFString: Any] = [kSecValueData: data, kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        var status = SecItemUpdate(q as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = q
            update.forEach { add[$0.key] = $0.value }
            status = SecItemAdd(add as CFDictionary, nil)
        }
        if status != errSecSuccess { ptLog(.error, "Could not store a link key (\(status))") }
        return status == errSecSuccess
    }

    public func delete(_ account: String) { SecItemDelete(query(account) as CFDictionary) }
}
