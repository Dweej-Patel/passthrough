import Foundation
import LocalAuthentication
import os
import Security
import PassthroughCore

/// The app's private home for remote-shell keys. The tunnel extension parks a
/// key a Mac granted over the cable in the shared store, sealed to the app's
/// `ShellSealingKey` (`PairingRegistry.grantShell`); after each unlock the app
/// opens it and moves it here: a
/// data-protection Keychain item with no access group (so the extension can't
/// read it), only on this device, only while a passcode is set, and only after
/// user presence. Reads reuse the app lock's evaluated `LAContext`, never
/// prompting a second time.
enum ShellKeyVault {
    enum Read {
        case key(Data)
        case missing
        /// The item exists but reading it would need a prompt: the context
        /// can't vouch for the user. The vault never prompts; the caller
        /// (`ShellModel`) asks `AppLock` to end the session so it prompts.
        case locked
    }

    private static let service = "\(PassthroughProtocol.identifier).shell"
    private static let log = Logger(subsystem: "app.passthrough", category: "ShellKeyVault")

    /// A Mac's keys live in versioned accounts, `shell.<macID>#<n>`, so a new
    /// key is added beside the old one and the old one is deleted only after
    /// the add succeeded. The bare `shell.<macID>` account of earlier builds is
    /// version 0: still read, and replaced by the next store.
    private static func account(_ macID: String, version: Int) -> String {
        version == 0 ? "shell." + macID : "shell.\(macID)#\(version)"
    }

    private static func parse(_ account: String) -> (macID: String, version: Int)? {
        guard account.hasPrefix("shell.") else { return nil }
        let rest = String(account.dropFirst("shell.".count))
        if let hash = rest.lastIndex(of: "#"), let n = Int(rest[rest.index(after: hash)...]), n > 0 {
            return (String(rest[..<hash]), n)
        }
        return (rest, 0)
    }

