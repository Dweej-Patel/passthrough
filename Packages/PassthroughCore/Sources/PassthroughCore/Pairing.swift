import Foundation
import notify
import CryptoKit

/// The secret a phone issues each Mac it pairs with: 32 random bytes as
/// unpadded URL-safe base64. The phone keeps only its SHA-256.
public enum PairingToken {
    public static let length = 43

    public static func generate() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Lowercase hex SHA-256, the form the phone stores.
    public static func hash(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Whether `token` has the shape `generate()` produces; anything else was not issued by a phone.
    public static func isWellFormed(_ token: String) -> Bool {
        token.count == length && token.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }
}

/// A Mac that has been granted access to this iPhone's proxy.
public struct PairedClient: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var tokenHash: String
    public var pairedAt: Date
    public var lastSeen: Date?
    /// SHA-256 of the Mac's wireless-link certificate, once linked over the cable.
    public var linkCertificate: String?

    public init(id: String, name: String, tokenHash: String, pairedAt: Date, lastSeen: Date? = nil) {
        self.id = id; self.name = name; self.tokenHash = tokenHash; self.pairedAt = pairedAt; self.lastSeen = lastSeen
    }
}

/// Stores paired Macs and the short-lived pairing code. Backed by the App Group
/// defaults so the tunnel extension and the app share one view of the world.
public final class PairingRegistry: @unchecked Sendable {
    public static let clientsKey = "pairing.clients"
    /// Posted (a Darwin notification, so across processes) whenever the list
    /// of paired or linked Macs changes: the app forgets a Mac while the
    /// tunnel extension's wireless link is running.
    public static let changedNotification = "dev.dpatel.passthrough.pairings-changed"
    public static let codeKey = "pairing.code"
    public static let codeExpiryKey = "pairing.codeExpiry"
    /// Wrong guesses against the current code. Kept with the code in the shared
    /// defaults, since the iOS app issues codes and the extension checks them.
    public static let failedAttemptsKey = "pairing.failedAttempts"

    public static let phoneIDKey = "pairing.phoneID"

    private let defaults: UserDefaults
    private let secrets: SecretStore
    private let lock = NSLock()
    public var onChange: (@Sendable () -> Void)?

    /// `secrets` holds the wireless link keys: the apps pass `KeychainSecrets`.
    public init(defaults: UserDefaults, secrets: SecretStore = InMemorySecrets()) {
        self.defaults = defaults
        self.secrets = secrets
    }

    // MARK: Wireless link

    /// This phone's identity towards linked Macs: random, created once.
    public var phoneID: String {
        lock.lock(); defer { lock.unlock() }
        if let id = defaults.string(forKey: Self.phoneIDKey) { return id }
        let id = UUID().uuidString
        defaults.set(id, forKey: Self.phoneIDKey)
        return id
    }

    /// Records what a paired Mac sent over the cable to link wirelessly.
    /// False if the Mac isn't paired or its key could not be stored; the
    /// Mac is then not linked.
    @discardableResult
    public func link(clientID: String, certificateSHA256: String, linkKey: Data) -> Bool {
        lock.lock()
        var list = loadClients()
        guard let i = list.firstIndex(where: { $0.id == clientID }),
              secrets.write(linkKey, account: "link." + clientID) else { lock.unlock(); return false }
        list[i].linkCertificate = certificateSHA256
        save(list)
        lock.unlock()
        return true
    }

    /// Everything the wireless dialer needs, for every linked Mac.
    public func linkCredentials() -> [LinkCredential] {
        let id = phoneID
        return clients.compactMap { client in
            guard let cert = client.linkCertificate, let key = secrets.read("link." + client.id) else { return nil }
            return LinkCredential(macTag: WirelessLink.macTag(clientID: client.id), certSHA256: cert, linkKey: key, phoneID: id)
        }
    }

    public var clients: [PairedClient] {
        lock.lock(); defer { lock.unlock() }
        return loadClients()
    }

    private func loadClients() -> [PairedClient] {
        guard let data = defaults.data(forKey: Self.clientsKey) else { return [] }
        return (try? JSONDecoder().decode([PairedClient].self, from: data)) ?? []
    }

