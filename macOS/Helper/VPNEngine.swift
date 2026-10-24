import Foundation
import HelperLogic
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
/// underlay. With the kill switch on, /3 reject routes override the /2 routes
/// while the VPN is down, so nothing falls back to the bare underlay.
///
/// Routes win by prefix length only, so a network that pushes longer ones
/// (TunnelVision) would still get traffic past them; the kill switch's pf
/// rules (`PacketFilter`, `KillSwitchRules`) close that, connected or not:
/// out through the VPN, to the VPN server, to the phone over the wireless
/// link, or to the local network, else dropped. The kill switch outlives a
/// crash of the app or the helper (`KillSwitchStateStore`): only turning the
/// VPN off lifts it.
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
        /// The kill switch lets traffic to directly connected networks through.
        var allowLocalNetwork = true
        var fallbackDNS = ["1.1.1.1", "1.0.0.1"]
        /// Passthrough's wireless link, which the kill switch always lets
        /// through: the app's listener port and where the phone is now.
        /// `subnets` is filled in when the rules are made.
        var phoneLink: KillSwitchRules.PhoneLink?
    }

    /// `held`: no session and no app, but the kill switch still blocks (the
    /// app went away, or the helper restarted, with the VPN on).
    enum State: String { case off, starting, connected, reconnecting, blocked, failed, held }

    /// The kill switch's state files, in the root-only state directory.
    static let stateStore = KillSwitchStateStore(directory: BundledEngines.stateDirectory)

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

    private static let serviceID = "\(HelperConstants.identifier).vpn"
    private static let v4Quarters = ["0.0.0.0/2", "64.0.0.0/2", "128.0.0.0/2", "192.0.0.0/2"]
    private static let v6Quarters = ["::/2", "4000::/2", "8000::/2", "c000::/2"]
    /// The kill switch rejects at /3, one step more specific than the /2 VPN
    /// routes, so engaging and lifting it are plain adds and deletes: never a
    /// moment without a route (XNU ignores -reject on `route change`).
    static let v4Eighths = ["0.0.0.0/3", "32.0.0.0/3", "64.0.0.0/3", "96.0.0.0/3", "128.0.0.0/3", "160.0.0.0/3", "192.0.0.0/3", "224.0.0.0/3"]
    static let v6Eighths = ["::/3", "2000::/3", "4000::/3", "6000::/3", "8000::/3", "a000::/3", "c000::/3", "e000::/3"]

    private let queue: DispatchQueue
    private unowned let tunnel: TunnelEngine
    private var config: Config?
    private var runner: VPNRunner?
    private(set) var state: State = .off
    private var lastError: String?
    private var interfaceName: String?
    private var underlay: Underlay?
    private var endpointRoutes: [(ip: String, viaInterface: String?, viaGateway: String?)] = []
    /// The VPN servers' addresses and ports, for the packet filter.
    private var endpointPasses: [KillSwitchRules.Endpoint] = []
    private var quarterRoutesOn: String?
    /// IPv6 goes around the VPN by choice (Block IPv6 off, none in the VPN).
    private var ipv6Bypass = false
    private var rejectRoutesInstalled = false
    /// The packet filter rules last loaded, and why loading them failed.
    private var filterRules: String?
    private var filterError: String?
    /// The VPN interface the filter was last made for (nil while the VPN is down).
    private var filterInterface: String?
    /// Routes the network pushed around the VPN, last time it was looked at.
    private var foreignRoutes: [String] = []
    private var routeWatch: DispatchSourceTimer?
    /// The block was already up when this start began (a reconnect after a
    /// crash, or a switch of profile), so a failed start keeps it.
    private var heldBeforeStart = false
    private var startedAt: Date?
    private var activeDNS: [String] = []
    private var publishedKeys: [String] = []
    private lazy var liveness: VPNLiveness = {
        let l = VPNLiveness(queue: queue)
        l.onDead = { [weak self] in self?.restart(after: 0.5) }
        return l
    }()
    private lazy var underlayWatch = UnderlayWatch(queue: queue)
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
        resolvedCache = Self.stateStore.endpoints
        // A kill switch the recovery sweep kept: still blocking, no session.
        if Self.stateStore.isWanted {
            state = .held
            rejectRoutesInstalled = true
        }
    }

    var isActive: Bool { config != nil }

    // MARK: Public API (call on `queue`)

    func start(_ config: Config) throws {
        heldBeforeStart = state == .held || self.config?.killSwitch == true
        // A switch of profile keeps any block in place meanwhile.
        if self.config != nil { endSession() }
        self.config = config
        if config.killSwitch {
            try BundledEngines.prepareStateDirectory()
            try Self.stateStore.setWanted(.init(allowLocalNetwork: config.allowLocalNetwork))
        } else if heldBeforeStart {
            liftKillSwitch()
        }
        lastError = nil
        retryAttempt = 0
        try BundledEngines.prepareStateDirectory()
        try launch()
    }

    /// Turns the VPN layer off, the kill switch included: the user asked
    /// (also from `held`, with no session left to stop).
    func stop() {
        guard config != nil || state == .held || Self.stateStore.isWanted else { return }
        HelperLog.info("vpn: stopping")
        endSession()
        liftKillSwitch()
        resolvedCache = [:]
        config = nil
        state = .off
    }

    /// The app that started the VPN went away without turning it off (it
    /// crashed or was killed), or this helper is quitting: with the kill
    /// switch on, the session ends but the block stays, until the app
    /// reconnects the VPN or turns it off. Without it, a plain stop.
    func hold() {
        guard let config else { return }
        guard KillSwitchHold.appGone(killSwitch: config.killSwitch) == .hold else { return stop() }
        HelperLog.warn("vpn: the app went away with the VPN on; the kill switch keeps traffic blocked until the VPN reconnects or is turned off")
        endSession()
        state = .held
        // Its wireless listener went with it; reconnecting names the link again.
        self.config?.phoneLink = nil
        engageKillSwitch()
        self.config = nil
    }

    /// A start that threw: keeps a block that was already up (`hold`), else stops.
    func abandonStart() {
        switch KillSwitchHold.failedStart(wasHeld: heldBeforeStart) {
        case .hold: hold()
        case .lift: stop()
        }
    }

    /// Ends the session (engine, timers, VPN and endpoint routes, DNS) and
    /// leaves the kill switch as it is.
    private func endSession() {
        generation += 1
        liveness.stop()
        underlayWatch.stop()
        routeWatch?.cancel(); routeWatch = nil
        retryTimer?.cancel(); retryTimer = nil
        deadlineTimer?.cancel(); deadlineTimer = nil
        runner?.onEvent = nil
        runner?.stop()
        runner = nil
        removeQuarterRoutes()
        removeEndpointRoutes()
        clearDNS()
        foreignRoutes = []
        interfaceName = nil
        startedAt = nil
        underlay = nil
    }

    /// Reject routes (ours only), the packet filter and the state file: all of it.
    private func liftKillSwitch() {
        // Unconditional: never trust the in-memory flag on the way out.
        rejectRoutesInstalled = true
        removeRejectRoutes()
        if PacketFilter.lift() { HelperLog.info("vpn: kill switch packet filter lifted") }
        filterRules = nil
        filterError = nil
        filterInterface = nil
        Self.stateStore.clearWanted()
    }

    /// The app's wireless link to the phone changed (it came up, moved to
    /// another address, or went): the filter follows at once, since a link
    /// it drops can't carry the VPN back. Ignored with no VPN session: the
    /// next `start` carries the link.
    func setPhoneLink(_ link: KillSwitchRules.PhoneLink?) {
        guard config != nil, config?.phoneLink != link else { return }
        config?.phoneLink = link
        if let link {
            HelperLog.info("vpn: wireless link to the phone on port \(link.port), at \(link.peers.isEmpty ? "no address yet" : link.peers.joined(separator: ", "))")
        } else {
            HelperLog.info("vpn: wireless link to the phone gone")
        }
        if filterRules != nil || filterError != nil { updateFilter(vpnInterface: filterInterface) }
    }

    /// The passthrough tunnel came up or went down: the encrypted flow has to
    /// move to the new underlay, which means a fresh session.
    func underlayChanged() {
        guard let config, state != .off else { return }
        HelperLog.info("vpn: underlay changed; restarting \(config.engine.rawValue)")
        restart(after: 0.5)
    }

    /// The phone under the passthrough moved between Wi-Fi and cellular: its
    /// public address changed, so a session riding it is dead. Restart now
    /// rather than wait for the liveness check.
    func phoneNetworkChanged() {
        guard let config, state != .off, underlay?.isPassthrough == true else { return }
        HelperLog.info("vpn: the phone changed networks; restarting \(config.engine.rawValue)")
        restart(after: 0.5)
    }

    func status() -> [String: Any] {
        var dict: [String: Any] = [VPNStatusKey.state: state.rawValue]
        if state == .held {
            dict[VPNStatusKey.error] = "Passthrough stopped while the VPN was on, so the kill switch is still blocking traffic."
        }
        guard let config else { return dict }
        dict[VPNStatusKey.engine] = config.engine.rawValue
        dict[VPNStatusKey.name] = config.name
        if let interfaceName { dict[VPNStatusKey.interface] = interfaceName }
        if let startedAt { dict[VPNStatusKey.since] = startedAt.timeIntervalSince1970 }
        if let lastError { dict[VPNStatusKey.error] = lastError }
        let blocking = config.killSwitch && filterError == nil
        if let warning = filterError.map({ "The kill switch's packet filter is not active (\($0)); only its routes protect you." })
            ?? (foreignRoutes.isEmpty ? nil : "This network is pushing routes around the VPN (\(foreignRoutes.prefix(3).joined(separator: ", ")))"
                + (blocking ? "; blocked by the kill switch." : "; with the kill switch off, traffic to them bypasses the VPN.")) {
            dict[VPNStatusKey.warning] = warning
        }
        if let underlay { dict[VPNStatusKey.underlay] = underlay.isPassthrough ? "iPhone" : Self.friendlyName(for: underlay.interface) }
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
        // The passthrough tunnel reports its own comings and goings
        // (underlayChanged); a Wi-Fi or Ethernet underlay is watched here.
        if !underlay.isPassthrough {
            let interface = underlay.interface
            underlayWatch.start(interface: interface) { [weak self] in self?.underlayMoved(interface) }
        }
        // Kill switch first whenever no name resolution is needed (IP-literal
        // endpoints, or cached answers), so there is no unprotected moment.
        let needsDNS = runner.endpoints.contains { ep in
            let h = ep.host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            return !(OpenVPNRunner.isIPv4(h) || Shell.isIPv6(h)) && resolvedCache[h] == nil
        }
        if config.killSwitch, !needsDNS { engageKillSwitch() }
        runner.endpointIPs = try installEndpointRoutes(for: runner.endpoints, underlay: underlay)
        // Again, now with the VPN servers let through.
        if config.killSwitch { engageKillSwitch() }

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
            installQuarterRoutes(on: iface)
            // The filter lets the VPN's interface through before the reject
            // routes go, so the switch-over never opens anything else.
            if config.killSwitch { updateFilter(vpnInterface: iface) }
            removeRejectRoutes()
            startRouteWatch(vpnInterface: iface)
            // OpenVPN: the pushed resolvers first, then the fallback. NordVPN's stall
            // for seconds at a time, and with no second choice every lookup, and so
            // every new connection, stalled with them. The fallback is reached
            // through the VPN too (the /2 routes), so nothing leaks to the underlay.
            let servers = config.engine == .openvpn ? dns + config.fallbackDNS.filter { !dns.contains($0) }
                : dns.isEmpty ? config.fallbackDNS : dns
            applyDNS(servers, interface: iface, address: address, gateway: gateway)
            state = .connected
            HelperLog.info("vpn: connected on \(iface) (dns \(activeDNS.joined(separator: ", ")))")
            // WireGuard re-handshakes every two minutes and has its own check.
            if config.engine == .openvpn {
                liveness.start(interface: iface, dnsServers: activeDNS,
                               rx: { [weak self] in (self?.runner as? OpenVPNRunner)?.linkRxBytes() ?? 0 },
                               describe: { [weak self] in (self?.runner as? OpenVPNRunner)?.counterSummary() ?? "" })
            }
        case .reconnecting(let why):
            HelperLog.warn("vpn: session lost (\(why)); engine is reconnecting")
            state = .reconnecting
        case .exited(let fatal):
            deadlineTimer?.cancel(); deadlineTimer = nil
            runner?.onEvent = nil
            runner = nil
            routeWatch?.cancel(); routeWatch = nil
            if config.killSwitch { engageKillSwitch() }
            removeQuarterRoutes()
            if let fatal {
                // Nothing a retry can fix. With the kill switch on, traffic stays
                // blocked until the user turns the layer off (stopVPN lifts it):
                // a peer must never be able to "fail" us into the clear.
                lastError = fatal
                state = .failed
                HelperLog.error("vpn: \(fatal)")
                underlayWatch.stop()   // a network change must not retry it either
                removeEndpointRoutes()
                return
            }
            retryAttempt += 1
            let delay = min(30.0, pow(2.0, Double(min(retryAttempt, 5))))
            lastError = "The VPN engine stopped; reconnecting in \(Int(delay))s"
            state = config.killSwitch ? .blocked : .reconnecting
            HelperLog.warn("vpn: engine exited; retry #\(retryAttempt) in \(Int(delay))s")
            restart(after: delay)
        }
    }

    /// The interface under the VPN joined another network: the endpoint route
    /// still points at the old gateway, so start over on the new one. The
    /// short wait lets the new default route settle before it is read.
    private func underlayMoved(_ interface: String) {
        guard let config, state != .off, state != .failed else { return }
        HelperLog.info("vpn: \(interface) joined another network; restarting \(config.engine.rawValue)")
        restart(after: 2)
    }

    private func restart(after delay: TimeInterval) {
        liveness.stop()
        underlayWatch.stop()
        routeWatch?.cancel(); routeWatch = nil
        retryTimer?.cancel()
        deadlineTimer?.cancel(); deadlineTimer = nil
        runner?.onEvent = nil
        runner?.stop()
        runner = nil
        // Block first, then tear down the rest.
        if config?.killSwitch == true { engageKillSwitch() }
        removeQuarterRoutes()
        removeEndpointRoutes()
        retractOwnService()
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

    /// "Wi-Fi" / "Ethernet" for a BSD interface name, via the hardware-port list.
    static func friendlyName(for interface: String) -> String {
        let ports = Shell.capture("/usr/sbin/networksetup", ["-listallhardwareports"])
        var lastPort = ""
        for line in ports.split(separator: "\n") {
            if line.hasPrefix("Hardware Port: ") { lastPort = String(line.dropFirst("Hardware Port: ".count)) }
            if line == "Device: \(interface)" { return lastPort.isEmpty ? interface : lastPort }
        }
        return interface
    }

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
        var passes: [KillSwitchRules.Endpoint] = []
        let cachedBefore = resolvedCache
        for endpoint in endpoints {
            let literal = endpoint.host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            let isLiteral = OpenVPNRunner.isIPv4(literal) || Shell.isIPv6(literal)
            // While the kill switch blocks, the last good answer: no DNS
            // outside the tunnel (only the LAN's resolver could answer anyway).
            var resolved = rejectRoutesInstalled && !isLiteral ? resolvedCache[literal] ?? [] : []
            if resolved.isEmpty { resolved = Shell.resolve(literal) }
            if resolved.isEmpty, let cached = resolvedCache[literal] {
                resolved = cached   // kill switch up: reuse the last good answer, no DNS needed
            }
            guard !resolved.isEmpty else { throw VPNError.unresolvable(endpoint.host) }
            if resolvedCache.count > 16 { resolvedCache = [:] }
            if !isLiteral { resolvedCache[literal] = resolved }
            byHost[endpoint.host] = resolved[0]
            for ip in resolved where !ips.contains(ip) { ips.append(ip) }
            passes += resolved.map { KillSwitchRules.Endpoint(ip: $0, port: endpoint.port) }
        }
        endpointPasses = passes
        // Kept on disk for a helper that starts after a crash with the block up.
        if resolvedCache != cachedBefore {
            do { try Self.stateStore.setEndpoints(resolvedCache) } catch {
                HelperLog.warn("vpn: could not save the servers' addresses: \(error.localizedDescription)")
            }
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

    /// Points a quarter prefix at `target` atomically: `route change` when the
    /// prefix exists (e.g. as a reject route), `route add` otherwise. Traffic for
    /// that prefix is never unrouted in between.
    /// A reject target, or an existing reject route, is re-added instead:
    /// XNU neither sets nor clears the reject flag on a change.
    private func setQuarter(_ q: String, v6: Bool, target: [String], table: Set<String>) -> Bool {
        let family = v6 ? "-inet6" : "-inet"
        if RouteTable.exists(q, v6: v6, in: table) {
            if !target.contains("-reject"), !RouteTable.isReject(q, v6: v6),
               (try? Shell.run("/sbin/route", ["-q", "-n", "change", family, q] + target, quiet: true)) != nil { return true }
            RouteTable.deleteIfPresent(q, v6: v6, table: table)
        }
        return (try? Shell.run("/sbin/route", ["-q", "-n", "add", family, q] + target, quiet: true)) != nil
    }

    private func installQuarterRoutes(on iface: String) {
        if quarterRoutesOn == iface { return }
        let v4 = RouteTable.present(v6: false)
        for q in Self.v4Quarters where !setQuarter(q, v6: false, target: ["-interface", iface], table: v4) {
            HelperLog.warn("vpn: route \(q) → \(iface) failed")
        }
        // IPv6: most VPN servers (NordVPN included) hand out no IPv6, and the
        // kernel refuses a v6 route through an interface with no v6 address. In
        // that case reject v6 outright so it can never fall back to the underlay;
        // apps fall through to IPv4 immediately (Happy Eyeballs).
        let hasV6 = Shell.capture("/sbin/ifconfig", [iface]).contains("inet6 ")
        var v6Rejected = false, v6Open = false
        let v6 = RouteTable.present(v6: true)
        for q in Self.v6Quarters {
            if hasV6, setQuarter(q, v6: true, target: ["-interface", iface], table: v6) { continue }
            if config?.blockIPv6 ?? true {
                _ = setQuarter(q, v6: true, target: ["::1", "-reject"], table: v6)
                v6Rejected = true
            } else {
                RouteTable.deleteIfPresent(q, v6: true, table: v6)
                v6Open = true
            }
        }
        if v6Rejected { HelperLog.info("vpn: \(iface) carries no IPv6; IPv6 is blocked while the VPN is on") }
        if v6Open { HelperLog.warn("vpn: \(iface) carries no IPv6 and IPv6 blocking is off; IPv6 traffic bypasses the VPN") }
        ipv6Bypass = v6Open
        quarterRoutesOn = iface
    }

    private func removeQuarterRoutes() {
        guard quarterRoutesOn != nil else { return }
        let v4 = RouteTable.present(v6: false), v6 = RouteTable.present(v6: true)
        for q in Self.v4Quarters { RouteTable.deleteIfPresent(q, v6: false, table: v4) }
        for q in Self.v6Quarters { RouteTable.deleteIfPresent(q, v6: true, table: v6) }
        quarterRoutesOn = nil
        ipv6Bypass = false
    }

    /// The VPN is down: reject routes and the packet filter (without the
    /// VPN's interface) both block.
    private func engageKillSwitch() {
        installRejectRoutes()
        updateFilter(vpnInterface: nil)
    }

    /// While the VPN is down, send everything (except the endpoint host routes)
    /// into a reject route so nothing leaks onto the underlay. A route someone
    /// else put at one of these prefixes (a network pushing routes around
    /// the VPN) is replaced, never left to carry traffic past the block.
    private func installRejectRoutes() {
        guard !rejectRoutesInstalled else { return }
        for (prefixes, v6) in [(Self.v4Eighths, false), (Self.v6Eighths, true)] {
            let table = RouteTable.entries(v6: v6)
            let family = v6 ? "-inet6" : "-inet"
            for q in prefixes {
                switch RejectRoutes.install(over: table[RouteTable.netstatName(q)], v6: v6) {
                case .keep: continue
                case .replace(let theirs):
                    HelperLog.warn("vpn: \(q) was routed via \(theirs.gateway) on \(theirs.interface), around the VPN (a network pushing routes, TunnelVision-style); replacing it with the kill switch's reject route")
                    _ = try? Shell.run("/sbin/route", ["-q", "-n", "delete", family, q], quiet: true)
                case .add: break
                }
                if (try? Shell.run("/sbin/route", ["-q", "-n", "add", family, q, RejectRoutes.loopback(v6: v6), "-reject"], quiet: true)) == nil {
                    HelperLog.warn("vpn: reject \(q) failed")
                }
            }
        }
        rejectRoutesInstalled = true
        HelperLog.info("vpn: kill switch engaged (traffic blocked until the VPN is back)")
    }

    /// Our reject routes only: a route someone else holds at one of these
    /// prefixes is not ours to delete.
    private func removeRejectRoutes() {
        guard rejectRoutesInstalled else { return }
        for (prefixes, v6) in [(Self.v4Eighths, false), (Self.v6Eighths, true)] {
            let entries = RouteTable.entries(v6: v6)
            let table = Set(entries.keys)
            for q in prefixes where RouteTable.isOurs(q, v6: v6, in: entries) { RouteTable.deleteIfPresent(q, v6: v6, table: table) }
        }
        rejectRoutesInstalled = false
    }

    // MARK: Packet filter + foreign routes

    /// Loads the kill switch's pf rules for the session as it is now: the
    /// VPN's interface (while connected), the servers, the wireless link to
    /// the phone, the local networks (when allowed) and Tailscale. Unchanged
    /// rules are not reloaded. If pf can't be used the reject routes still
    /// block while the VPN is down, and the app is told protection is weaker.
    private func updateFilter(vpnInterface: String?) {
        guard let config, config.killSwitch else { return }
        filterInterface = vpnInterface
        let addresses = LocalNetworks.current()
        let lan = LocalNetworks.subnets(addresses)
        let rules = KillSwitchRules.ruleset(KillSwitchRules.Input(
            vpnInterface: vpnInterface,
            endpoints: endpointPasses,
            localSubnets: config.allowLocalNetwork ? lan : [],
            tailscaleInterfaces: LocalNetworks.tailscaleInterfaces(addresses, excluding: notTailscale),
            phoneLink: config.phoneLink.map { KillSwitchRules.PhoneLink(port: $0.port, peers: $0.peers, subnets: lan) },
            allowIPv6Bypass: vpnInterface != nil && ipv6Bypass))
        guard rules != filterRules else { return }
        do {
            try PacketFilter.apply(rules)
            filterRules = rules
            if filterError != nil { HelperLog.info("vpn: kill switch packet filter active again") }
            filterError = nil
        } catch {
            filterRules = nil
            if filterError == nil {
                HelperLog.error("vpn: kill switch packet filter: \(error.localizedDescription); routes pushed by the network can get around a connected VPN")
            }
            filterError = error.localizedDescription
        }
    }

    /// While connected: looks every 20 s for routes the network pushed around
    /// the VPN (the filter drops what they carry; the user is told), and
    /// keeps the filter's local networks current as interfaces come and go.
    private func startRouteWatch(vpnInterface: String) {
        routeWatch?.cancel()
        let check = { [weak self] in
            guard let self, self.state == .connected, self.interfaceName == vpnInterface else { return }
            self.checkForeignRoutes(vpnInterface: vpnInterface)
            self.updateFilter(vpnInterface: vpnInterface)
        }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 20, repeating: 20)
        timer.setEventHandler(handler: check)
        timer.resume()
        routeWatch = timer
        checkForeignRoutes(vpnInterface: vpnInterface)
    }

    /// Interfaces that are never Tailscale's, whatever address they hold:
    /// the underlay (the passthrough's utun, or Wi-Fi), which carries
    /// everything around the VPN.
    private var notTailscale: Set<String> {
        Set([underlay?.interface, tunnel.interfaceName].compactMap { $0 })
    }

    private func checkForeignRoutes(vpnInterface: String) {
        let tailscale = Set(LocalNetworks.tailscaleInterfaces(LocalNetworks.current(), excluding: notTailscale))
        let ours = Set(endpointRoutes.map(\.ip))
        let foreign = ForeignRoutes.find(RouteTable.all(v6: false), vpnInterface: vpnInterface, ownInterfaces: tailscale, ownHosts: ours)
            + ForeignRoutes.find(RouteTable.all(v6: true), vpnInterface: vpnInterface, ownInterfaces: tailscale, ownHosts: ours)
        let described = foreign.map { "\($0.prefix?.description ?? $0.destination) via \($0.interface)" }
        if described != foreignRoutes, !described.isEmpty {
            HelperLog.warn("vpn: this network is pushing routes around the VPN (\(described.joined(separator: ", "))); \(config?.killSwitch == true && filterError == nil ? "the kill switch blocks them" : "traffic to them bypasses the VPN")")
        }
        foreignRoutes = described
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
        retractOwnService()
    }

    /// Drop only our own published service (so the underlay can be re-detected)
    /// while keeping the VPN's resolvers on the passthrough during a reconnect:
    /// queries must never fall back to the bare underlay's DNS mid-session.
    private func retractOwnService() {
        tunnel.setPrimaryRank("First")
        guard !publishedKeys.isEmpty, let store else { return }
        for key in publishedKeys { SCDynamicStoreRemoveValue(store, key as CFString) }
        publishedKeys = []
    }
}
