import Foundation
import Darwin

/// Tells a live VPN session from a dead one without mistaking an idle one for
/// dead. OpenVPN's own ping-restart can't: its pings are one-way, so an idle
/// session hears from a NordVPN server only once a minute and a timeout short
/// enough to catch a real failure fires on every quiet spell. Instead, while
/// anything arrives from the server the session is alive; after a quiet spell
/// a one-question DNS probe goes through the VPN interface to every resolver
/// at once, and a session none of them answers three times in a row is
/// restarted, about 40 s after it died.
/// A single resolver is not enough: NordVPN's stall for seconds at a time, and
/// judging by them alone restarted healthy sessions every 33 s.
final class VPNLiveness {
    private let queue: DispatchQueue
    private let probeQueue = DispatchQueue(label: "\(HelperConstants.identifier).vpn.probe")
    private var timer: DispatchSourceTimer?
    private var lastRx = -1
    private var misses = 0
    private var probing = false
    /// Called on `queue` when the session should be restarted.
    var onDead: (() -> Void)?

    static let interval: TimeInterval = 10
    static let allowedMisses = 3

    init(queue: DispatchQueue) { self.queue = queue }

    /// `rx` reads the bytes received from the server so far; `describe` sums up
    /// the engine's counters for the log when the session goes quiet.
    func start(interface: String, dnsServers: [String], rx: @escaping () -> Int, describe: @escaping () -> String = { "" }) {
        stop()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.interval, repeating: Self.interval)
        timer.setEventHandler { [weak self] in self?.check(interface: interface, dnsServers: dnsServers, rx: rx(), describe: describe) }
        timer.resume()
        self.timer = timer
    }

    func stop() {
        timer?.cancel(); timer = nil
        lastRx = -1; misses = 0; probing = false
    }

    private func check(interface: String, dnsServers: [String], rx: Int, describe: () -> String) {
        if rx != lastRx { lastRx = rx; misses = 0; return }
        guard !probing else { return }
        HelperLog.info("vpn: nothing from the server for \(Int(Self.interval)) s (\(describe())); probing")
        probing = true
        probeQueue.async { [weak self] in
            let answered = Self.probe(dnsServers: dnsServers, interface: interface)
            self?.queue.async {
                guard let self, self.timer != nil else { return }
                self.probing = false
                if answered { self.misses = 0; return }
                self.misses += 1
                if self.misses >= Self.allowedMisses {
                    HelperLog.warn("vpn: nothing from the server and \(self.misses) probes to \(dnsServers.joined(separator: ", ")) unanswered; restarting the session")
                    self.stop()
                    self.onDead?()
                }
            }
        }
    }

    /// One DNS question (A for the root) to each of `dnsServers` from one socket
    /// bound to `interface`; true if any reply with the same ID arrives within 3 s.
    static func probe(dnsServers: [String], interface: String, timeout: Int = 3) -> Bool {
        let targets: [sockaddr_in] = dnsServers.compactMap { server in
            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = in_port_t(53).bigEndian
            return inet_pton(AF_INET, server, &addr.sin_addr) == 1 ? addr : nil
        }
        guard !targets.isEmpty else { return true }   // no IPv4 resolver: don't judge
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return true }
        defer { close(fd) }
        var index = if_nametoindex(interface)
        guard index != 0, setsockopt(fd, IPPROTO_IP, IP_BOUND_IF, &index, socklen_t(MemoryLayout<UInt32>.size)) == 0 else { return true }
        var tv = timeval(tv_sec: timeout, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        let id = UInt16.random(in: 1...UInt16.max)
        // Header: id, RD flag, 1 question; question: root name, type A, class IN.
        let query: [UInt8] = [UInt8(id >> 8), UInt8(id & 0xFF), 0x01, 0x00, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 1]
        var sentAny = false
        for var addr in targets {
            let sent = withUnsafePointer(to: &addr) { p in
                p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(fd, query, query.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
            if sent == query.count { sentAny = true }
        }
        guard sentAny else { return false }
        var reply = [UInt8](repeating: 0, count: 512)
        let deadline = Date().addingTimeInterval(TimeInterval(timeout))
        while Date() < deadline {
            let n = recv(fd, &reply, reply.count, 0)
            if n < 0 { return false }
            if n >= 2, reply[0] == UInt8(id >> 8), reply[1] == UInt8(id & 0xFF) { return true }
        }
        return false
    }
}