    private func save(_ clients: [PairedClient]) {
        defaults.set(try? JSONEncoder().encode(clients), forKey: Self.clientsKey)
        onChange?()
        notify_post(Self.changedNotification)
    }

    // MARK: Pairing code

    private static let maxAttempts = 5

    /// Generates a fresh six digit code, valid for `PassthroughProtocol.pairingCodeLifetime`.
    @discardableResult
    public func issueCode() -> (code: String, expiry: Date) {
        var value: UInt32 = 0
        _ = withUnsafeMutableBytes(of: &value) { SecRandomCopyBytes(kSecRandomDefault, 4, $0.baseAddress!) }
        let code = String(format: "%06d", value % 1_000_000)
        let expiry = Date().addingTimeInterval(PassthroughProtocol.pairingCodeLifetime)
        lock.lock()
        defaults.set(code, forKey: Self.codeKey)
        defaults.set(expiry.timeIntervalSince1970, forKey: Self.codeExpiryKey)
        defaults.set(0, forKey: Self.failedAttemptsKey)
        lock.unlock()
        onChange?()
        return (code, expiry)
    }

    public func clearCode() {
        lock.lock()
        defaults.removeObject(forKey: Self.codeKey)
        defaults.removeObject(forKey: Self.codeExpiryKey)
        lock.unlock()
        onChange?()
    }

    public var activeCode: (code: String, expiry: Date)? {
        lock.lock(); defer { lock.unlock() }
        guard let code = defaults.string(forKey: Self.codeKey) else { return nil }
        let expiry = Date(timeIntervalSince1970: defaults.double(forKey: Self.codeExpiryKey))
        guard expiry > Date() else { return nil }
        return (code, expiry)
    }

    /// Validates a code and registers the Mac; returns the token to hand back.
    public func pair(code: String, clientID: String, name: String) -> Result<String, PairingFailure> {
        lock.lock()
        let stored = defaults.string(forKey: Self.codeKey)
        let expiry = Date(timeIntervalSince1970: defaults.double(forKey: Self.codeExpiryKey))
        lock.unlock()
        guard let stored else { return .failure(.expired) }
        guard expiry > Date() else { clearCode(); return .failure(.expired) }
        guard constantTimeEquals(stored, code.trimmingCharacters(in: .whitespaces)) else {
            // A six-digit code must not be brute-forceable over the cable: a
            // handful of wrong guesses burns the code; the user shows a new one.
            lock.lock()
            let n = defaults.integer(forKey: Self.failedAttemptsKey) + 1
            defaults.set(n, forKey: Self.failedAttemptsKey)
            lock.unlock()
            if n >= Self.maxAttempts {
                ptLog(.warning, "Pairing code withdrawn after \(n) wrong attempts")
                clearCode()
                return .failure(.expired)
            }
            return .failure(.badCode)
        }
        guard clientID.count <= 64, name.count <= 64 else { return .failure(.badCode) }

        let token = PairingToken.generate()
        lock.lock()
        var list = loadClients().filter { $0.id != clientID }
        list.append(PairedClient(id: clientID, name: name, tokenHash: PairingToken.hash(token), pairedAt: Date(), lastSeen: Date()))
        save(list)
        defaults.removeObject(forKey: Self.codeKey)
        defaults.removeObject(forKey: Self.codeExpiryKey)
        lock.unlock()
        onChange?()
        ptLog(.info, "Paired Mac \(name)")
        return .success(token)
    }

    public func verify(clientID: String, token: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let client = loadClients().first(where: { $0.id == clientID }) else { return false }
        return constantTimeEquals(client.tokenHash, PairingToken.hash(token))
    }

    public func touch(clientID: String) {
        lock.lock(); defer { lock.unlock() }
        var list = loadClients()
        guard let i = list.firstIndex(where: { $0.id == clientID }) else { return }
        list[i].lastSeen = Date()
        save(list)
    }

    public func revoke(clientID: String) {
        lock.lock(); defer { lock.unlock() }
        secrets.delete("link." + clientID)
        save(loadClients().filter { $0.id != clientID })
    }

    public func revokeAll() {
        lock.lock(); defer { lock.unlock() }
        loadClients().forEach { secrets.delete("link." + $0.id) }
        save([])
    }

    private func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<x.count { diff |= x[i] ^ y[i] }
        return diff == 0
    }
}
