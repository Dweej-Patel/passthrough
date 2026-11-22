import Foundation
import LocalAuthentication
import Security
import PassthroughCore

/// The Windows login a PC's screen window signs in with, remembered when the
/// user chooses to: one per PC, in the data-protection Keychain, on this Mac
/// only, behind user presence. It is read with the context the window's own
/// Touch ID (or password) prompt already satisfied, so there is one prompt a
/// window and never a second one from the Keychain. Each is kept with the PC's
/// keys (`ShellCredential.loginPin`) and used only while they still match, so a
/// host that later claims the same id with its own keys is never sent it.
enum WindowsLoginStore {
    private static let service = "\(PassthroughProtocol.identifier).windows-login"

    private struct Stored: Codable { var username: String; var password: String; var pin: String? }

    private static func query(hostID: String) -> [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: hostID, kSecUseDataProtectionKeychain: true]
    }

    /// Nil when none is saved, it was saved for other keys than `pin`, or the context can't vouch for the user (no prompt is shown).
    static func read(hostID: String, pin: String, context: LAContext) -> ScreenLogin? {
        context.interactionNotAllowed = true
        defer { context.interactionNotAllowed = false }
        var q = query(hostID: hostID)
        q[kSecReturnData] = true
        q[kSecMatchLimit] = kSecMatchLimitOne
        q[kSecUseAuthenticationContext] = context
        var item: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data, let stored = try? JSONDecoder().decode(Stored.self, from: data) else {
            if status != errSecItemNotFound, status != errSecSuccess { ptLog(.info, "screen: the saved Windows login wasn't read (\(status))") }
            return nil
        }
        guard stored.pin == pin else {
            ptLog(.info, "screen: the saved Windows login was for other keys; not used")
            return nil
        }
        return ScreenLogin(username: stored.username, password: stored.password)
    }

    /// Replaces any saved login for that PC.
    @discardableResult
    static func save(_ login: ScreenLogin, hostID: String, pin: String, context: LAContext) -> Bool {
        var error: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, .userPresence, &error),
              let data = try? JSONEncoder().encode(Stored(username: login.username, password: login.password, pin: pin)) else { return false }
        SecItemDelete(query(hostID: hostID) as CFDictionary)
        context.interactionNotAllowed = true
        defer { context.interactionNotAllowed = false }
        var add = query(hostID: hostID)
        add[kSecAttrAccessControl] = access
        add[kSecValueData] = data
        add[kSecUseAuthenticationContext] = context
        let status = SecItemAdd(add as CFDictionary, nil)
        if status != errSecSuccess { ptLog(.error, "screen: the Windows login wasn't saved (\(status))") }
        return status == errSecSuccess
    }

    static func delete(hostID: String) {
        SecItemDelete(query(hostID: hostID) as CFDictionary)
    }

    /// Whether one is saved, without reading it (no prompt, no context needed).
    static func has(hostID: String) -> Bool {
        var q = query(hostID: hostID)
        q[kSecUseAuthenticationUI] = kSecUseAuthenticationUISkip
        let status = SecItemCopyMatching(q as CFDictionary, nil)
        return status == errSecSuccess || status == errSecInteractionNotAllowed
    }
}
