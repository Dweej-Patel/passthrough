#if os(macOS)
import Foundation
import PassthroughCore

/// A pass to another Mac's screen this Mac was handed by a phone (`ScreenPass`).
public struct ReceivedScreenPass: Codable, Equatable, Sendable, Identifiable {
    /// Where and how to reach that Mac, and the viewer id and key to prove there.
    public var credential: ShellCredential
    /// The phone that handed it over, by its label here.
    public var from: String
    /// That phone's id here: revoking the phone forgets what it handed over.
    /// Absent only in passes stored before it was kept.
    public var fromPhoneID: String?
    public var receivedAt: Date

    public init(credential: ShellCredential, from: String, fromPhoneID: String? = nil, receivedAt: Date) {
        self.credential = credential; self.from = from; self.fromPhoneID = fromPhoneID; self.receivedAt = receivedAt
    }

    /// The other Mac's id as the phone knows it: one pass per Mac.
    public var id: String { credential.macID }
    public var macName: String { credential.macName }
}

/// The passes this Mac holds to other Macs' screens, in its secret store.
/// One per Mac: a newer pass for the same Mac replaces the older. Like
/// `ShellAccessStore`, it never writes over a stored list it can't read.
public final class ScreenPassStore: @unchecked Sendable {
    public static let account = "screenPasses"
    /// Most passes kept; the oldest goes past this.
    public static let maxPasses = 16

    private let secrets: SecretStore
    /// Guards the store and the two sets below, so a save and a revoke never interleave.
    private let lock = NSLock()
    /// Passes removed, kept out even if the store couldn't be rewritten, until a new pass for that Mac is saved.
    private var removedMacs: Set<String> = []
    /// Phones that lost access here: nothing they hand over is kept, until they're granted access again.
    private var revokedSenders: Set<String> = []

    public init(secrets: SecretStore) {
        self.secrets = secrets
    }

    /// Newest first. Empty when nothing is stored or it is unreadable.
    public var passes: [ReceivedScreenPass] {
        lock.lock(); defer { lock.unlock() }
        return (load() ?? []).filter { !isDenied($0) }.sorted { $0.receivedAt > $1.receivedAt }
    }

    public func pass(for macID: String) -> ReceivedScreenPass? {
        passes.first { $0.id == macID }
    }

    /// Keeps `pass`, replacing any for the same Mac. False if it isn't usable,
    /// what's stored is unreadable, or it couldn't be stored. Returns the pass
    /// it replaced, if any.
    @discardableResult
    public func save(_ pass: ReceivedScreenPass) -> (saved: Bool, replaced: ReceivedScreenPass?) {
        guard ScreenPass.isUsable(pass.credential) else { return (false, nil) }
        lock.lock(); defer { lock.unlock() }
        // Checked under the same lock a revoke takes: a phone revoked meanwhile hands over nothing.
        if let sender = pass.fromPhoneID, revokedSenders.contains(sender) { return (false, nil) }
        guard let stored = load() else { return (false, nil) }
        let replaced = stored.first { $0.id == pass.id }
        var list = stored.filter { $0.id != pass.id }
        list.append(pass)
        if list.count > Self.maxPasses {
            list = Array(list.sorted { $0.receivedAt > $1.receivedAt }.prefix(Self.maxPasses))
        }
        guard write(list) else { return (false, nil) }
        removedMacs.remove(pass.id)
        return (true, replaced.flatMap { isDenied($0) ? nil : $0 })
    }

    /// A phone was granted access here (again): what it hands over is kept once more.
    public func allowSender(_ phoneID: String) {
        lock.lock(); revokedSenders.remove(phoneID); lock.unlock()
    }

    /// Forgets the pass to that Mac. False only if it may still be stored.
    @discardableResult
    public func remove(macID: String) -> Bool {
        remove { $0.id == macID }.done
    }

    /// Forgets every pass these phones handed over (they lost access here).
    /// Returns the Macs whose passes went.
    @discardableResult
    public func remove(fromPhones phoneIDs: Set<String>) -> (done: Bool, macIDs: [String]) {
        remove(revokingSenders: phoneIDs) { $0.fromPhoneID.map(phoneIDs.contains) ?? false }
    }

    /// Removes the matching passes; `revokingSenders` are refused from now on,
    /// in the same critical section, so no save from them lands after this.
    private func remove(revokingSenders senders: Set<String> = [],
                        where shouldRemove: (ReceivedScreenPass) -> Bool) -> (done: Bool, macIDs: [String]) {
        lock.lock(); defer { lock.unlock() }
        defer { revokedSenders.formUnion(senders) }
        guard let list = load() else {
            // Unreadable: nothing in it can be used, so drop it whole rather than leave it.
            secrets.delete(Self.account)
            return (secrets.read(Self.account) == nil, [])
        }
        let gone = list.filter { !isDenied($0) && shouldRemove($0) }.map(\.id)
        guard !gone.isEmpty else { return (true, []) }
        // Out at once, whether or not the rewrite below works.
        removedMacs.formUnion(gone)
        return (write(list.filter { !shouldRemove($0) }), gone)
    }

    /// Under `lock`: removed, or from a phone that lost access.
    private func isDenied(_ pass: ReceivedScreenPass) -> Bool {
        removedMacs.contains(pass.id) || (pass.fromPhoneID.map(revokedSenders.contains) ?? false)
    }

    /// Nil when something is stored but can't be read.
    private func load() -> [ReceivedScreenPass]? {
        guard let data = secrets.read(Self.account) else { return [] }
        return try? JSONDecoder().decode([ReceivedScreenPass].self, from: data)
    }

    private func write(_ list: [ReceivedScreenPass]) -> Bool {
        if list.isEmpty {
            secrets.delete(Self.account)
            return secrets.read(Self.account) == nil
        }
        guard let data = try? JSONEncoder().encode(list) else { return false }
        return secrets.write(data, account: Self.account)
    }
}
#endif
