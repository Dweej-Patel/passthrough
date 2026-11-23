import Foundation
import LocalAuthentication
import os
import Security
import PassthroughCore
import ScreenClient

/// The logins a screen view signs in with, remembered when the user chooses
/// to: a Mac's account for Screen Sharing (one per Mac), and a PC's Windows
/// accounts for Remote Desktop (one per PC and account). Kept like the shell
/// keys (`ShellKeyVault`): a data-protection Keychain item only on this
/// device, only while a passcode is set, only after user presence, and read
/// with the app lock's context so it never prompts a second time.
enum ScreenLoginStore {
    private static let service = "\(PassthroughProtocol.identifier).screen-login"
    /// A PC's Windows accounts: account attribute `<host id>` U+001F `<account, trimmed and lowercased>`.
    private static let windowsService = "\(PassthroughProtocol.identifier).screen-login.windows"
    private static let log = Logger(subsystem: "app.passthrough", category: "ScreenLoginStore")

    /// `pin`: a Windows login's computer (`ShellCredential.loginPin`); one saved for other keys isn't used.
    private struct Stored: Codable { var username: String; var password: String; var pin: String? }

    private static func query(service: String, account: String) -> [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account, kSecUseDataProtectionKeychain: true]
    }

    private static func read(service: String, account: String, context: LAContext, pin: String? = nil) -> ScreenLogin? {
        context.interactionNotAllowed = true
        var q = query(service: service, account: account)
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
        if let pin, stored.pin != pin {
            log.info("A saved Windows login was for other keys; not used")
            return nil
        }
        return ScreenLogin(username: stored.username, password: stored.password)
    }

    private static func save(_ login: ScreenLogin, service: String, account: String, context: LAContext, pin: String? = nil) -> Bool {
        var error: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly, .userPresence, &error),
              let data = try? JSONEncoder().encode(Stored(username: login.username, password: login.password, pin: pin)) else { return false }
        SecItemDelete(query(service: service, account: account) as CFDictionary)
        context.interactionNotAllowed = true
        var add = query(service: service, account: account)
        add[kSecAttrAccessControl] = access
        add[kSecValueData] = data
        add[kSecUseAuthenticationContext] = context
        let status = SecItemAdd(add as CFDictionary, nil)
        if status != errSecSuccess { log.error("Screen login not saved (\(status, privacy: .public))") }
        return status == errSecSuccess
    }

    // MARK: A Mac's Screen Sharing

    /// Nil when none is saved or the context can't vouch for the user (no prompt is shown).
    static func read(macID: String, context: LAContext) -> ScreenLogin? {
        read(service: service, account: macID, context: context)
    }

    /// Replaces any saved login for `macID`.
    @discardableResult
    static func save(_ login: ScreenLogin, macID: String, context: LAContext) -> Bool {
        save(login, service: service, account: macID, context: context)
    }

    static func delete(macID: String) {
        SecItemDelete(query(service: service, account: macID) as CFDictionary)
    }

    // MARK: A PC's Windows accounts

    /// An account as the store keys it: trimmed, lowercased.
    static func accountKey(_ account: String) -> String { account.trimmingCharacters(in: .whitespaces).lowercased() }

    private static func windowsAccount(hostID: String, account: String) -> String { hostID + "\u{1F}" + accountKey(account) }
    /// Names only (not secret): which accounts have a login saved, and the last one used. A protected
    /// item can't be listed without a prompt, so this index says what is there.
    private static func accountsKey(_ hostID: String) -> String { "screenLoginAccounts.\(hostID)" }
    private static func lastKey(_ hostID: String) -> String { "screenLoginLast.\(hostID)" }

    /// The accounts with a login saved for this PC (as the store keys them).
    static func savedAccounts(hostID: String) -> [String] {
        UserDefaults.standard.stringArray(forKey: accountsKey(hostID)) ?? []
    }

    /// The account last signed in with on this PC, as typed.
    static func lastAccount(hostID: String) -> String? {
        UserDefaults.standard.string(forKey: lastKey(hostID))
    }

    static func setLastAccount(_ account: String, hostID: String) {
        UserDefaults.standard.set(account.trimmingCharacters(in: .whitespaces), forKey: lastKey(hostID))
    }

    /// Nil when none is saved for that account, it was saved for other keys than `pin` (the PC's credential now), or
    /// the context can't vouch for the user (no prompt is shown).
    static func readWindows(hostID: String, account: String, pin: String, context: LAContext) -> ScreenLogin? {
        guard savedAccounts(hostID: hostID).contains(accountKey(account)) else { return nil }
        return read(service: windowsService, account: windowsAccount(hostID: hostID, account: account), context: context, pin: pin)
    }

    /// Replaces any saved login for this PC and the login's account, kept with the PC's keys (`pin`).
    @discardableResult
    static func saveWindows(_ login: ScreenLogin, hostID: String, pin: String, context: LAContext) -> Bool {
        guard save(login, service: windowsService, account: windowsAccount(hostID: hostID, account: login.username), context: context,
                   pin: pin) else {
            return false
        }
        var accounts = savedAccounts(hostID: hostID)
        let key = accountKey(login.username)
        if !accounts.contains(key) { accounts.append(key) }
        UserDefaults.standard.set(accounts, forKey: accountsKey(hostID))
        return true
    }

    static func deleteWindows(hostID: String, account: String) {
        SecItemDelete(query(service: windowsService, account: windowsAccount(hostID: hostID, account: account)) as CFDictionary)
        let key = accountKey(account)
        let accounts = savedAccounts(hostID: hostID).filter { $0 != key }
        UserDefaults.standard.set(accounts, forKey: accountsKey(hostID))
    }

    /// Every login saved for this computer: it was forgotten, or its access was revoked.
    static func deleteAll(hostID: String) {
        delete(macID: hostID)
        for account in savedAccounts(hostID: hostID) {
            SecItemDelete(query(service: windowsService, account: hostID + "\u{1F}" + account) as CFDictionary)
        }
        UserDefaults.standard.removeObject(forKey: accountsKey(hostID))
        UserDefaults.standard.removeObject(forKey: lastKey(hostID))
    }
}
