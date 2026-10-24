import Foundation
import PassthroughCore
import Network

/// Slots for connections that have not proved anything yet, shared by the
/// wireless and shell listeners: anyone on the same network can connect, so a
/// stranger may hold a couple of handshakes, never all of them, and none for
/// longer than the handshake timeout. A stranger with many addresses is
/// counted by network (`bucket`), and a few slots are kept for addresses that
/// proved themselves lately (`proven`, remembered across launches by a
/// `ProvenAddressStore`), so the owner's phones still get in while someone
/// holds every other slot. Confined to the listener's queue.
public final class HandshakeLimiter {
    /// Handshakes at once, in all and from one address (or network: `bucket`).
    public static let maxHandshakes = 16
    public static let maxHandshakesPerHost = 2
    /// Of `maxHandshakes`, how many only addresses that proved themselves
    /// within `provenFor` may take.
    public static let reservedForProven = 4
    public static let provenFor: TimeInterval = 30 * 24 * 3600
    /// Most proven addresses remembered; the longest unproven go first.
    static let provenLimit = 256

    /// One handshake's hold on a slot. Freed once, by whichever comes first:
    /// the handshake finishing or the timeout.
    public final class Slot {
        private weak var limiter: HandshakeLimiter?
        private let host: String
        public private(set) var isReleased = false

        fileprivate init(limiter: HandshakeLimiter, host: String) { self.limiter = limiter; self.host = host }

        /// Frees the slot; false if it was already freed (the timeout won).
        @discardableResult
        public func release() -> Bool {
            guard !isReleased else { return false }
            isReleased = true
            limiter?.free(host)
            return true
        }
    }

    /// How stale the stored date of an address proven again may get before it
    /// is written down anew (a new address is written at once), so a phone
    /// that reconnects all day does not rewrite the file every time.
    static let resaveInterval: TimeInterval = 3600

    private let queue: DispatchQueue
    private let timeout: TimeInterval
    private let maxTotal: Int
    private let maxPerHost: Int
    private let reserved: Int
    private let now: () -> Date
    private let store: ProvenAddressStore
    private var pending = 0
    private var pendingByHost: [String: Int] = [:]
    /// Bare addresses that proved themselves, and when they last did. Kept
    /// in `store` too, so after a relaunch the owner's phones still have
    /// their reserved slots while a neighbour holds the shared ones.
    private var provenAt: [String: Date] = [:]
    private var lastSaved = Date.distantPast

    /// `queue` is the listener's; the timeout fires on it. `store` keeps the
    /// proven addresses across launches (memory only by default); it is read
    /// once here. `now` is for tests.
    public init(queue: DispatchQueue, timeout: TimeInterval = WirelessLink.handshakeTimeout,
                maxTotal: Int = HandshakeLimiter.maxHandshakes, maxPerHost: Int = HandshakeLimiter.maxHandshakesPerHost,
                reservedForProven: Int = HandshakeLimiter.reservedForProven,
                store: ProvenAddressStore = MemoryProvenAddressStore(), now: @escaping () -> Date = Date.init) {
        self.queue = queue
        self.timeout = timeout
        self.maxTotal = maxTotal
        self.maxPerHost = maxPerHost
        self.reserved = min(reservedForProven, maxTotal)
        self.now = now
        self.store = store
        provenAt = Self.kept(store.load(), at: now())
    }

    /// `table` without expired entries or anything but addresses, and at
    /// most `provenLimit` of the newest. A date in the future (the clock was
    /// set back) counts as now, so it never outlasts `provenFor` from here.
    static func kept(_ table: [String: Date], at now: Date) -> [String: Date] {
        let valid = table.mapValues { min($0, now) }.filter { address, at in
            (IPv4Address(address) != nil || IPv6Address(address) != nil) && now.timeIntervalSince(at) < provenFor
        }
        guard valid.count > provenLimit else { return valid }
        return Dictionary(uniqueKeysWithValues: valid.sorted { $0.value > $1.value }.prefix(provenLimit).map { ($0.key, $0.value) })
    }

    /// A slot for a handshake from `host`, or nil when it must be refused.
    /// `maxForHost` overrides the per-host cap for this bucket (relayed iroh
    /// attempts share one bucket with a larger cap). An address that proved
    /// itself lately is counted on its own, not in its network's bucket, and
    /// may also take the reserved slots. If the handshake has not released
    /// it within the timeout, the slot is freed and `onTimeout` runs (to drop
    /// the connection).
    public func acquire(host: String, maxForHost: Int? = nil, onTimeout: @escaping () -> Void) -> Slot? {
        let trusted = isProven(host)
        let key = trusted ? "proven/" + Self.bare(host) : Self.bucket(host)
        let limit = trusted ? maxTotal : maxTotal - reserved
        guard pending < limit, pendingByHost[key, default: 0] < (maxForHost ?? maxPerHost) else { return nil }
        pending += 1
        pendingByHost[key, default: 0] += 1
        let slot = Slot(limiter: self, host: key)
        queue.asyncAfter(deadline: .now() + timeout) {
            if slot.release() { onTimeout() }
        }
        return slot
    }

