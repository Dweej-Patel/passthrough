import Foundation
import SystemConfiguration

/// Events an engine runner reports back to the orchestrator (on its queue).
enum VPNRunnerEvent {
    /// The tunnel interface exists and the session is established.
    case connected(interface: String, address: String?, gateway: String?, dns: [String], mtu: Int?)
    /// The engine lost its session and is retrying by itself (interface kept).
    case reconnecting(String)
    /// The engine process ended. `fatal` carries a reason no retry can fix.
    case exited(fatal: String?)
    case log(String)
}

/// A bundled engine process (WireGuard or OpenVPN) driven by `VPNEngine`.
protocol VPNRunner: AnyObject {
    var onEvent: ((VPNRunnerEvent) -> Void)? { get set }
    /// Hosts/ports the engine will talk to; routed through the underlay before start.
    var endpoints: [(host: String, port: Int)] { get }
    /// host → first resolved IP, filled in by the orchestrator before `start()`.
    var endpointIPs: [String: String] { get set }
    /// Configures the interface once the runner reports it exists (address, mtu…).
    func start() throws
    func stop()
    /// (rxBytes, txBytes, secondsSinceLastHandshake)
    func stats() -> (Int, Int, Int?)
}

/// Runs a VPN engine "on top" of whatever network is current — the passthrough
/// tunnel when it is up, otherwise the Mac's default route — so every byte the
/// carrier sees is one encrypted flow to the VPN server.
///
/// Routing: the VPN owns 0.0.0.0/2 ×4 (and ::/2 ×4) routes into its interface.
/// Those beat the passthrough's /1 routes (longest prefix) without touching them,
/// and a /32 host route per VPN endpoint keeps the encrypted flow itself on the
/// underlay. With the kill switch on, the /2 routes become reject routes while
/// the VPN is down, so nothing ever falls back to the bare underlay.
final class VPNEngine {
    struct Config {
        enum Engine: String { case wireguard, openvpn }
        var engine: Engine
        var name: String
        var configText: String
        var username = ""
        var password = ""
        var killSwitch = true
        /// Reject IPv6 while the VPN is up if the VPN can't carry it (else it leaks to the underlay).
        var blockIPv6 = true
        var fallbackDNS = ["1.1.1.1", "1.0.0.1"]
    }

    enum State: String { case off, starting, connected, reconnecting, blocked, failed }

    enum VPNError: LocalizedError {
        case noUnderlay
        case badConfig(String)
        case unresolvable(String)
        var errorDescription: String? {
            switch self {
            case .noUnderlay: return "No network to run the VPN over. Connect passthrough or Wi-Fi first."
            case .badConfig(let why): return "The VPN config could not be read: \(why)"
            case .unresolvable(let host): return "Could not resolve the VPN server \(host)."
            }
        }
    }

    struct Underlay {
        var interface: String
        var gateway: String?
        var isPassthrough: Bool
    }

    private static let serviceID = "dev.dpatel.passthrough.vpn"
    private static let v4Quarters = ["0.0.0.0/2", "64.0.0.0/2", "128.0.0.0/2", "192.0.0.0/2"]
    private static let v6Quarters = ["::/2", "4000::/2", "8000::/2", "c000::/2"]

    private let queue: DispatchQueue
    private unowned let tunnel: TunnelEngine
    private var config: Config?
    private var runner: VPNRunner?
    private(set) var state: State = .off
    private var lastError: String?
    private var interfaceName: String?
    private var underlay: Underlay?
    private var endpointRoutes: [(ip: String, viaInterface: String?, viaGateway: String?)] = []
    private var quarterRoutesOn: String?
    private var rejectRoutesInstalled = false
    private var startedAt: Date?
    private var activeDNS: [String] = []
    private var publishedKeys: [String] = []
    private var retryTimer: DispatchSourceTimer?
    private var deadlineTimer: DispatchSourceTimer?
    private var retryAttempt = 0
    private var generation = 0
    /// Last good resolution per host, so reconnects under the kill switch need no DNS.
    private var resolvedCache: [String: [String]] = [:]
    private lazy var store: SCDynamicStore? = SCDynamicStoreCreate(nil, "PassthroughVPN" as CFString, nil, nil)
    /// How long a fresh session may sit in `starting` before it's treated as failed.
    private static let connectDeadline: TimeInterval = 60

