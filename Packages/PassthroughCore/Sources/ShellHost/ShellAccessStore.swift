#if os(macOS)
import Foundation
import Security
import PassthroughCore

/// A phone the owner has allowed to open shells on this Mac.
public struct ShellPhone: Codable, Equatable, Sendable {
    public var phoneID: String
    public var label: String
    public var pairingSlot: String
    /// The per-phone shell key. Treat as a secret: never log it.
    public var key: Data
    /// The key this phone held before its latest grant, still accepted until
    /// the phone first proves `key`: a phone adopts a new grant only once it
    /// is unlocked, so plugging it in must not lock it out meanwhile. A secret
    /// too. Absent in lists stored before it existed.
    public var previousKey: Data?
    public var grantedAt: Date
    /// The owner also let this phone see and control the screen (through
    /// Screen Sharing). Off unless turned on; absent in older lists.
    public var screen: Bool?

    public init(phoneID: String, label: String, pairingSlot: String, key: Data, previousKey: Data? = nil, grantedAt: Date,
                screen: Bool? = nil) {
        self.phoneID = phoneID; self.label = label; self.pairingSlot = pairingSlot; self.key = key
        self.previousKey = previousKey; self.grantedAt = grantedAt; self.screen = screen
    }

    public var screenAllowed: Bool { screen ?? false }
}

/// The phones allowed a shell, with their keys, kept in the Mac's secret store.
/// The list is read from the store and then answered from memory (the shell
/// listener asks on every handshake, on a queue that must not wait on the
/// Keychain); every write this store makes updates or drops that copy. A
/// read that finds nothing is remembered for `emptyTTL` only, so a stranger's
/// handshakes cannot make every one go to the Keychain, while a phone stored
/// by another writer is still seen soon. The lock guarding the copy is never
/// held across store I/O, and writes serialize on their own lock.
///
/// Taking access away fails closed: a revoke, or Screen turned off, holds in
/// memory even when the store cannot be written, and is laid over every
/// later read of the store until a write succeeds, so a failed write never
/// brings back what the owner took away.
public final class ShellAccessStore: @unchecked Sendable {
    private static let account = "shell.phones"
    /// How long a read that found nothing is answered from memory.
    public static let emptyTTL: TimeInterval = 5
    private let secrets: SecretStore
    private let now: @Sendable () -> Date
    /// Guards `cached` and `generation` only; held briefly, never across I/O.
    private let lock = NSLock()
    /// Serializes read-modify-write cycles (and so the store writes).
    private let writeLock = NSLock()
    /// The stored list as last read or written; nil until read, after a
    /// failed write and after a read that could not be decoded, so the next
    /// read goes to the store again.
    private var cached: [ShellPhone]?
    /// When `cached` came from a read that found nothing: until when that
    /// answer stands (writes never rely on it). Nil for any other `cached`.
    private var emptyUntil: Date?
    /// Bumped whenever `cached` is set by a write, so a read that began
    /// earlier does not install what it saw before that write.
    private var generation = 0
    /// Reductions not yet in the store (its write failed): phones revoked and
    /// phones whose screen access was turned off. Applied to every list read
    /// from the store; cleared once a list that includes them is written.
    /// Guarded by `lock`.
    private var unsavedRevokes: Set<String> = []
    private var unsavedScreenOff: Set<String> = []

    /// `now` is for tests.
    public init(secrets: SecretStore, now: @escaping @Sendable () -> Date = Date.init) {
        self.secrets = secrets
        self.now = now
    }

    public var phones: [ShellPhone] {
        lock.lock()
        if let cached, emptyUntil.map({ now() < $0 }) ?? true { lock.unlock(); return cached }
        let seen = generation
        lock.unlock()
        let loaded = readStore()
        if let list = loaded {
            lock.lock()
            if generation == seen, cached == nil || emptyUntil != nil {
                cached = list
                emptyUntil = list.isEmpty ? now() + Self.emptyTTL : nil
            }
            lock.unlock()
        }
        return loaded ?? []
    }