    /// Every stored account name. Nil when the listing itself failed (distinct
    /// from an empty vault). Listing user-presence items needs an evaluated
    /// context like reading them does (iOS refuses it with
    /// `errSecInteractionNotAllowed` otherwise), so callers pass the app lock's;
    /// without one this only works on a vault holding no such items.
    private static func accounts(context: LAContext?) -> [String]? {
        var query = baseQuery(account: nil)
        query[kSecReturnAttributes] = true
        query[kSecMatchLimit] = kSecMatchLimitAll
        let quiet = context ?? LAContext()
        quiet.interactionNotAllowed = true
        query[kSecUseAuthenticationContext] = quiet
        var items: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &items)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess, let list = items as? [[CFString: Any]] else { return nil }
        return list.compactMap { $0[kSecAttrAccount] as? String }
    }

    /// The stored versions of `macID`'s key, newest first; nil when they
    /// can't be listed.
    private static func versions(of macID: String, context: LAContext?) -> [Int]? {
        accounts(context: context)?.compactMap { name in parse(name).flatMap { $0.macID == macID ? $0.version : nil } }.sorted(by: >)
    }

    /// False only when the device has no passcode: the vault's items can't exist then.
    static var passcodeSet: Bool {
        var error: NSError?
        if LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) { return true }
        guard let error, error.domain == LAErrorDomain else { return true }
        return LAError.Code(rawValue: error.code) != .passcodeNotSet
    }

    /// Opens every key waiting sealed in the shared store (`ShellSealingKey`,
    /// with the lock's `context`), moves it into the vault and clears it
    /// there. Also makes sure the extension has the sealing key to seal the
    /// next grant with. A key that can't be opened or stored yet stays
    /// pending; one that can never be opened (an older build's bare key,
    /// sealed to a key since replaced, altered) is deleted, and the Mac
    /// grants again on its next cable connection. Returns how many moved.
    @discardableResult
    static func adoptPending(from registry: PairingRegistry, context: LAContext) -> Int {
        guard passcodeSet else { return 0 }
        let opener = ShellSealingKey.prepare(registry: registry, context: context)
        var moved = 0
        for client in registry.clients where client.shell != nil {
            guard let stored = registry.sealedPendingShellKey(clientID: client.id) else { continue }
            let adoption = opener?.adopt(stored, clientID: client.id) ?? (ShellKeySeal.format(of: stored) == .sealed ? .keep : .discard)
            // A newer grant may have landed meanwhile: leave that one for the next unlock.
            let clear = { if registry.sealedPendingShellKey(clientID: client.id) == stored { registry.clearPendingShellKey(clientID: client.id) } }
            switch adoption {
            case let .key(key):
                if store(key, macID: client.id, context: context) {
                    clear()
                    moved += 1
                }
            case .discard:
                log.info("Discarded a pending shell key this build can't open; the Mac grants again over the cable")
                clear()
            case .keep:
                break
            }
        }
        return moved
    }

    static func key(for macID: String, context: LAContext) -> Data? {
        if case let .key(data) = read(macID: macID, context: context) { return data }
        return nil
    }

    /// Reads without any UI: `interactionNotAllowed` makes the Keychain fail
    /// rather than prompt when `context` can't vouch for the user.
    static func read(macID: String, context: LAContext) -> Read {
        // The newest version present wins; an unreadable (locked) newest one is not skipped.
        guard let versions = versions(of: macID, context: context) else { return .locked }
        guard let newest = versions.first else { return .missing }
        context.interactionNotAllowed = true
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account(macID, version: newest),
            kSecUseDataProtectionKeychain: true,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
            kSecUseAuthenticationContext: context,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else { return .missing }
            return .key(data)
        case errSecItemNotFound:
            return .missing
        case errSecInteractionNotAllowed, errSecAuthFailed, errSecUserCanceled:
            return .locked
        default:
            log.error("Shell key read failed (\(status, privacy: .public))")
            return .missing
        }
    }

    /// `context` is the app lock's, so the keys can be listed.
    static func delete(macID: String, context: LAContext?) {
        // The bare (legacy) account always goes, whatever the listing says.
        delete(macID: macID, version: 0)
        guard let names = accounts(context: context) else {
            // The listing failed: forgetting must not silently do nothing, so
            // fail closed and clear every shell key (a Mac re-grants on its
            // next pairing) rather than leave this Mac's key behind.
            deleteAll()
            return
        }
        for name in names where parse(name)?.macID == macID {
            SecItemDelete(baseQuery(account: name) as CFDictionary)
        }
    }

    private static func delete(macID: String, version: Int) {
        SecItemDelete(baseQuery(account: account(macID, version: version)) as CFDictionary)
    }

    static func deleteAll() {
        SecItemDelete(baseQuery(account: nil) as CFDictionary)
    }

    /// Deletes the keys of Macs no longer paired (revoked while the app wasn't
    /// looking), listing with the lock's `context`. Skipped
    /// when `macIDs` is empty, so a failed registry read can't wipe the vault
    /// (forgetting every Mac uses `deleteAll`).
    static func prune(keeping macIDs: Set<String>, context: LAContext) {
        guard !macIDs.isEmpty else { return }
        for name in accounts(context: context) ?? [] {
            // An account this build doesn't recognise as a shell key is left alone.
            guard let parsed = parse(name), !macIDs.contains(parsed.macID) else { continue }
            SecItemDelete(baseQuery(account: name) as CFDictionary)
        }
    }

    // MARK: Private

    private static func baseQuery(account: String?) -> [CFString: Any] {
        var q: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecUseDataProtectionKeychain: true]
        if let account { q[kSecAttrAccount] = account }
        return q
    }

    /// Replaces any earlier key for `macID`. Updating an access-controlled item
    /// would need user presence, so the new key is added as the next version
    /// and the older ones are deleted only once it is stored: a failed add
    /// leaves the old key in place.
    private static func store(_ key: Data, macID: String, context: LAContext) -> Bool {
        var error: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly, .userPresence, &error) else {
            log.error("Shell key access control unavailable")
            return false
        }
        // Unlisted, a new version could collide with one already there.
        guard let older = versions(of: macID, context: context) else {
            log.error("Shell key not stored: the vault could not be listed")
            return false
        }
        context.interactionNotAllowed = true
        var add = baseQuery(account: account(macID, version: (older.first ?? 0) + 1))
        add[kSecAttrAccessControl] = access
        add[kSecValueData] = key
        add[kSecUseAuthenticationContext] = context
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else {
            log.error("Shell key not stored (\(status, privacy: .public))")
            return false
        }
        for version in older { delete(macID: macID, version: version) }
        return true
    }
}