    init(queue: DispatchQueue, tunnel: TunnelEngine) {
        self.queue = queue
        self.tunnel = tunnel
    }

    var isActive: Bool { config != nil }

    // MARK: Public API (call on `queue`)

    func start(_ config: Config) throws {
        if self.config != nil { stop() }
        self.config = config
        lastError = nil
        retryAttempt = 0
        try BundledEngines.prepareStateDirectory()
        try launch()
    }

    func stop() {
        guard config != nil else { return }
        HelperLog.info("vpn: stopping")
        generation += 1
        retryTimer?.cancel(); retryTimer = nil
        deadlineTimer?.cancel(); deadlineTimer = nil
        runner?.onEvent = nil
        runner?.stop()
        runner = nil
        removeQuarterRoutes()
        removeRejectRoutes()
        removeEndpointRoutes()
        clearDNS()
        config = nil
        state = .off
        interfaceName = nil
        startedAt = nil
        underlay = nil
    }

    /// The passthrough tunnel came up or went down: the encrypted flow has to
    /// move to the new underlay, which means a fresh session.
    func underlayChanged() {
        guard let config, state != .off else { return }
        HelperLog.info("vpn: underlay changed; restarting \(config.engine.rawValue)")
        restart(after: 0.5)
    }

    func status() -> [String: Any] {
        var dict: [String: Any] = [VPNStatusKey.state: state.rawValue]
        guard let config else { return dict }
        dict[VPNStatusKey.engine] = config.engine.rawValue
        dict[VPNStatusKey.name] = config.name
        if let interfaceName { dict[VPNStatusKey.interface] = interfaceName }
        if let startedAt { dict[VPNStatusKey.since] = startedAt.timeIntervalSince1970 }
        if let lastError { dict[VPNStatusKey.error] = lastError }
        if let underlay { dict[VPNStatusKey.underlay] = underlay.isPassthrough ? "iPhone" : underlay.interface }
        if !activeDNS.isEmpty { dict[VPNStatusKey.dns] = activeDNS }
        if let first = endpointRoutes.first { dict[VPNStatusKey.endpoint] = first.ip }
        if let runner, state == .connected || state == .reconnecting {
            let (rx, tx, handshake) = runner.stats()
            dict[VPNStatusKey.rxBytes] = rx
            dict[VPNStatusKey.txBytes] = tx
            if let handshake { dict[VPNStatusKey.handshakeAge] = handshake }
        }
        return dict
    }

    // MARK: Lifecycle

    private func launch() throws {
        guard let config else { return }
        generation += 1
        let gen = generation
        state = .starting
        interfaceName = nil

        var runner: VPNRunner
        switch config.engine {
        case .wireguard: runner = try WireGuardRunner(configText: config.configText, queue: queue)
        case .openvpn: runner = try OpenVPNRunner(configText: config.configText, username: config.username, password: config.password, queue: queue)
        }

        guard let underlay = detectUnderlay() else { throw VPNError.noUnderlay }
        self.underlay = underlay
        runner.endpointIPs = try installEndpointRoutes(for: runner.endpoints, underlay: underlay)
        if config.killSwitch { installRejectRoutes() }

        runner.onEvent = { [weak self] event in
            guard let self, self.generation == gen else { return }
            self.handle(event)
        }
        self.runner = runner
        try runner.start()
        // An engine that never reports connected (server unreachable, UDP
        // blocked) must not leave the kill switch engaged forever.
        deadlineTimer?.cancel()
        let deadline = DispatchSource.makeTimerSource(queue: queue)
        deadline.schedule(deadline: .now() + Self.connectDeadline)
        deadline.setEventHandler { [weak self] in
            guard let self, self.generation == gen, self.state == .starting else { return }
            HelperLog.warn("vpn: no session after \(Int(Self.connectDeadline))s; restarting")
            self.runner?.onEvent = nil
            self.runner?.stop()
            self.runner = nil
            self.handle(.exited(fatal: nil))
        }
        deadline.resume()
        deadlineTimer = deadline
        HelperLog.info("vpn: \(config.engine.rawValue) starting over \(underlay.isPassthrough ? "the iPhone" : underlay.interface)")
    }

