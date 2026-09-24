import Foundation
import SystemConfiguration
import HevSocks5Tunnel

/// Owns the utun interface and the embedded tun2socks engine.
final class TunnelEngine {
    struct Config {
        var socksPort: UInt16 = 17890
        var username = ""
        var password = ""
        var ipv6 = true
        var dns = ["1.1.1.1", "1.0.0.1"]
        var mtu = 8500
        var ipv4Address = "10.7.0.2"
        var ipv4Gateway = "10.7.0.1"
        var ipv6Address = "fd00:7::2"
        var ipv6Gateway = "fd00:7::1"
    }

    enum EngineError: LocalizedError {
        case utunOpen(String)
        case command(String, Int32)
        case engineExited
        case alreadyRunning

        var errorDescription: String? {
            switch self {
            case .utunOpen(let why): return "Could not create the tunnel interface: \(why)"
            case .command(let cmd, let status): return "\(cmd) failed with status \(status)"
            case .engineExited: return "The tunnel engine exited unexpectedly"
            case .alreadyRunning: return "The tunnel is already running"
            }
        }
    }

    private static let serviceID = "dev.dpatel.passthrough.tunnel"
    private var fd: Int32 = -1
    private(set) var interfaceName: String?
    private var thread: Thread?
    private var exited = DispatchSemaphore(value: 0)
    /// Kept for the tunnel's lifetime: values are published as *temporary* so
    /// configd drops them by itself if this process dies.
    private lazy var store: SCDynamicStore? = SCDynamicStoreCreate(nil, "Passthrough" as CFString, nil, nil)
    private var config: Config?
    private var startedAt: Date?
    private var storeKeys: [String] = []
    private var keepaliveIf: String?
    private let alive = NSLock()
    private var engineAlive = false

    var isRunning: Bool { thread != nil && isEngineAlive }
    /// Set when the engine ignored a stop request. It still owns its utun and
    /// that utun's fixed addresses, so no new tunnel can start in this process.
    private(set) var isStuck = false
    /// IPv6 is rejected at the tunnel's routes because the phone's network has none.
    private(set) var ipv6Blocked = false
    static let ipv6Halves = ["::/1", "8000::/1"]
    var ipv4Gateway: String? { config?.ipv4Gateway }
    /// DNS servers the VPN layer wants used instead of the configured ones.
    private var dnsOverride: [String]?
    /// "First" normally; "Last" while the VPN layer is primary on top of us.
    private var primaryRank = "First"

    /// Demote/promote this service so a VPN layered on top can own the default
    /// route (clients like Tailscale bind to the default-route interface).
    func setPrimaryRank(_ rank: String) {
        guard primaryRank != rank else { return }
        primaryRank = rank
        guard isRunning, let config, let name = interfaceName, !storeKeys.isEmpty else { return }
        publishNetworkService(name: name, config: config)
    }

    /// Re-publishes the tunnel's DNS entry with the VPN's resolvers (or the
    /// configured ones when `servers` is nil). No-op while the tunnel is down.
    func setDNSOverride(_ servers: [String]?) {
        dnsOverride = servers
        guard isRunning, let config, storeKeys.contains("State:/Network/Service/\(Self.serviceID)/DNS"), let store else { return }
        let key = "State:/Network/Service/\(Self.serviceID)/DNS" as CFString
        let value = [kSCPropNetDNSServerAddresses as String: servers ?? config.dns] as CFDictionary
        if !SCDynamicStoreSetValue(store, key, value) {
            HelperLog.warn("failed to update DNS: \(String(cString: SCErrorString(SCError())))")
        }
    }
    private var isEngineAlive: Bool { alive.lock(); defer { alive.unlock() }; return engineAlive }
    private func setEngineAlive(_ v: Bool) { alive.lock(); engineAlive = v; alive.unlock() }

    // MARK: Start / stop

