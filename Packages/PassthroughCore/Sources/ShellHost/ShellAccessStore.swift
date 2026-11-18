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
    /// The owner lets this phone change Keep awake and the VPN. On unless
    /// turned off (a phone with shell access can already run commands as the
    /// owner); absent in older lists.
    public var control: Bool?
    /// A screen-only pass (another Mac, say) a phone got this Mac to issue:
    /// it may ask for the screen and nothing else. Absent for a phone.
    public var screenOnly: Bool?
    /// The phone that got this Mac to issue the pass; removing that phone removes it too.
    public var grantedBy: String?
    /// The viewer's own id as that phone knows it: a new pass for it replaces this one.
    public var viewerOf: String?

    public init(phoneID: String, label: String, pairingSlot: String, key: Data, previousKey: Data? = nil, grantedAt: Date,
                screen: Bool? = nil, control: Bool? = nil, screenOnly: Bool? = nil, grantedBy: String? = nil, viewerOf: String? = nil) {
        self.phoneID = phoneID; self.label = label; self.pairingSlot = pairingSlot; self.key = key
        self.previousKey = previousKey; self.grantedAt = grantedAt; self.screen = screen; self.control = control
        self.screenOnly = screenOnly; self.grantedBy = grantedBy; self.viewerOf = viewerOf
    }

    public var isScreenOnly: Bool { screenOnly ?? false }
    public var screenAllowed: Bool { screen ?? false }
    /// A screen-only pass never changes Keep awake or the VPN.
    public var controlAllowed: Bool { !isScreenOnly && (control ?? true) }
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
    /// phones whose screen access or control was turned off. Applied to every
    /// list read from the store; cleared once a list that includes them is
    /// written. Guarded by `lock`.
    private var unsavedRevokes: Set<String> = []
    private var unsavedScreenOff: Set<String> = []
    private var unsavedControlOff: Set<String> = []

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
        // A pass's id is the Mac's to mint, never a phone's to claim: a phone
        // granted under one would turn the pass (and its key, held by another
        // Mac) into full access.
        guard !ScreenPass.isViewerID(phone.phoneID), phone.screenOnly != true else {
            ptLog(.error, "A phone claimed a screen pass's id; not recording it")
            return false
        }
        var phone = phone
        if let earlier = list.first(where: { $0.phoneID == phone.phoneID }) {
            guard !earlier.isScreenOnly else {
                ptLog(.error, "A phone claimed a screen pass's id; not recording it")
                return false
            }
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
            phone.control = earlier.control
        }
        list.removeAll { $0.phoneID == phone.phoneID }
        list.append(phone)
        return store(list)
    }

    /// Issues a screen-only pass, granted by `granter` (a phone with access,
    /// itself allowed the screen), for a device it calls `name` and knows as
    /// `viewer`. The pass replaces any earlier one that phone got for that
    /// viewer, and the phone's oldest once it has `ScreenPass.maxPerGranter`.
    /// It follows the phone's pairing: forgetting the phone removes it.
    /// Returns the new id and key and the ids of passes it replaced, or why not.
    public func grantViewer(by granter: String, name: String, viewer: String) -> Result<(id: String, key: Data, replaced: [String]), ShellError> {
        guard ScreenPass.isValidName(name), !viewer.isEmpty, viewer.count <= ScreenPass.maxName * 2 else { return .failure(.badRequest) }
        writeLock.lock(); defer { writeLock.unlock() }
        guard var list = loadForWrite() else { return .failure(.passNotSaved) }
        guard let phone = list.first(where: { $0.phoneID == granter }), !phone.isScreenOnly else { return .failure(.notAuthorized) }
        guard phone.screenAllowed else { return .failure(.screenNotAllowed) }
        var replaced = list.filter { $0.grantedBy == granter && $0.viewerOf == viewer }.map(\.phoneID)
        list.removeAll { replaced.contains($0.phoneID) }
        let others = list.filter { $0.grantedBy == granter }.sorted { $0.grantedAt < $1.grantedAt }
        if others.count >= ScreenPass.maxPerGranter {
            let dropped = others.prefix(others.count - ScreenPass.maxPerGranter + 1).map(\.phoneID)
            replaced += dropped
            list.removeAll { dropped.contains($0.phoneID) }
        }
        let id = ScreenPass.idPrefix + UUID().uuidString.lowercased()
        let key = Self.newKey()
        list.append(ShellPhone(phoneID: id, label: name.trimmingCharacters(in: .whitespacesAndNewlines), pairingSlot: phone.pairingSlot,
                               key: key, grantedAt: now(), screen: true, control: false, screenOnly: true,
                               grantedBy: granter, viewerOf: viewer))
        return store(list) ? .success((id, key, replaced)) : .failure(.passNotSaved)
    }

    /// From memory, like `screenAllowed`: whether this is a screen-only pass.
    /// Fails closed: a pass's id is screen-only even once it is gone.
    public func isScreenOnly(_ phoneID: String) -> Bool {
        ScreenPass.isViewerID(phoneID) || (phones.first { $0.phoneID == phoneID }?.isScreenOnly ?? false)
    }

    /// The screen passes `phoneID` granted, by id.
    public func viewers(grantedBy phoneID: String) -> [String] {
        phones.filter { $0.grantedBy == phoneID }.map(\.phoneID)
    }

    public func key(forPhone phoneID: String) -> Data? {
        phones.first { $0.phoneID == phoneID }?.key
    }

    /// From memory, like `candidateKeys`: asked on every `screen` request. A
    /// screen pass may see the screen only while the phone that granted it
    /// still has access and may see it too: turning that phone's Screen off
    /// (even when that can't be saved) stops its passes with it.
    public func screenAllowed(forPhone phoneID: String) -> Bool {
        let list = phones
        guard let phone = list.first(where: { $0.phoneID == phoneID }), phone.screenAllowed else { return false }
        guard phone.isScreenOnly else { return true }
        guard let granter = phone.grantedBy, let by = list.first(where: { $0.phoneID == granter }) else { return false }
        return !by.isScreenOnly && by.screenAllowed
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

    /// The phone (or iPad) granted through `pairingSlot` now goes by `label`
    /// (its status says so). Checked in memory first: true only if a stored
    /// label changed.
    @discardableResult
    public func relabel(pairingSlot: String, label: String) -> Bool {
        guard !label.isEmpty, phones.contains(where: { $0.pairingSlot == pairingSlot && !$0.isScreenOnly && $0.label != label }) else { return false }
        writeLock.lock(); defer { writeLock.unlock() }
        guard var list = loadForWrite() else { return false }
        // A screen pass keeps its own name (another Mac's), not the phone's that granted it.
        for index in list.indices where list[index].pairingSlot == pairingSlot && !list[index].isScreenOnly { list[index].label = label }
        return store(list)
    }

    /// From memory: asked for every `macState` and every `setAwake` / `setVPN`.
    public func controlAllowed(forPhone phoneID: String) -> Bool {
        phones.first { $0.phoneID == phoneID }?.controlAllowed ?? false
    }

    /// Lets the phone change Keep awake and the VPN, or stops it; as
    /// `setScreenAllowed`, a failed stop still stops it in memory.
    @discardableResult
    public func setControlAllowed(_ allowed: Bool, forPhone phoneID: String) -> Bool {
        writeLock.lock(); defer { writeLock.unlock() }
        guard var list = loadForWrite(), let index = list.firstIndex(where: { $0.phoneID == phoneID }) else { return false }
        list[index].control = allowed
        if allowed { return store(list) }
        setCache(list)
        if write(list) { saved(); return true }
        ptLog(.error, "Could not store that a phone may no longer change Keep awake and the VPN; it stays off until this Mac quits")
        lock.lock(); unsavedControlOff.insert(phoneID); lock.unlock()
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
        // The screen passes it granted follow it.
        for other in list.indices where list[other].grantedBy == phoneID && list[other].pairingSlot == fromSlot {
            list[other].pairingSlot = toSlot
        }
        return store(list)
    }

    /// False only if the key may still be usable afterwards.
    @discardableResult
    /// Also removes the screen passes that phone granted.
    public func revoke(phoneID: String) -> Bool {
        removing { $0.phoneID == phoneID || $0.grantedBy == phoneID }.done
    }

    /// Removes every phone granted through this pairing slot (a cable or a wireless link).
    @discardableResult
    public func revoke(pairingSlot: String) -> Bool {
        removing { $0.pairingSlot == pairingSlot }.done
    }

    /// As `revoke(phoneID:)`, also saying which entries it removed (the
    /// phone and its passes), as found under the write lock, so a pass
    /// granted meanwhile is among them.
    public func revokeReporting(phoneID: String) -> (done: Bool, removed: [ShellPhone]) {
        removing { $0.phoneID == phoneID || $0.grantedBy == phoneID }
    }

    /// As `revoke(pairingSlot:)`, also saying which entries it removed.
    public func revokeReporting(pairingSlot: String) -> (done: Bool, removed: [ShellPhone]) {
        removing { $0.pairingSlot == pairingSlot }
    }

    /// Removes one screen pass `granter` granted (one it gave no Mac after
    /// all). False if there is no such pass or it may still be usable.
    /// Returns what it removed (empty: nothing of that phone's by that id),
    /// so the caller cuts its connections even when the removal couldn't be saved.
    @discardableResult
    public func revokeViewer(_ viewerID: String, grantedBy granter: String) -> (done: Bool, removed: [ShellPhone]) {
        let matches = { (phone: ShellPhone) in phone.phoneID == viewerID && phone.grantedBy == granter && phone.isScreenOnly }
        // Not this phone's pass (or nothing readable): touch nothing, so a
        // stranger's request can never set off the remove-everything fallback.
        guard ScreenPass.isViewerID(viewerID), phones.contains(where: matches) else { return (true, []) }
        return removing(where: matches)
    }

    /// Revocation fails closed: the phone leaves the in-memory list first, so
    /// it is refused at once; if the stored list then cannot be rewritten (or
    /// read), it is deleted whole rather than left holding a revoked key.
    private func removing(where shouldRemove: (ShellPhone) -> Bool) -> (done: Bool, removed: [ShellPhone]) {
        writeLock.lock(); defer { writeLock.unlock() }
        if var list = loadForWrite() {
            let entries = list.filter(shouldRemove)
            // Nothing to remove: nothing to write (a failed write would set off the fallback below).
            guard !entries.isEmpty else { return (true, []) }
            let removed = Set(entries.map(\.phoneID))
            list.removeAll(where: shouldRemove)
            setCache(list)
            if write(list) { saved(); return (true, entries) }
            ptLog(.error, "Could not update the shell phones; removing them all")
            secrets.delete(Self.account)
            // Still stored: the in-memory list stays the trimmed one, and any
            // later read of the store leaves these phones out.
            if secrets.read(Self.account) == nil { setCache(nil); saved(); return (true, entries) }
            lock.lock(); unsavedRevokes.formUnion(removed); lock.unlock()
            return (false, entries)
        }
        ptLog(.error, "Could not update the shell phones; removing them all")
        lock.lock(); let everyone = cached ?? []; lock.unlock()
        setCache(nil)
        secrets.delete(Self.account)
        return (secrets.read(Self.account) == nil, everyone.filter(shouldRemove))
    }

    private func setCache(_ list: [ShellPhone]?) {
        lock.lock(); cached = list; emptyUntil = nil; generation += 1; lock.unlock()
    }

    /// A list built on the in-memory one (so with every unsaved reduction
    /// applied) was written, or nothing is stored at all: nothing is unsaved.
    private func saved() {
        lock.lock(); unsavedRevokes.removeAll(); unsavedScreenOff.removeAll(); unsavedControlOff.removeAll(); lock.unlock()
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
        lock.lock(); let revoked = unsavedRevokes, screenOff = unsavedScreenOff, controlOff = unsavedControlOff; lock.unlock()
        list.removeAll { revoked.contains($0.phoneID) }
        for index in list.indices where screenOff.contains(list[index].phoneID) { list[index].screen = false }
        for index in list.indices where controlOff.contains(list[index].phoneID) { list[index].control = false }
        return list
    }
}
#endif
