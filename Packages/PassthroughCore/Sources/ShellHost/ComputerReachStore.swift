#if os(macOS)
import Foundation
import PassthroughCore

/// Access to another computer this Mac was handed by a phone (`computerPass`, stage 7 a.5).
public struct ReachableComputer: Codable, Equatable, Sendable, Identifiable {
    /// Where and how to reach it, and the `computer.` id and key to prove there (`hostKind` says what it is).
    public var credential: ShellCredential
    /// What this Mac may do there (`Computers.scopeShell`, `scopeScreen`), and what waits for its owner.
    public var scopes: [String]
    public var pending: [String]?
    /// The phone that handed it over, by its label here; nil for one paired directly.
    public var from: String?
    /// That phone's id here: revoking the phone forgets what it handed over.
    public var fromPhoneID: String?
    public var receivedAt: Date

    public init(credential: ShellCredential, scopes: [String], pending: [String]? = nil, from: String?, fromPhoneID: String?,
                receivedAt: Date) {
        self.credential = credential; self.scopes = scopes; self.pending = pending
        self.from = from; self.fromPhoneID = fromPhoneID; self.receivedAt = receivedAt
    }

    /// The other computer's host id: one entry per computer.
    public var id: String { credential.macID }
}

/// The computers this Mac can reach, in its secret store (item `computers.reach`), apart from the
/// screen passes. One per host id. A credential for a host already kept replaces it only when its
/// certificate and its iroh id are the same (both absent counts as the same): over iroh this Mac
/// knows a host by its id alone, so a swapped one would send the next sign-in to someone else.
/// Like `ScreenPassStore`, it never writes over a list it can't read, and removing fails closed.
public final class ComputerReachStore: @unchecked Sendable {
    public static let account = "computers.reach"
    /// Most computers kept; past this a new one is refused, never the oldest dropped.
    public static let maxComputers = 16

    public enum SaveResult: Equatable, Sendable {
        /// Kept, replacing `replaced` when there was one for that host.
        case saved(replaced: ReachableComputer?)
        /// One for that host is kept with a different certificate or iroh id: nothing changed.
        case conflict
        /// Not a credential this Mac can use.
        case notUsable
        /// Unreadable, full, or not written.
        case failed
    }

    private let secrets: SecretStore
    /// Guards the store and the sets below, so a save and a revoke never interleave.
    private let lock = NSLock()
    /// Removed, kept out even if the store couldn't be rewritten, until saved again.
    private var removedHosts: Set<String> = []
    /// Phones that lost access here: nothing they hand over is kept, until they're granted access again.
    private var revokedSenders: Set<String> = []

    public init(secrets: SecretStore) {
        self.secrets = secrets
    }

    /// Newest first. Empty when nothing is stored or it is unreadable.
    public var computers: [ReachableComputer] {
        lock.lock(); defer { lock.unlock() }
        return (load() ?? []).filter { !isDenied($0) }.sorted { $0.receivedAt > $1.receivedAt }
    }

    public func save(_ computer: ReachableComputer) -> SaveResult {
        guard Computers.isUsable(computer.credential), Computers.validScopes(computer.scopes + (computer.pending ?? [])) != nil else {
            return .notUsable
        }
        lock.lock(); defer { lock.unlock() }
        if let sender = computer.fromPhoneID, revokedSenders.contains(sender) { return .failed }
        guard let stored = load() else { return .failed }
        let kept = stored.first { $0.id == computer.id && !isDenied($0) }
        if let kept, kept.credential.certSHA256.lowercased() != computer.credential.certSHA256.lowercased()
            || kept.credential.irohID != computer.credential.irohID {
            return .conflict
        }
        var list = stored.filter { $0.id != computer.id && !isDenied($0) }
        list.append(computer)
        guard list.count <= Self.maxComputers, write(list) else { return .failed }
        removedHosts.remove(computer.id)
        return .saved(replaced: kept)
    }

    /// A phone was granted access here (again): what it hands over is kept once more.
    public func allowSender(_ phoneID: String) {
        lock.lock(); revokedSenders.remove(phoneID); lock.unlock()
    }

    /// Forgets the access to that host. False only if it may still be stored.
    @discardableResult
    public func remove(hostID: String) -> Bool {
        remove { $0.id == hostID }.done
    }

    /// Forgets everything these phones handed over (they lost access here). Returns the hosts that went.
    @discardableResult
    public func remove(fromPhones phoneIDs: Set<String>) -> (done: Bool, hostIDs: [String]) {
        remove(revokingSenders: phoneIDs) { $0.fromPhoneID.map(phoneIDs.contains) ?? false }
    }

    private func remove(revokingSenders senders: Set<String> = [],
                        where shouldRemove: (ReachableComputer) -> Bool) -> (done: Bool, hostIDs: [String]) {
        lock.lock(); defer { lock.unlock() }
        defer { revokedSenders.formUnion(senders) }
        guard let list = load() else {
            secrets.delete(Self.account)
            return (secrets.read(Self.account) == nil, [])
        }
        let gone = list.filter { !isDenied($0) && shouldRemove($0) }.map(\.id)
        guard !gone.isEmpty else { return (true, []) }
        removedHosts.formUnion(gone)
        if write(list.filter { !shouldRemove($0) && !isDenied($0) }) { return (true, gone) }
        ptLog(.error, "Could not update the computers this Mac can reach; removing them all")
        secrets.delete(Self.account)
        return (secrets.read(Self.account) == nil, gone)
    }

    /// Under `lock`.
    private func isDenied(_ computer: ReachableComputer) -> Bool {
        removedHosts.contains(computer.id) || (computer.fromPhoneID.map(revokedSenders.contains) ?? false)
    }

    private func load() -> [ReachableComputer]? {
        guard let data = secrets.read(Self.account) else { return [] }
        return try? JSONDecoder().decode([ReachableComputer].self, from: data)
    }

    private func write(_ list: [ReachableComputer]) -> Bool {
        if list.isEmpty {
            secrets.delete(Self.account)
            return secrets.read(Self.account) == nil
        }
        guard let data = try? JSONEncoder().encode(list) else { return false }
        return secrets.write(data, account: Self.account)
    }
}
#endif