    func start(_ config: Config) throws {
        guard !isRunning else { throw EngineError.alreadyRunning }
        if thread != nil { stop() }
        self.config = config
        var limit = rlimit(rlim_cur: 65536, rlim_max: 65536)
        _ = setrlimit(RLIMIT_NOFILE, &limit)
        let (fd, name) = try Self.openUTun()
        self.fd = fd
        interfaceName = name
        HelperLog.info("created \(name)")

        try run("/sbin/ifconfig", [name, "inet", config.ipv4Address, config.ipv4Gateway, "mtu", "\(config.mtu)", "up"])
        if config.ipv6 {
            try run("/sbin/ifconfig", [name, "inet6", config.ipv6Address, config.ipv6Gateway, "prefixlen", "128"])
        }

        let yaml = Self.yaml(for: config)
        let bytes = Array(yaml.utf8)
        let tunFD = fd
        setEngineAlive(true)
        let exited = DispatchSemaphore(value: 0)
        self.exited = exited
        let thread = Thread { [exited, weak self] in
            let result = bytes.withUnsafeBufferPointer { buf in
                hev_socks5_tunnel_main_from_str(buf.baseAddress, UInt32(buf.count), tunFD)
            }
            HelperLog.info("engine exited with \(result)")
            self?.setEngineAlive(false)
            exited.signal()
        }
        thread.name = "tun2socks"
        thread.stackSize = 4 << 20
        self.thread = thread
        thread.start()
        if exited.wait(timeout: .now() + 0.6) == .success {
            self.thread = nil
            throw EngineError.engineExited
        }

        try run("/sbin/route", ["-q", "-n", "add", "-inet", "0.0.0.0/1", "-interface", name])
        try run("/sbin/route", ["-q", "-n", "add", "-inet", "128.0.0.0/1", "-interface", name])
        if config.ipv6 {
            try run("/sbin/route", ["-q", "-n", "add", "-inet6", "::/1", "-interface", name])
            try run("/sbin/route", ["-q", "-n", "add", "-inet6", "8000::/1", "-interface", name])
        }
        ipv6Blocked = false
        publishNetworkService(name: name, config: config)
        createKeepaliveInterface()
        startedAt = Date()
        HelperLog.info("tunnel up on \(name) → 127.0.0.1:\(config.socksPort)")
    }

    /// Follows the phone's network: without IPv6 there, the tunnel's IPv6
    /// routes become reject routes, so apps fall back to IPv4 at once instead of
    /// hanging on connections tun2socks accepts but the phone can never make.
    /// Each flip is one atomic `route change` per half.
    func setIPv6Available(_ available: Bool) {
        guard isRunning, let name = interfaceName, config?.ipv6 == true, available == ipv6Blocked else { return }
        for half in Self.ipv6Halves {
            let target = available ? ["-interface", name] : ["::1", "-reject"]
            if (try? run("/sbin/route", ["-q", "-n", "change", "-inet6", half] + target)) == nil {
                HelperLog.warn("route change \(half) failed")
            }
        }
        ipv6Blocked = !available
        HelperLog.info(available ? "phone's network routes IPv6 again; IPv6 goes through \(name)"
                                 : "phone's network has no IPv6; rejecting IPv6 so apps use IPv4 at once")
    }

    func stop() {
        guard fd >= 0 || isRunning else { return }
        HelperLog.info("stopping tunnel")
        retractNetworkService()
        destroyKeepaliveInterface()
        if let name = interfaceName {
            _ = try? run("/sbin/route", ["-q", "-n", "delete", "-inet", "0.0.0.0/1", "-interface", name])
            _ = try? run("/sbin/route", ["-q", "-n", "delete", "-inet", "128.0.0.0/1", "-interface", name])
            if ipv6Blocked {
                // Reject routes aren't tied to the utun, so they'd outlive it.
                for half in Self.ipv6Halves { RouteTable.deleteIfPresent(half, v6: true) }
                ipv6Blocked = false
            } else {
                _ = try? run("/sbin/route", ["-q", "-n", "delete", "-inet6", "::/1", "-interface", name])
                _ = try? run("/sbin/route", ["-q", "-n", "delete", "-inet6", "8000::/1", "-interface", name])
            }
        }
        var engineGone = true
        if thread != nil {
            if isEngineAlive {
                hev_socks5_tunnel_quit()
                if exited.wait(timeout: .now() + 8) != .success {
                    HelperLog.error("engine did not stop in time; leaving its descriptor open")
                    engineGone = false
                    isStuck = true
                }
            }
            thread = nil
        }
        // Never close the utun while the engine thread might still use it.
        if fd >= 0, engineGone { close(fd) }
        fd = -1
        interfaceName = nil
        startedAt = nil
        config = nil
    }