    private func handle(_ event: VPNRunnerEvent) {
        guard let config else { return }
        switch event {
        case .log(let line):
            HelperLog.info("vpn[\(config.engine.rawValue)]: \(line)")
        case .connected(let iface, let address, let gateway, let dns, _):
            deadlineTimer?.cancel(); deadlineTimer = nil
            interfaceName = iface
            if startedAt == nil { startedAt = Date() }
            retryAttempt = 0
            lastError = nil
            removeRejectRoutes()
            installQuarterRoutes(on: iface)
            applyDNS(dns.isEmpty ? config.fallbackDNS : dns, interface: iface, address: address, gateway: gateway)
            state = .connected
            HelperLog.info("vpn: connected on \(iface) (dns \(activeDNS.joined(separator: ", ")))")
        case .reconnecting(let why):
            HelperLog.warn("vpn: session lost (\(why)); engine is reconnecting")
            state = .reconnecting
        case .exited(let fatal):
            deadlineTimer?.cancel(); deadlineTimer = nil
            runner?.onEvent = nil
            runner = nil
            removeQuarterRoutes()
            if let fatal {
                // Nothing a retry can fix: don't keep the Mac blackholed.
                removeRejectRoutes()
                lastError = fatal
                state = .failed
                HelperLog.error("vpn: \(fatal)")
                removeEndpointRoutes()
                clearDNS()
                return
            }
            if config.killSwitch { installRejectRoutes() }
            retryAttempt += 1
            let delay = min(30.0, pow(2.0, Double(min(retryAttempt, 5))))
            lastError = "The VPN engine stopped; reconnecting in \(Int(delay))s"
            state = config.killSwitch ? .blocked : .reconnecting
            HelperLog.warn("vpn: engine exited; retry #\(retryAttempt) in \(Int(delay))s")
            restart(after: delay)
        }
    }

