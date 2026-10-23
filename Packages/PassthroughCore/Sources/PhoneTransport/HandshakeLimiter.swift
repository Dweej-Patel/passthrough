import Foundation
import PassthroughCore
import Network

/// Slots for connections that have not proved anything yet, shared by the
/// wireless and shell listeners: anyone on the same network can connect, so a
/// stranger may hold a couple of handshakes, never all of them, and none for
/// longer than the handshake timeout. Confined to the listener's queue.
public final class HandshakeLimiter {
    /// Handshakes at once, in all and from one address.
    public static let maxHandshakes = 16
    public static let maxHandshakesPerHost = 2

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
    private let onLinkPrefixes: () -> Set<Data>
    private var pending = 0
    private var pendingByHost: [String: Int] = [:]

    /// `queue` is the listener's; the timeout fires on it. `onLinkPrefixes`
    /// are the /64s the Mac is on itself (first 8 bytes), whose peers are
    /// neighbours and are counted one address each.
    public init(queue: DispatchQueue, timeout: TimeInterval = WirelessLink.handshakeTimeout,
                maxTotal: Int = HandshakeLimiter.maxHandshakes, maxPerHost: Int = HandshakeLimiter.maxHandshakesPerHost,
                onLinkPrefixes: @escaping () -> Set<Data> = { [] }) {
        self.queue = queue
        self.timeout = timeout
        self.maxTotal = maxTotal
        self.maxPerHost = maxPerHost
        self.onLinkPrefixes = onLinkPrefixes
    }

    /// A slot for a handshake from `host`, or nil when it must be refused.
    /// `maxForHost` overrides the per-host cap for this bucket (relayed iroh
    /// attempts share one bucket with a larger cap). If the handshake has not
    /// released it within the timeout, the slot is freed and `onTimeout` runs
    /// (to drop the connection).
    public func acquire(host: String, maxForHost: Int? = nil, onTimeout: @escaping () -> Void) -> Slot? {
        let host = Self.bucket(host, onLinkPrefixes: onLinkPrefixes)
        guard pending < maxTotal, pendingByHost[host, default: 0] < (maxForHost ?? maxPerHost) else { return nil }
        pending += 1
        pendingByHost[host, default: 0] += 1
        let slot = Slot(limiter: self, host: host)
        queue.asyncAfter(deadline: .now() + timeout) {
            if slot.release() { onTimeout() }
        }
        return slot
    }

    /// What a peer is counted under: its address, except that a global IPv6
    /// peer from beyond the Mac's own links is counted by its /64, so rotating
    /// source addresses within one cannot multiply its share. Link-local, ULA
    /// and on-link peers are neighbours that share a /64 with every other
    /// phone (AWDL is all fe80::/64), so they keep one share per address.
    /// (A `%scope` suffix is ignored.)
    static func bucket(_ host: String, onLinkPrefixes: () -> Set<Data> = { [] }) -> String {
        let bare = host.split(separator: "%", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? host
        guard let v6 = IPv6Address(bare) else { return host }
        let raw = v6.rawValue
        let isGlobal = raw[raw.startIndex] & 0xE0 == 0x20
        let prefix = Data(raw.prefix(8))
        let bytes = isGlobal && !onLinkPrefixes().contains(prefix) ? prefix : raw
        return "v6/" + bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// Handshakes holding a slot now.
    public var count: Int { pending }

    private func free(_ host: String) {
        pending -= 1
        let left = (pendingByHost[host] ?? 1) - 1
        pendingByHost[host] = left > 0 ? left : nil
    }
}
