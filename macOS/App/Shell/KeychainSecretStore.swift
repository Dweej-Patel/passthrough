import Foundation
import PassthroughCore

/// `SecretStore` over the Mac app's `Keychain` (string items), keeping data as base64.
final class KeychainSecretStore: SecretStore, @unchecked Sendable {
    /// A stored item that is not base64 comes back as empty data, so a reader
    /// sees "stored but unreadable" (and refuses to overwrite it), not "nothing stored".
    func read(_ account: String) -> Data? {
        Keychain.read(account).map { Data(base64Encoded: $0) ?? Data() }
    }

    @discardableResult
    func write(_ data: Data, account: String) -> Bool {
        Keychain.write(data.base64EncodedString(), account: account)
    }

    func delete(_ account: String) { Keychain.delete(account) }
}