    /// A handshake from `host` proved itself: for `provenFor` it is counted
    /// on its own and may use the reserved slots. Only IP addresses are
    /// remembered, never a shared bucket such as relayed iroh attempts'.
    public func proven(_ host: String) {
        let bare = Self.bare(host)
        guard IPv4Address(bare) != nil || IPv6Address(bare) != nil else { return }
        let now = now()
        let isNew = provenAt.updateValue(now, forKey: bare) == nil
        if provenAt.count > Self.provenLimit, let oldest = provenAt.min(by: { $0.value < $1.value })?.key {
            provenAt[oldest] = nil
        }
        // Expired entries go with the write (`kept`); they are dropped on reading too.
        guard isNew || now.timeIntervalSince(lastSaved) >= Self.resaveInterval else { return }
        provenAt = Self.kept(provenAt, at: now)
        lastSaved = now
        store.save(provenAt)
    }

    func isProven(_ host: String) -> Bool {
        let bare = Self.bare(host)
        guard let at = provenAt[bare] else { return false }
        if now().timeIntervalSince(at) < Self.provenFor { return true }
        provenAt[bare] = nil
        return false
    }

    /// What a peer is counted under, so taking many addresses in one network
    /// does not multiply a stranger's share: a public IPv4 peer by its /24,
    /// and a ULA or global IPv6 peer by its /64. A private, loopback,
    /// link-local or shared-space IPv4 peer (a LAN, Tailscale) is counted by
    /// its own address, as DHCP hands those out one per device, and so is a
    /// link-local IPv6 one (fe80::/10): every neighbour over AWDL or on the
    /// LAN shares fe80::/64, so one chatty neighbour would otherwise hold the
    /// owner's phones' share too. A `%scope` suffix is ignored.
    static func bucket(_ host: String) -> String {
        let bare = bare(host)
        if let v4 = IPv4Address(bare) {
            let b = [UInt8](v4.rawValue)
            let ownAddress = b[0] == 10 || b[0] == 127 || (b[0] == 172 && (16...31).contains(b[1]))
                || (b[0] == 192 && b[1] == 168) || (b[0] == 169 && b[1] == 254) || (b[0] == 100 && (64...127).contains(b[1]))
            return ownAddress ? "v4/" + bare : "v4/\(b[0]).\(b[1]).\(b[2]).0/24"
        }
        guard let v6 = IPv6Address(bare) else { return host }
        let raw = [UInt8](v6.rawValue)
        let linkLocal = raw[0] == 0xFE && raw[1] & 0xC0 == 0x80
        return "v6/" + raw.prefix(linkLocal ? 16 : 8).map { String(format: "%02x", $0) }.joined()
    }

    private static func bare(_ host: String) -> String {
        host.split(separator: "%", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? host
    }

    /// Handshakes holding a slot now.
    public var count: Int { pending }

    private func free(_ host: String) {
        pending -= 1
        let left = (pendingByHost[host] ?? 1) - 1
        pendingByHost[host] = left > 0 ? left : nil
    }
}

/// Where a `HandshakeLimiter` keeps the addresses that proved themselves
/// (bare address → when it last did). Give each listener its own: each
/// limiter writes its whole table. Called on the listener's queue, so
/// neither call may block for long.
public protocol ProvenAddressStore: AnyObject, Sendable {
    func load() -> [String: Date]
    func save(_ proven: [String: Date])
}

/// Forgotten when the app quits (tests, and listeners nothing is kept for).
public final class MemoryProvenAddressStore: ProvenAddressStore {
    private let table: Locked<[String: Date]>

    public init(_ table: [String: Date] = [:]) { self.table = Locked(table) }

    public func load() -> [String: Date] { table.get() }
    public func save(_ proven: [String: Date]) { table.set(proven) }
}

/// A small JSON file (address → Unix seconds), written whole, atomically and
/// 0600 in a 0700 folder, off the caller's queue. A missing or unreadable
/// file is an empty table: the phones prove themselves through the shared slots once more.
public final class FileProvenAddressStore: ProvenAddressStore, @unchecked Sendable {
    private let url: URL
    /// Writes, in order; `load` waits for any still queued.
    private let writes = DispatchQueue(label: "\(PassthroughProtocol.identifier).proven-addresses", qos: .utility)

    public init(url: URL) { self.url = url }

    /// `<name>.json` in the app's Application Support folder.
    public static func inApplicationSupport(named name: String) -> FileProvenAddressStore {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return FileProvenAddressStore(url: support
            .appendingPathComponent(PassthroughProtocol.identifier, isDirectory: true)
            .appendingPathComponent("\(name).json"))
    }

    public func load() -> [String: Date] {
        writes.sync {}
        guard let data = try? Data(contentsOf: url),
              let seconds = try? JSONDecoder().decode([String: Double].self, from: data) else { return [:] }
        return seconds.mapValues { Date(timeIntervalSince1970: $0) }
    }

    public func save(_ proven: [String: Date]) {
        let seconds = proven.mapValues(\.timeIntervalSince1970)
        writes.async { [url] in
            do {
                try Self.write(JSONEncoder().encode(seconds), to: url)
            } catch {
                ptLog(.warning, "handshakes: could not keep the proven addresses: \(error.localizedDescription)")
            }
        }
    }

    /// A 0600 file beside `url`, renamed over it.
    private static func write(_ data: Data, to url: URL) throws {
        let folder = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let temporary = folder.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString)")
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: data)
            try handle.close()
            guard rename(temporary.path, url.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }
}