    func status() -> [String: Any] {
        var tx = 0, txb = 0, rx = 0, rxb = 0
        if isRunning { hev_socks5_tunnel_stats(&tx, &txb, &rx, &rxb) }
        var dict: [String: Any] = [
            TunnelStatusKey.running: isRunning,
            TunnelStatusKey.txPackets: tx,
            TunnelStatusKey.txBytes: txb,
            TunnelStatusKey.rxPackets: rx,
            TunnelStatusKey.rxBytes: rxb,
        ]
        if let interfaceName { dict[TunnelStatusKey.interface] = interfaceName }
        if let startedAt { dict[TunnelStatusKey.since] = startedAt.timeIntervalSince1970 }
        return dict
    }

    // MARK: utun

    private static func openUTun() throws -> (Int32, String) {
        let fd = socket(PF_SYSTEM, SOCK_DGRAM, SYSPROTO_CONTROL)
        guard fd >= 0 else { throw EngineError.utunOpen(String(cString: strerror(errno))) }
        var info = ctl_info()
        withUnsafeMutablePointer(to: &info.ctl_name) {
            $0.withMemoryRebound(to: CChar.self, capacity: 96) { _ = strlcpy($0, "com.apple.net.utun_control", 96) }
        }
        let CTLIOCGINFO: UInt = 0xC0644E03
        guard ioctl(fd, CTLIOCGINFO, &info) == 0 else {
            let why = String(cString: strerror(errno)); close(fd); throw EngineError.utunOpen("ioctl: \(why)")
        }
        var addr = sockaddr_ctl()
        addr.sc_len = UInt8(MemoryLayout<sockaddr_ctl>.size)
        addr.sc_family = UInt8(AF_SYSTEM)
        addr.ss_sysaddr = UInt16(AF_SYS_CONTROL)
        addr.sc_id = info.ctl_id
        addr.sc_unit = 0 // let the kernel pick the next free utunN
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_ctl>.size)) }
        }
        guard connected == 0 else {
            let why = String(cString: strerror(errno)); close(fd); throw EngineError.utunOpen("connect: \(why)")
        }
        var nameBuffer = [CChar](repeating: 0, count: Int(IFNAMSIZ))
        var length = socklen_t(nameBuffer.count)
        guard getsockopt(fd, SYSPROTO_CONTROL, 2 /* UTUN_OPT_IFNAME */, &nameBuffer, &length) == 0 else {
            let why = String(cString: strerror(errno)); close(fd); throw EngineError.utunOpen("ifname: \(why)")
        }
        return (fd, String(cString: nameBuffer))
    }

    // MARK: Engine config

    private static func yaml(for c: Config) -> String {
        var lines = [
            "tunnel:",
            "  name: \(c.ipv4Address)",
            "  mtu: \(c.mtu)",
            "  ipv4: \(c.ipv4Address)",
        ]
        if c.ipv6 { lines.append("  ipv6: '\(c.ipv6Address)'") }
        lines += [
            "socks5:",
            "  port: \(c.socksPort)",
            "  address: 127.0.0.1",
            "  udp: 'tcp'",
        ]
        if !c.username.isEmpty {
            // Quoted YAML scalars parsed by a root process: only plain
            // base64/uuid characters are accepted (enforced again in HelperService).
            let safe = { (s: String) in s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "+/=-_".contains($0)) } }
            precondition(safe(c.username) && safe(c.password), "credentials contain characters that are not allowed")
            lines.append("  username: '\(c.username)'")
            lines.append("  password: '\(c.password)'")
        }
        lines += [
            "misc:",
            "  log-file: stderr",
            "  log-level: warn",
            "  connect-timeout: 15000",
            "  tcp-read-write-timeout: 600000",
            "  udp-read-write-timeout: 120000",
            "  limit-nofile: 65535",
        ]
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: Routing helpers

    /// Runs a command and returns its trimmed stdout.
    private func runCapture(_ path: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Tailscale (and some other clients) ignore any interface whose name starts
    /// with "utun" when deciding whether the machine has a network at all. With
    /// only our tunnel present (e.g. laptop truly remote, Wi-Fi off) they would
    /// declare themselves offline. We create a dummy "fake ethernet" interface
    /// with a private address purely so that heuristic passes; no traffic is ever
    /// routed over it — real traffic still follows the default route into the tunnel.
    private func createKeepaliveInterface() {
        do {
            let name = try runCapture("/sbin/ifconfig", ["feth", "create"])
            guard name.hasPrefix("feth") else { HelperLog.warn("keepalive: unexpected name \(name)"); return }
            try run("/sbin/ifconfig", [name, "inet", "10.83.0.1", "netmask", "255.255.255.0", "up"])
            keepaliveIf = name
            HelperLog.info("keepalive interface \(name) up (satisfies VPN clients' network check)")
        } catch {
            HelperLog.warn("keepalive interface failed: \(error.localizedDescription)")
        }
    }

    private func destroyKeepaliveInterface() {
        guard let name = keepaliveIf else { return }
        _ = try? run("/sbin/ifconfig", [name, "destroy"])
        keepaliveIf = nil
    }

    @discardableResult
    private func run(_ path: String, _ arguments: [String]) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.standardError
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw EngineError.command(([path] + arguments).joined(separator: " "), process.terminationStatus)
        }
        return process.terminationStatus
    }

    /// Registers the utun as a first-ranked network service so macOS treats the
    /// Mac as online, elects it primary, and hands mDNSResponder our DNS servers.
    private func publishNetworkService(name: String, config: Config) {
        guard let store else {
            HelperLog.warn("SCDynamicStoreCreate failed; DNS may not resolve")
            return
        }
        let base = "State:/Network/Service/\(Self.serviceID)"
        var entries: [(String, [String: Any])] = [
            ("\(base)/IPv4", [
                kSCPropNetIPv4Addresses as String: [config.ipv4Address],
                kSCPropNetIPv4DestAddresses as String: [config.ipv4Gateway],
                kSCPropNetIPv4Router as String: config.ipv4Gateway,
                kSCPropInterfaceName as String: name,
                "PrimaryRank": primaryRank,
            ]),
            ("\(base)/DNS", [
                kSCPropNetDNSServerAddresses as String: dnsOverride ?? config.dns,
            ]),
            (base, [
                "PrimaryRank": primaryRank,
                kSCPropUserDefinedName as String: "Passthrough (iPhone USB)",
            ]),
        ]
        if config.ipv6 {
            entries.append(("\(base)/IPv6", [
                kSCPropNetIPv6Addresses as String: [config.ipv6Address],
                kSCPropNetIPv6PrefixLength as String: [128],
                kSCPropNetIPv6Router as String: config.ipv6Gateway,
                kSCPropInterfaceName as String: name,
                "PrimaryRank": primaryRank,
            ]))
        }
        storeKeys = []
        for (key, value) in entries {
            // Temporary first (auto-removed if we die); SetValue when it already exists.
            if SCDynamicStoreAddTemporaryValue(store, key as CFString, value as CFDictionary) || SCDynamicStoreSetValue(store, key as CFString, value as CFDictionary) {
                storeKeys.append(key)
            } else {
                HelperLog.warn("failed to set \(key): \(String(cString: SCErrorString(SCError())))")
            }
        }
    }

    private func retractNetworkService() {
        guard !storeKeys.isEmpty, let store else { return }
        for key in storeKeys { SCDynamicStoreRemoveValue(store, key as CFString) }
        storeKeys = []
    }
}
