import Foundation
import PassthroughCore
import Network

/// Slots for connections that have not proved anything yet, shared by the
/// wireless and shell listeners: anyone on the same network can connect, so a
/// stranger may hold a couple of handshakes, never all of them, and none for
/// longer than the handshake timeout. A stranger with many addresses is
/// counted by network (`bucket`), and a few slots are kept for addresses that
/// proved themselves lately (`proven`), so the owner's phones still get in
/// while someone holds every other slot. Confined to the listener's queue.
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

    private let queue: DispatchQueue
    private let timeout: TimeInterval
    private let maxTotal: Int
    private let maxPerHost: Int
    private let reserved: Int
    private let now: () -> Date
    private var pending = 0
    private var pendingByHost: [String: Int] = [:]
    /// Bare addresses that proved themselves, and when they last did. In
    /// memory only: after a relaunch each phone proves itself once more
    /// through the shared slots.
    private var provenAt: [String: Date] = [:]

    /// `queue` is the listener's; the timeout fires on it. `now` is for tests.
    public init(queue: DispatchQueue, timeout: TimeInterval = WirelessLink.handshakeTimeout,
                maxTotal: Int = HandshakeLimiter.maxHandshakes, maxPerHost: Int = HandshakeLimiter.maxHandshakesPerHost,
                reservedForProven: Int = HandshakeLimiter.reservedForProven, now: @escaping () -> Date = Date.init) {
        self.queue = queue
        self.timeout = timeout
        self.maxTotal = maxTotal
        self.maxPerHost = maxPerHost
        self.reserved = min(reservedForProven, maxTotal)
        self.now = now
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
        provenAt[bare] = now()
        if provenAt.count > Self.provenLimit, let oldest = provenAt.min(by: { $0.value < $1.value })?.key {
            provenAt[oldest] = nil
        }
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
    /// and every IPv6 peer (link-local, ULA or global) by its /64. A private,
    /// loopback, link-local or shared-space IPv4 peer (a LAN, Tailscale) is
    /// counted by its own address, as DHCP hands those out one per device.
    /// Neighbours over AWDL or one IPv6 LAN share their /64: the owner's
    /// phones get past that once proven (`proven`). A `%scope` suffix is ignored.
    static func bucket(_ host: String) -> String {
        let bare = bare(host)
        if let v4 = IPv4Address(bare) {
            let b = [UInt8](v4.rawValue)
            let ownAddress = b[0] == 10 || b[0] == 127 || (b[0] == 172 && (16...31).contains(b[1]))
                || (b[0] == 192 && b[1] == 168) || (b[0] == 169 && b[1] == 254) || (b[0] == 100 && (64...127).contains(b[1]))
            return ownAddress ? "v4/" + bare : "v4/\(b[0]).\(b[1]).\(b[2]).0/24"
        }
        guard let v6 = IPv6Address(bare) else { return host }
        return "v6/" + v6.rawValue.prefix(8).map { String(format: "%02x", $0) }.joined()
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