    /// 32 random bytes.
    public static func newKey() -> Data {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes)
    }

    /// Adds the phone, replacing any earlier grant for the same phone ID. The
    /// key that phone last proved stays accepted as `previousKey` until the
    /// new one is first used (`confirmCurrentKey`). False if it could not be stored (or the stored list is unreadable and
    /// must not be overwritten): the phone then has no key, so grant none.
    /// Also false when that phone ID was granted through another pairing: the
    /// ID is the phone's own claim, so one paired phone must not take over
    /// (or lock out) another's access by naming it.
    @discardableResult
    public func record(_ phone: ShellPhone) -> Bool {
        writeLock.lock(); defer { writeLock.unlock() }
        guard var list = loadForWrite() else {
            ptLog(.error, "The stored shell phones are unreadable; not recording a new one")
            return false
        }
        var phone = phone
        if let earlier = list.first(where: { $0.phoneID == phone.phoneID }) {
            guard earlier.pairingSlot == phone.pairingSlot else {
                ptLog(.error, "A phone claimed the shell access of a phone granted through another pairing; not recording it")
                return false
            }
            // An unconfirmed earlier grant was never used, so the phone may
            // still hold only the key before it: keep that one.
            let kept = earlier.previousKey ?? earlier.key
            phone.previousKey = kept == phone.key ? nil : kept
            // Plugging the phone in again renews its key, not what it may do.
            phone.screen = earlier.screen
        }
        list.removeAll { $0.phoneID == phone.phoneID }
        list.append(phone)
        return store(list)
    }

    public func key(forPhone phoneID: String) -> Data? {
        phones.first { $0.phoneID == phoneID }?.key
    }

    /// From memory, like `candidateKeys`: asked on every `screen` request.
    public func screenAllowed(forPhone phoneID: String) -> Bool {
        phones.first { $0.phoneID == phoneID }?.screenAllowed ?? false
    }

    /// Lets the phone see and control the screen, or stops it. False if it
    /// could not be stored, or the phone is unknown. A failed allow changes
    /// nothing; a failed stop still stops it, in memory, until the store can
    /// be written (and the caller should say it may come back after a relaunch).
    @discardableResult
    public func setScreenAllowed(_ allowed: Bool, forPhone phoneID: String) -> Bool {
        writeLock.lock(); defer { writeLock.unlock() }
        guard var list = loadForWrite(), let index = list.firstIndex(where: { $0.phoneID == phoneID }) else {
            // Unreadable or unknown: nobody can be allowed the screen through it anyway.
            return false
        }
        list[index].screen = allowed
        if allowed { return store(list) }
        setCache(list)
        if write(list) { saved(); return true }
        ptLog(.error, "Could not store that a phone may no longer see the screen; it stays off until this Mac quits")
        lock.lock(); unsavedScreenOff.insert(phoneID); lock.unlock()
        return false
    }

    /// The keys a proof from this phone may use: its current key, then the
    /// previous one while that is still accepted. Empty for an unknown phone.
    public func candidateKeys(forPhone phoneID: String) -> [Data] {
        guard let phone = phones.first(where: { $0.phoneID == phoneID }) else { return [] }
        return [phone.key] + (phone.previousKey.map { [$0] } ?? [])
    }

    /// The phone proved `proven`, its current key, so it has adopted its
    /// latest grant: the previous key stops working. Nothing changes if the
    /// phone was granted again meanwhile (the current key is no longer the
    /// one proved): the phone may not have that grant yet. Writes only when
    /// there is a key to drop.
    public func confirmCurrentKey(phoneID: String, proven: Data) {
        writeLock.lock(); defer { writeLock.unlock() }
        guard var list = loadForWrite(), let index = list.firstIndex(where: { $0.phoneID == phoneID }),
              list[index].key == proven, list[index].previousKey != nil else { return }
        list[index].previousKey = nil
        if !store(list) { ptLog(.warning, "Could not drop a phone's previous shell key") }
    }

    /// The phone's pairing moved from `fromSlot` to `toSlot` (an iPhone's,
    /// out of the slot every iPhone once shared): so does its access, which
    /// `record` would otherwise refuse to renew. False if the phone has no
    /// access through `fromSlot`, or the move could not be stored.
    @discardableResult
    public func move(phoneID: String, fromSlot: String, toSlot: String) -> Bool {
        writeLock.lock(); defer { writeLock.unlock() }
        guard var list = loadForWrite(),
              let index = list.firstIndex(where: { $0.phoneID == phoneID && $0.pairingSlot == fromSlot }) else { return false }
        list[index].pairingSlot = toSlot
        return store(list)
    }

    /// False only if the key may still be usable afterwards.
    @discardableResult
    public func revoke(phoneID: String) -> Bool {
        remove { $0.phoneID == phoneID }
    }

    /// Removes every phone granted through this pairing slot (a cable or a wireless link).
    @discardableResult
    public func revoke(pairingSlot: String) -> Bool {
        remove { $0.pairingSlot == pairingSlot }
    }

    /// Revocation fails closed: the phone leaves the in-memory list first, so
    /// it is refused at once; if the stored list then cannot be rewritten (or
    /// read), it is deleted whole rather than left holding a revoked key.
    private func remove(where shouldRemove: (ShellPhone) -> Bool) -> Bool {
        writeLock.lock(); defer { writeLock.unlock() }
        if var list = loadForWrite() {
            let removed = Set(list.filter(shouldRemove).map(\.phoneID))
            list.removeAll(where: shouldRemove)
            setCache(list)
            if write(list) { saved(); return true }
            ptLog(.error, "Could not update the shell phones; removing them all")
            secrets.delete(Self.account)
            // Still stored: the in-memory list stays the trimmed one, and any
            // later read of the store leaves these phones out.
            if secrets.read(Self.account) == nil { setCache(nil); saved(); return true }
            lock.lock(); unsavedRevokes.formUnion(removed); lock.unlock()
            return false
        }
        ptLog(.error, "Could not update the shell phones; removing them all")
        setCache(nil)
        secrets.delete(Self.account)
        return secrets.read(Self.account) == nil
    }

    private func setCache(_ list: [ShellPhone]?) {
        lock.lock(); cached = list; emptyUntil = nil; generation += 1; lock.unlock()
    }

    /// A list built on the in-memory one (so with every unsaved reduction
    /// applied) was written, or nothing is stored at all: nothing is unsaved.
    private func saved() {
        lock.lock(); unsavedRevokes.removeAll(); unsavedScreenOff.removeAll(); lock.unlock()
    }

    /// Writes `list` to the store, no lock held.
    private func write(_ list: [ShellPhone]) -> Bool {
        guard let data = try? JSONEncoder().encode(list) else { return false }
        return secrets.write(data, account: Self.account)
    }

    /// Under `writeLock`.
    private func store(_ list: [ShellPhone]) -> Bool {
        if write(list) { setCache(list); saved(); return true }
        setCache(nil)   // whatever the store holds now, read it again
        return false
    }

    /// The list to modify, under `writeLock`: nil when something is stored but
    /// unreadable.
    private func loadForWrite() -> [ShellPhone]? {
        lock.lock(); let current = emptyUntil == nil ? cached : nil; lock.unlock()
        if let current { return current }
        let loaded = readStore()
        if let list = loaded, !list.isEmpty { setCache(list) }
        return loaded
    }

    /// From the store, with the unsaved reductions applied; no lock held
    /// across the read. Empty when nothing is stored and nil when something
    /// is stored but unreadable.
    private func readStore() -> [ShellPhone]? {
        guard let data = secrets.read(Self.account) else { return [] }
        guard var list = try? JSONDecoder().decode([ShellPhone].self, from: data) else { return nil }
        lock.lock(); let revoked = unsavedRevokes, screenOff = unsavedScreenOff; lock.unlock()
        list.removeAll { revoked.contains($0.phoneID) }
        for index in list.indices where screenOff.contains(list[index].phoneID) { list[index].screen = false }
        return list
    }
}
#endif
