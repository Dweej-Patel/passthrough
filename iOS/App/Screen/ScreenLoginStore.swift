import Foundation
import LocalAuthentication
import os
import Security
import PassthroughCore
import ScreenClient

/// The Mac account name and password Screen Sharing asks for, remembered per
/// Mac when the user chooses to: kept like the shell keys
/// (`ShellKeyVault`), a data-protection Keychain item only on this device,
/// only while a passcode is set, only after user presence, and read with the
/// app lock's context so it never prompts a second time.
enum ScreenLoginStore {
    private static let service = "\(PassthroughProtocol.identifier).screen-login"
    private static let log = Logger(subsystem: "app.passthrough", category: "ScreenLoginStore")

    private struct Stored: Codable { var username: String; var password: String }

    private static func query(_ macID: String) -> [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: macID, kSecUseDataProtectionKeychain: true]
    }

    /// Nil when none is saved or the context can't vouch for the user (no prompt is shown).
    static func read(macID: String, context: LAContext) -> RFBClient.Login? {
        context.interactionNotAllowed = true
        var q = query(macID)
        q[kSecReturnData] = true
        q[kSecMatchLimit] = kSecMatchLimitOne
        q[kSecUseAuthenticationContext] = context
        var item: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data,
              let stored = try? JSONDecoder().decode(Stored.self, from: data) else {
            if status != errSecItemNotFound && status != errSecSuccess { log.info("Screen login not read (\(status, privacy: .public))") }
            return nil
        }
        return RFBClient.Login(username: stored.username, password: stored.password)
    }

    /// Replaces any saved login for `macID`.
    @discardableResult
    static func save(_ login: RFBClient.Login, macID: String, context: LAContext) -> Bool {
        var error: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly, .userPresence, &error),
              let data = try? JSONEncoder().encode(Stored(username: login.username, password: login.password)) else { return false }
        delete(macID: macID)
        context.interactionNotAllowed = true
        var add = query(macID)
        add[kSecAttrAccessControl] = access
        add[kSecValueData] = data
        add[kSecUseAuthenticationContext] = context
        let status = SecItemAdd(add as CFDictionary, nil)
        if status != errSecSuccess { log.error("Screen login not saved (\(status, privacy: .public))") }
        return status == errSecSuccess
    }

    static func delete(macID: String) {
        SecItemDelete(query(macID) as CFDictionary)
    }
}

/// "Copy the Mac's clipboard to this iPhone", per Mac, for Screen Sharing.
/// Off unless the user turns it on: the Mac's clipboard (passwords from its
/// password manager included) would otherwise land on this iPhone's for any
/// app to read. The phone's clipboard still goes to the Mac on Paste.
enum ScreenClipboardSetting {
    private static let prefix = "screen.copyMacClipboard."

    static func isOn(macID: String) -> Bool { UserDefaults.standard.bool(forKey: prefix + macID) }

    static func set(_ on: Bool, macID: String) {
        if on { UserDefaults.standard.set(true, forKey: prefix + macID) } else { UserDefaults.standard.removeObject(forKey: prefix + macID) }
    }
}
