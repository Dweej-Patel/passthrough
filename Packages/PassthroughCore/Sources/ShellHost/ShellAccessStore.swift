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
    /// A computer (`Computers`): its identity public key (a 65-byte point), recorded at grant. Every
    /// proof it makes is also signed with it. Absent for phones and passes.
    public var identityKey: Data?
    /// A computer's shell scope (its screen scope is `screen`). Absent for phones and passes.
    public var shell: Bool?
    /// A computer's kind (`HostInfo.kindMac`, `kindWindows`), for showing.
    public var kind: String?
    /// On a phone's record: "May share access with other computers". Off unless turned on.
    public var share: Bool?

    public init(phoneID: String, label: String, pairingSlot: String, key: Data, previousKey: Data? = nil, grantedAt: Date,
                screen: Bool? = nil, control: Bool? = nil, screenOnly: Bool? = nil, grantedBy: String? = nil, viewerOf: String? = nil,
                identityKey: Data? = nil, shell: Bool? = nil, kind: String? = nil, share: Bool? = nil) {
        self.phoneID = phoneID; self.label = label; self.pairingSlot = pairingSlot; self.key = key
        self.previousKey = previousKey; self.grantedAt = grantedAt; self.screen = screen; self.control = control
        self.screenOnly = screenOnly; self.grantedBy = grantedBy; self.viewerOf = viewerOf
        self.identityKey = identityKey; self.shell = shell; self.kind = kind; self.share = share
    }

    public var isScreenOnly: Bool { screenOnly ?? false }
    public var screenAllowed: Bool { screen ?? false }
    /// A computer another device gave access (by its id, which only this Mac mints).
    public var isComputer: Bool { Computers.isComputerID(phoneID) }
    /// A screen-only pass or a computer never changes Keep awake or the VPN.
    public var controlAllowed: Bool { !isScreenOnly && !isComputer && (control ?? true) }
    /// Only a phone may give other computers access, and only once the owner lets it.
    public var shareAllowed: Bool { !isScreenOnly && !isComputer && (share ?? false) }
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
///
/// Screen passes are kept in their own item, apart from the phones: a build
/// that predates them reads only the phones' item, so it can never take a
/// pass (whose key another Mac holds) for a phone with full access.
/// Computers phones gave access (`Computers`) have a third item of their
/// own for the same reason, and stay in the one list, so removing a phone
/// removes them through the same fail-closed path as its passes.
public final class ShellAccessStore: @unchecked Sendable {
    private static let account = "shell.phones"
    private static let passAccount = "shell.screenPasses"
    private static let computerAccount = "shell.computers"
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
    private var unsavedShareOff: Set<String> = []
    /// A read found entries it left out (passes in the phones' item, from
    /// before they had their own, or passes that can't be used): the next
    /// write rewrites both items without them. Guarded by `lock`.
    private var needsTidy = false

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
        let before = list
        // A pass's id is the Mac's to mint, never a phone's to claim: a phone
        // granted under one would turn the pass (and its key, held by another
        // Mac) into full access.
        guard !ScreenPass.isViewerID(phone.phoneID), phone.screenOnly != true else {
            ptLog(.error, "A phone claimed a screen pass's id; not recording it")
            return false
        }
        // The same for a computer's id: its key and identity are another computer's.
        guard !Computers.isComputerID(phone.phoneID) else {
            ptLog(.error, "A phone claimed a computer's id; not recording it")
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
            phone.share = earlier.share
        }
        list.removeAll { $0.phoneID == phone.phoneID }
        list.append(phone)
        return store(list, over: before)
    }

    /// Issues a screen-only pass, granted by `granter` (a phone with access,
    /// itself allowed the screen), for a device it calls `name` and knows as
    /// `viewer`. An earlier pass that phone got for that viewer stays until
    /// the new one is first used (`supersede(by:)`), since the hand-over to
    /// the viewer may still fail; only the newest such earlier pass is kept.
    /// The phone's oldest pass goes once it has `ScreenPass.maxPerGranter`.
    /// It follows the phone's pairing: forgetting the phone removes it.
    /// Returns the new id and key and the ids of passes it removed, or why not.
    public func grantViewer(by granter: String, name: String, viewer: String) -> Result<(id: String, key: Data, replaced: [String]), ShellError> {
        guard ScreenPass.isValidName(name), !viewer.isEmpty, viewer.count <= ScreenPass.maxName * 2 else { return .failure(.badRequest) }
        writeLock.lock(); defer { writeLock.unlock() }
        guard var list = loadForWrite() else { return .failure(.passNotSaved) }
        let before = list
        guard let phone = list.first(where: { $0.phoneID == granter }), !phone.isScreenOnly, !phone.isComputer else { return .failure(.notAuthorized) }
        guard phone.screenAllowed else { return .failure(.screenNotAllowed) }
        // In the order granted: the last is the newest, and the one kept. Only passes: a
        // computer the phone gave access is never dropped to make room for one.
        var replaced = Array(list.filter { $0.isScreenOnly && $0.grantedBy == granter && $0.viewerOf == viewer }.map(\.phoneID).dropLast())
        list.removeAll { replaced.contains($0.phoneID) }
        let others = list.filter { $0.isScreenOnly && $0.grantedBy == granter }.sorted { $0.grantedAt < $1.grantedAt }
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
        return store(list, over: before) ? .success((id, key, replaced)) : .failure(.passNotSaved)
    }

    /// The pass `passID` was used (its viewer proved its key), so its viewer
    /// has it: the earlier passes the same phone granted that viewer go.
    /// Answered from memory when there are none, as there usually aren't.
    /// Returns what it removed.
    @discardableResult
    public func supersede(by passID: String) -> [ShellPhone] {
        guard let pass = phones.first(where: { $0.phoneID == passID && $0.isScreenOnly }),
              let granter = pass.grantedBy, let viewer = pass.viewerOf else { return [] }
        // Only older ones: a pass granted after this one may still be on its way to the viewer.
        let stale = { (other: ShellPhone) in
            other.isScreenOnly && other.phoneID != passID && other.grantedBy == granter && other.viewerOf == viewer
                && other.grantedAt < pass.grantedAt
        }
        guard phones.contains(where: stale) else { return [] }
        return removing(where: stale).removed
    }

    // MARK: Computers

    /// Gives another of the phone's computers access, granted by `granter` (a phone the owner lets
    /// share), for the computer it calls `name` and knows as `viewer` (its host id), proving with
    /// `identityKey`. The rules, in order: a valid request, else `bad_request`; a phone, else
    /// `not_authorized`; one that may share, else `not_allowed`; the screen only for a phone that may
    /// see it, else `screen_not_allowed`; at most `Computers.maxPerGranter` a phone and
    /// `Computers.maxTotal` in all, else refused `too_many_computers`. An earlier grant by the same
    /// phone for the same viewer is replaced (it doesn't count). It follows the phone's pairing:
    /// forgetting the phone removes it. Returns the new id and key, its scopes and the ids replaced.
    public func grantComputer(by granter: String, name: String, viewer: String, kind: String?, identityKey: Data,
                              scopes: Set<String>) -> Result<(id: String, key: Data, scopes: [String], replaced: [String]), ShellError> {
        guard ScreenPass.isValidName(name), !viewer.isEmpty, viewer.count <= ScreenPass.maxName * 2,
              ComputerProof.isPoint(identityKey), !scopes.isEmpty, scopes.isSubset(of: Set(Computers.allScopes)) else { return .failure(.badRequest) }
        writeLock.lock(); defer { writeLock.unlock() }
        guard var list = loadForWrite() else { return .failure(.passNotSaved) }
        let before = list
        guard let phone = list.first(where: { $0.phoneID == granter }), !phone.isScreenOnly, !phone.isComputer else { return .failure(.notAuthorized) }
        guard phone.shareAllowed else { return .failure(.notAllowed) }
        if scopes.contains(Computers.scopeScreen), !phone.screenAllowed { return .failure(.screenNotAllowed) }
        let replaced = list.filter { $0.isComputer && $0.grantedBy == granter && $0.viewerOf == viewer }.map(\.phoneID)
        let others = list.filter { $0.isComputer && !replaced.contains($0.phoneID) }
        guard others.filter({ $0.grantedBy == granter }).count < Computers.maxPerGranter, others.count < Computers.maxTotal else {
            return .failure(.tooManyComputers)
        }
        list.removeAll { replaced.contains($0.phoneID) }
        let id = Computers.newID()
        let key = Self.newKey()
        list.append(ShellPhone(phoneID: id, label: name.trimmingCharacters(in: .whitespacesAndNewlines), pairingSlot: phone.pairingSlot,
                               key: key, grantedAt: now(), screen: scopes.contains(Computers.scopeScreen) ? true : nil, control: false,
                               grantedBy: granter, viewerOf: viewer, identityKey: identityKey,
                               shell: scopes.contains(Computers.scopeShell) ? true : nil,
                               kind: Hosts.isRecordable(kind) ? kind : nil))
        guard store(list, over: before) else { return .failure(.passNotSaved) }
        return .success((id, key, Computers.allScopes.filter(scopes.contains), replaced))
    }

    /// From memory: the identity key a computer's proof must be signed with; nil for anything that
    /// isn't a computer with access (unknown, its phone gone, or nothing left it may do).
    public func computerKey(_ id: String) -> Data? {
        let list = phones
        guard !Self.scopes(of: id, in: list).isEmpty else { return nil }
        return list.first { $0.phoneID == id }?.identityKey
    }

    /// From memory, asked on every request: what a computer may do now. `shell` while its phone keeps
    /// access, `screen` while that phone may also see the screen. Empty for anything else.
    public func scopes(of id: String) -> Set<String> {
        Self.scopes(of: id, in: phones)
    }

    private static func scopes(of id: String, in list: [ShellPhone]) -> Set<String> {
        guard Computers.isComputerID(id), let computer = list.first(where: { $0.phoneID == id }) else { return [] }
        let granter = computer.grantedBy.flatMap { by in list.first { $0.phoneID == by && !$0.isScreenOnly && !$0.isComputer } }
        guard computer.grantedBy == nil || granter != nil else { return [] }
        var scopes = Set<String>()
        if computer.shell == true { scopes.insert(Computers.scopeShell) }
        if computer.screen == true, granter?.screenAllowed ?? true { scopes.insert(Computers.scopeScreen) }
        return scopes
    }

    /// The computers `granter` gave access here, oldest first, as `computerList` lists them (`connected`
    /// is the listener's to say). On a Mac nothing waits for the owner: there is no `pending`.
    public func computers(grantedBy granter: String) -> [ComputerAccess] {
        let list = phones
        return list.filter { $0.isComputer && $0.grantedBy == granter }
            .sorted { $0.grantedAt < $1.grantedAt }
            .prefix(Computers.maxTotal)
            .map { computer in
                let scopes = Self.scopes(of: computer.phoneID, in: list)
                return ComputerAccess(phoneID: computer.phoneID, viewer: computer.viewerOf, name: computer.label, kind: computer.kind,
                                      scopes: Computers.allScopes.filter(scopes.contains), connected: false,
                                      grantedAt: Int64(computer.grantedAt.timeIntervalSince1970))
            }
    }

    /// Takes back one computer `granter` gave access (one it couldn't hand over after all), as
    /// `revokeViewer`. Returns what it removed (empty: nothing of that phone's by that id).
    @discardableResult
    public func revokeComputer(_ id: String, grantedBy granter: String) -> (done: Bool, removed: [ShellPhone]) {
        let matches = { (entry: ShellPhone) in entry.phoneID == id && entry.grantedBy == granter && entry.isComputer }
        guard Computers.isComputerID(id), phones.contains(where: matches) else { return (true, []) }
        return removing(where: matches)
    }

    /// The owner takes back a computer's access, whichever phone gave it (Settings ▸ Computers with
    /// access). Only that computer goes: its phone's own access and passes stay. Returns what it
    /// removed (empty: no computer by that id), so the caller cuts its connections even when the
    /// removal couldn't be saved.
    @discardableResult
    public func revokeComputer(_ id: String) -> (done: Bool, removed: [ShellPhone]) {
        let matches = { (entry: ShellPhone) in entry.phoneID == id && entry.isComputer }
        guard Computers.isComputerID(id), phones.contains(where: matches) else { return (true, []) }
        return removing(where: matches)
    }

    /// From memory: whether the phone may give other computers access ("May share access with other computers").
    public func shareAllowed(forPhone phoneID: String) -> Bool {
        phones.first { $0.phoneID == phoneID }?.shareAllowed ?? false
    }

    /// Lets the phone give other computers access, or stops it; as `setScreenAllowed`, a failed stop
    /// still stops it in memory. Stopping removes nothing it already gave.
    @discardableResult
    public func setShareAllowed(_ allowed: Bool, forPhone phoneID: String) -> Bool {
        writeLock.lock(); defer { writeLock.unlock() }
        guard var list = loadForWrite(), let index = list.firstIndex(where: { $0.phoneID == phoneID }),
              !list[index].isScreenOnly, !list[index].isComputer else { return false }
        let before = list
        list[index].share = allowed
        if allowed { return store(list, over: before) }
        setCache(list)
        if write(list, over: before).ok { saved(); return true }
        ptLog(.error, "Could not store that a phone may no longer share access; it stays off until this Mac quits")
        lock.lock(); unsavedShareOff.insert(phoneID); lock.unlock()
        return false
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
        // A computer: its screen scope, while the phone that gave it may see the screen too.
        if Computers.isComputerID(phoneID) { return Self.scopes(of: phoneID, in: list).contains(Computers.scopeScreen) }
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
        let before = list
        list[index].screen = allowed
        if allowed { return store(list, over: before) }
        setCache(list)
        if write(list, over: before).ok { saved(); return true }
        ptLog(.error, "Could not store that a phone may no longer see the screen; it stays off until this Mac quits")
        lock.lock(); unsavedScreenOff.insert(phoneID); lock.unlock()
        return false
    }

    /// The phone (or iPad) granted through `pairingSlot` now goes by `label`
    /// (its status says so). Checked in memory first: true only if a stored
    /// label changed.
    @discardableResult
    public func relabel(pairingSlot: String, label: String) -> Bool {
        guard !label.isEmpty, phones.contains(where: { $0.pairingSlot == pairingSlot && !$0.isScreenOnly && !$0.isComputer && $0.label != label }) else { return false }
        writeLock.lock(); defer { writeLock.unlock() }
        guard var list = loadForWrite() else { return false }
        let before = list
        // A screen pass or a computer keeps its own name (another Mac's), not the phone's that granted it.
        for index in list.indices where list[index].pairingSlot == pairingSlot && !list[index].isScreenOnly && !list[index].isComputer {
            list[index].label = label
        }
        return store(list, over: before)
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
        let before = list
        list[index].control = allowed
        if allowed { return store(list, over: before) }
        setCache(list)
        if write(list, over: before).ok { saved(); return true }
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
        let before = list
        list[index].previousKey = nil
        if !store(list, over: before) { ptLog(.warning, "Could not drop a phone's previous shell key") }
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
        let before = list
        list[index].pairingSlot = toSlot
        // The screen passes it granted follow it.
        for other in list.indices where list[other].grantedBy == phoneID && list[other].pairingSlot == fromSlot {
            list[other].pairingSlot = toSlot
        }
        return store(list, over: before)
    }

    /// Also removes the screen passes that phone granted. False only if the
    /// key may still be usable afterwards.
    @discardableResult
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
    /// Only the item that failed goes: passes that can't be rewritten never
    /// cost the phones their access.
    private func removing(where shouldRemove: (ShellPhone) -> Bool) -> (done: Bool, removed: [ShellPhone]) {
        writeLock.lock(); defer { writeLock.unlock() }
        if var list = loadForWrite() {
            let entries = list.filter(shouldRemove)
            // Nothing to remove: nothing to write (a failed write would set off the fallback below).
            guard !entries.isEmpty else { return (true, []) }
            let removed = Set(entries.map(\.phoneID))
            let before = list
            list.removeAll(where: shouldRemove)
            setCache(list)
            let written = write(list, over: before)
            if written.ok { saved(); return (true, entries) }
            var gone = true
            if !written.phones {
                ptLog(.error, "Could not update the shell phones; removing them all")
                secrets.delete(Self.account)
                gone = secrets.read(Self.account) == nil
            }
            // Passes and computers without their phones can't be used, but they don't stay behind either.
            if !written.phones || !written.passes {
                if written.phones { ptLog(.error, "Could not update the screen passes; removing them all") }
                secrets.delete(Self.passAccount)
                gone = gone && secrets.read(Self.passAccount) == nil
            }
            if !written.phones || !written.computers {
                if written.phones { ptLog(.error, "Could not update the computers with access; removing them all") }
                secrets.delete(Self.computerAccount)
                gone = gone && secrets.read(Self.computerAccount) == nil
            }
            // Still stored: the in-memory list stays the trimmed one, and any
            // later read of the store leaves these phones out.
            if gone { setCache(nil); saved(); return (true, entries) }
            lock.lock(); unsavedRevokes.formUnion(removed); lock.unlock()
            return (false, entries)
        }
        ptLog(.error, "Could not update the shell phones; removing them all")
        lock.lock(); let everyone = cached ?? []; lock.unlock()
        setCache(nil)
        secrets.delete(Self.account)
        secrets.delete(Self.passAccount)
        secrets.delete(Self.computerAccount)
        return (secrets.read(Self.account) == nil && secrets.read(Self.passAccount) == nil && secrets.read(Self.computerAccount) == nil,
                everyone.filter(shouldRemove))
    }

    private func setCache(_ list: [ShellPhone]?) {
        lock.lock(); cached = list; emptyUntil = nil; generation += 1; lock.unlock()
    }

    /// A list built on the in-memory one (so with every unsaved reduction
    /// applied) was written, or nothing is stored at all: nothing is unsaved.
    private func saved() {
        lock.lock()
        unsavedRevokes.removeAll(); unsavedScreenOff.removeAll(); unsavedControlOff.removeAll(); unsavedShareOff.removeAll()
        lock.unlock()
    }

    /// Whether an entry is a screen pass (kept in the passes' item), by what it says or by its id.
    private static func isPass(_ entry: ShellPhone) -> Bool {
        !entry.isComputer && (entry.isScreenOnly || ScreenPass.isViewerID(entry.phoneID))
    }

    /// Whether an entry is a computer (kept in the computers' item), by its id.
    private static func isComputer(_ entry: ShellPhone) -> Bool { entry.isComputer }

    /// A phone's own entry (kept in the phones' item).
    private static func isPhone(_ entry: ShellPhone) -> Bool { !isPass(entry) && !isComputer(entry) }

    /// A stored computer that can be used: its key and identity key well formed, something it may
    /// do, and the phone that gave it access (if one did) among `phones`.
    private static func isUsableComputer(_ entry: ShellPhone, phones: Set<String>) -> Bool {
        entry.isComputer && !entry.isScreenOnly && entry.key.count == 32 && entry.identityKey.map(ComputerProof.isPoint) == true
            && (entry.shell == true || entry.screen == true) && (entry.grantedBy.map(phones.contains) ?? true)
    }

    /// Which of the three items a write stored (true when there was nothing to write).
    private struct Written {
        var phones = true, passes = true, computers = true
        var ok: Bool { phones && passes && computers }
    }

    /// Writes `list`, its phones and its passes each to their own item, no
    /// lock held. Only the part that differs from `previous` (the list it was
    /// made from) is written, so changing a phone never writes the passes'
    /// item and a pass never the phones'; both are written while a reduction
    /// is unsaved, or a read found something to tidy.
    private func write(_ list: [ShellPhone], over previous: [ShellPhone]) -> Written {
        let phones = list.filter(Self.isPhone), passes = list.filter(Self.isPass), computers = list.filter(Self.isComputer)
        lock.lock()
        let all = needsTidy || !unsavedRevokes.isEmpty || !unsavedScreenOff.isEmpty || !unsavedControlOff.isEmpty || !unsavedShareOff.isEmpty
        lock.unlock()
        var written = Written()
        if all || previous.filter(Self.isPhone) != phones {
            written.phones = (try? JSONEncoder().encode(phones)).map { secrets.write($0, account: Self.account) } ?? false
        }
        if all || previous.filter(Self.isPass) != passes {
            written.passes = writeItem(passes, account: Self.passAccount)
        }
        if all || previous.filter(Self.isComputer) != computers {
            written.computers = writeItem(computers, account: Self.computerAccount)
        }
        if all, written.ok { lock.lock(); needsTidy = false; lock.unlock() }
        return written
    }

    /// The passes' or the computers' item: deleted when there are none.
    private func writeItem(_ entries: [ShellPhone], account: String) -> Bool {
        if entries.isEmpty {
            secrets.delete(account)
            return secrets.read(account) == nil
        }
        return (try? JSONEncoder().encode(entries)).map { secrets.write($0, account: account) } ?? false
    }

    /// Under `writeLock`.
    private func store(_ list: [ShellPhone], over previous: [ShellPhone]) -> Bool {
        if write(list, over: previous).ok { setCache(list); saved(); return true }
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

    /// From the store (the phones, then their passes), with the unsaved
    /// reductions applied; no lock held across the read. Empty when nothing
    /// is stored and nil when the phones are stored but unreadable.
    private func readStore() -> [ShellPhone]? {
        var list: [ShellPhone] = []
        var tidy = false
        if let data = secrets.read(Self.account) {
            guard let stored = try? JSONDecoder().decode([ShellPhone].self, from: data) else { return nil }
            // Passes stored among the phones (before they had their own item)
            // are left out, never taken for phones, and that item is rewritten without them.
            list = stored.filter(Self.isPhone)
            tidy = list.count != stored.count
        }
        let phoneIDs = Set(list.map(\.phoneID))
        if let data = secrets.read(Self.passAccount) {
            // Passes that can't be read, aren't passes, or whose phone is gone
            // can't be used: they're left out, and the item rewritten without them.
            let stored = try? JSONDecoder().decode([ShellPhone].self, from: data)
            let passes = (stored ?? []).filter { $0.isScreenOnly && ScreenPass.isViewerID($0.phoneID) && $0.grantedBy.map(phoneIDs.contains) == true }
            tidy = tidy || stored == nil || passes.count != stored?.count
            list += passes
        }
        if let data = secrets.read(Self.computerAccount) {
            // The same for computers: never taken for phones or passes, and only with their phone.
            let stored = try? JSONDecoder().decode([ShellPhone].self, from: data)
            let computers = (stored ?? []).filter { Self.isUsableComputer($0, phones: phoneIDs) }
            tidy = tidy || stored == nil || computers.count != stored?.count
            list += computers
        }
        lock.lock()
        if tidy { needsTidy = true }
        let revoked = unsavedRevokes, screenOff = unsavedScreenOff, controlOff = unsavedControlOff, shareOff = unsavedShareOff
        lock.unlock()
        list.removeAll { revoked.contains($0.phoneID) }
        for index in list.indices where screenOff.contains(list[index].phoneID) { list[index].screen = false }
        for index in list.indices where controlOff.contains(list[index].phoneID) { list[index].control = false }
        for index in list.indices where shareOff.contains(list[index].phoneID) { list[index].share = false }
        return list
    }
}
#endif
