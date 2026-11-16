#if os(macOS)
import Foundation
import PassthroughCore

/// The phones that asked this Mac for notices (`PushRegistration`), by
/// phone ID, kept in the Keychain: each one holds the key its notices are
/// sealed with. Revoking a phone's shell access removes it (the app does,
/// as it revokes: never by comparing with a list that may have failed to load).
public final class PushRegistry: @unchecked Sendable {
    private let secrets: SecretStore
    private let lock = NSLock()
    private var cached: [String: PushRegistration]?
    static let account = "push.registrations"

    public init(secrets: SecretStore) { self.secrets = secrets }

    public var all: [String: PushRegistration] {
        lock.lock(); defer { lock.unlock() }
        return load()
    }

    /// Sets (or with nil, removes) `phoneID`'s registration. False when it could not be stored.
    @discardableResult
    public func set(_ registration: PushRegistration?, for phoneID: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        var list = load()
        guard list[phoneID] != registration else { return true }
        list[phoneID] = registration
        guard let data = try? JSONEncoder().encode(list) else { return false }
        let stored = list.isEmpty ? { secrets.delete(Self.account); return true }() : secrets.write(data, account: Self.account)
        if stored { cached = list }
        return stored
    }

    public func remove(_ phoneID: String) { set(nil, for: phoneID) }

    private func load() -> [String: PushRegistration] {
        if let cached { return cached }
        let list = secrets.read(Self.account).flatMap { try? JSONDecoder().decode([String: PushRegistration].self, from: $0) } ?? [:]
        cached = list
        return list
    }
}
#endif
