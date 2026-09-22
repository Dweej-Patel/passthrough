import Foundation
import CryptoKit

/// A Mac that has been granted access to this iPhone's proxy.
public struct PairedClient: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var tokenHash: String
    public var pairedAt: Date
    public var lastSeen: Date?

    public init(id: String, name: String, tokenHash: String, pairedAt: Date, lastSeen: Date? = nil) {
        self.id = id; self.name = name; self.tokenHash = tokenHash; self.pairedAt = pairedAt; self.lastSeen = lastSeen
    }
}

/// Stores paired Macs and the short-lived pairing code. Backed by the App Group
/// defaults so the tunnel extension and the app share one view of the world.
public final class PairingRegistry: @unchecked Sendable {
    public static let clientsKey = "pairing.clients"
    public static let codeKey = "pairing.code"
    public static let codeExpiryKey = "pairing.codeExpiry"

    private let defaults: UserDefaults
    private let lock = NSLock()
    public var onChange: (@Sendable () -> Void)?

    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    public static func hash(token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    public static func makeToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
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
    }

    // MARK: Pairing code

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
        guard constantTimeEquals(stored, code.trimmingCharacters(in: .whitespaces)) else { return .failure(.badCode) }

        let token = Self.makeToken()
        lock.lock()
        var list = loadClients().filter { $0.id != clientID }
        list.append(PairedClient(id: clientID, name: name, tokenHash: Self.hash(token: token), pairedAt: Date(), lastSeen: Date()))
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
        return constantTimeEquals(client.tokenHash, Self.hash(token: token))
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
        save(loadClients().filter { $0.id != clientID })
    }

    public func revokeAll() {
        lock.lock(); defer { lock.unlock() }
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