    private func restart(after delay: TimeInterval) {
        retryTimer?.cancel()
        deadlineTimer?.cancel(); deadlineTimer = nil
        runner?.onEvent = nil
        runner?.stop()
        runner = nil
        removeQuarterRoutes()
        removeEndpointRoutes()
        clearDNS()
        if config?.killSwitch == true { installRejectRoutes() }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + delay)
        timer.setEventHandler { [weak self] in
            guard let self, self.config != nil else { return }
            self.retryTimer = nil
            do { try self.launch() } catch {
                self.lastError = error.localizedDescription
                self.state = self.config?.killSwitch == true ? .blocked : .reconnecting
                HelperLog.warn("vpn: relaunch failed: \(error.localizedDescription)")
                self.retryAttempt += 1
                self.restart(after: min(30, 2 * Double(self.retryAttempt)))
            }
        }
        timer.resume()
        retryTimer = timer
    }

    // MARK: Underlay + endpoint routes

    private func detectUnderlay() -> Underlay? {
        if tunnel.isRunning, let name = tunnel.interfaceName {
            return Underlay(interface: name, gateway: tunnel.ipv4Gateway, isPassthrough: true)
        }
        // Ask the kernel for the default route while our /2 routes are absent.
        let output = Shell.capture("/sbin/route", ["-n", "get", "default"])
        var gateway: String?, interface: String?
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else { continue }
            if parts[0] == "gateway" { gateway = parts[1] }
            if parts[0] == "interface" { interface = parts[1] }
        }
        guard let interface, !interface.isEmpty, !interface.hasPrefix("lo") else { return nil }
        if let g = gateway, g.hasPrefix("link#") || g.contains("utun") { gateway = nil }
        return Underlay(interface: interface, gateway: gateway, isPassthrough: false)
    }

    /// Pins each endpoint through the underlay; returns host → first IP.
    @discardableResult
    private func installEndpointRoutes(for endpoints: [(host: String, port: Int)], underlay: Underlay) throws -> [String: String] {
        removeEndpointRoutes()
        var ips: [String] = []
        var byHost: [String: String] = [:]
        for endpoint in endpoints {
            let literal = endpoint.host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            var resolved = Shell.resolve(literal)
            if resolved.isEmpty, let cached = resolvedCache[literal] {
                resolved = cached   // kill switch up: reuse the last good answer, no DNS needed
            }
            guard !resolved.isEmpty else { throw VPNError.unresolvable(endpoint.host) }
            resolvedCache[literal] = resolved
            byHost[endpoint.host] = resolved[0]
            for ip in resolved where !ips.contains(ip) { ips.append(ip) }
        }
        for ip in ips {
            let family = Shell.isIPv6(ip) ? "-inet6" : "-inet"
            _ = try? Shell.run("/sbin/route", ["-q", "-n", "delete", family, "-host", ip], quiet: true)
            if let gw = underlay.gateway, !underlay.isPassthrough, Shell.isIPv6(ip) == Shell.isIPv6(gw) {
                try Shell.run("/sbin/route", ["-q", "-n", "add", family, "-host", ip, gw])
                endpointRoutes.append((ip, nil, gw))
            } else {
                try Shell.run("/sbin/route", ["-q", "-n", "add", family, "-host", ip, "-interface", underlay.interface])
                endpointRoutes.append((ip, underlay.interface, nil))
            }
        }
        return byHost
    }

    private func removeEndpointRoutes() {
        for r in endpointRoutes {
            let family = Shell.isIPv6(r.ip) ? "-inet6" : "-inet"
            _ = try? Shell.run("/sbin/route", ["-q", "-n", "delete", family, "-host", r.ip], quiet: true)
        }
        endpointRoutes = []
    }

    // MARK: /2 routes + kill switch

    private func installQuarterRoutes(on iface: String) {
        if quarterRoutesOn == iface { return }
        removeQuarterRoutes()
        for q in Self.v4Quarters {
            do { try Shell.run("/sbin/route", ["-q", "-n", "add", "-inet", q, "-interface", iface]) }
            catch { HelperLog.warn("vpn: route \(q) → \(iface) failed: \(error.localizedDescription)") }
        }
        // IPv6: most VPN servers (NordVPN included) hand out no IPv6, and the
        // kernel refuses a v6 route through an interface with no v6 address. In
        // that case reject v6 outright so it can never fall back to the underlay;
        // apps fall through to IPv4 immediately (Happy Eyeballs).
        let hasV6 = Shell.capture("/sbin/ifconfig", [iface]).contains("inet6 ")
        var v6Rejected = false, v6Open = false
        for q in Self.v6Quarters {
            if hasV6, (try? Shell.run("/sbin/route", ["-q", "-n", "add", "-inet6", q, "-interface", iface], quiet: true)) != nil { continue }
            if config?.blockIPv6 ?? true {
                _ = try? Shell.run("/sbin/route", ["-q", "-n", "add", "-inet6", q, "::1", "-reject"], quiet: true)
                v6Rejected = true
            } else {
                v6Open = true
            }
        }
        if v6Rejected { HelperLog.info("vpn: \(iface) carries no IPv6; IPv6 is blocked while the VPN is on") }
        if v6Open { HelperLog.warn("vpn: \(iface) carries no IPv6 and IPv6 blocking is off; IPv6 traffic bypasses the VPN") }
        quarterRoutesOn = iface
    }

    private func removeQuarterRoutes() {
        guard quarterRoutesOn != nil else { return }
        for q in Self.v4Quarters { _ = try? Shell.run("/sbin/route", ["-q", "-n", "delete", "-inet", q], quiet: true) }
        for q in Self.v6Quarters { _ = try? Shell.run("/sbin/route", ["-q", "-n", "delete", "-inet6", q], quiet: true) }
        quarterRoutesOn = nil
    }

    /// While the VPN is down, send everything (except the endpoint host routes)
    /// into a reject route so nothing leaks onto the underlay.
    private func installRejectRoutes() {
        guard !rejectRoutesInstalled else { return }
        removeQuarterRoutes()
        for q in Self.v4Quarters {
            _ = try? Shell.run("/sbin/route", ["-q", "-n", "delete", "-inet", q], quiet: true)
            _ = try? Shell.run("/sbin/route", ["-q", "-n", "add", "-inet", q, "127.0.0.1", "-reject"])
        }
        for q in Self.v6Quarters {
            _ = try? Shell.run("/sbin/route", ["-q", "-n", "delete", "-inet6", q], quiet: true)
            _ = try? Shell.run("/sbin/route", ["-q", "-n", "add", "-inet6", q, "::1", "-reject"])
        }
        rejectRoutesInstalled = true
        HelperLog.info("vpn: kill switch engaged (traffic blocked until the VPN is back)")
    }

    private func removeRejectRoutes() {
        guard rejectRoutesInstalled else { return }
        for q in Self.v4Quarters { _ = try? Shell.run("/sbin/route", ["-q", "-n", "delete", "-inet", q], quiet: true) }
        for q in Self.v6Quarters { _ = try? Shell.run("/sbin/route", ["-q", "-n", "delete", "-inet6", q], quiet: true) }
        rejectRoutesInstalled = false
    }

    // MARK: Network service (default route + DNS)

    /// Publishes the VPN interface as the first-ranked network service so it
    /// owns the system default route and DNS. Over the passthrough this also
    /// demotes the passthrough service: clients that bind to the default-route
    /// interface (Tailscale does) must land on the VPN, not the bare underlay.
    private func applyDNS(_ servers: [String], interface: String, address: String?, gateway: String?) {
        activeDNS = servers
        if underlay?.isPassthrough == true {
            tunnel.setDNSOverride(servers)
            tunnel.setPrimaryRank("Last")
        }
        guard let store else { return }
        let base = "State:/Network/Service/\(Self.serviceID)"
        var entries: [(String, [String: Any])] = [
            ("\(base)/DNS", [kSCPropNetDNSServerAddresses as String: servers]),
            (base, ["PrimaryRank": "First", kSCPropUserDefinedName as String: "Passthrough VPN"]),
        ]
        if let address, let gateway {
            entries.append(("\(base)/IPv4", [
                kSCPropNetIPv4Addresses as String: [address],
                kSCPropNetIPv4DestAddresses as String: [gateway],
                kSCPropNetIPv4Router as String: gateway,
                kSCPropInterfaceName as String: interface,
                "PrimaryRank": "First",
            ]))
        }
        publishedKeys = []
        for (key, value) in entries where SCDynamicStoreAddTemporaryValue(store, key as CFString, value as CFDictionary) || SCDynamicStoreSetValue(store, key as CFString, value as CFDictionary) {
            publishedKeys.append(key)
        }
    }

    private func clearDNS() {
        activeDNS = []
        tunnel.setDNSOverride(nil)
        tunnel.setPrimaryRank("First")
        guard !publishedKeys.isEmpty, let store else { return }
        for key in publishedKeys { SCDynamicStoreRemoveValue(store, key as CFString) }
        publishedKeys = []
    }
}
