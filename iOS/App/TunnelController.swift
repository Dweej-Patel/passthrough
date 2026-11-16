import Foundation
import NetworkExtension
import PassthroughCore

/// Thin wrapper over NETunnelProviderManager for the packet tunnel extension
/// that hosts the proxy in the background.
final class TunnelController {
    static let providerBundleID = "\(PassthroughProtocol.identifier).ios.tunnel"
    private var manager: NETunnelProviderManager?
    private var observer: NSObjectProtocol?
    var onStatusChange: ((NEVPNStatus) -> Void)?

    var status: NEVPNStatus { manager?.connection.status ?? .invalid }

    func load() async throws {
        let managers = try await NETunnelProviderManager.loadAllFromPreferences()
        manager = managers.first { ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == Self.providerBundleID } ?? managers.first
        observe()
    }

    private func observe() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        guard let manager else { return }
        observer = NotificationCenter.default.addObserver(forName: .NEVPNStatusDidChange, object: manager.connection, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.onStatusChange?(self.status)
        }
    }

    func configure(_ options: PassthroughService.Options) async throws {
        if manager == nil { try await load() }
        let manager = self.manager ?? NETunnelProviderManager()
        let proto = (manager.protocolConfiguration as? NETunnelProviderProtocol) ?? NETunnelProviderProtocol()
        proto.providerBundleIdentifier = Self.providerBundleID
        proto.serverAddress = "USB"
        proto.providerConfiguration = options.providerConfiguration
        proto.disconnectOnSleep = false
        manager.protocolConfiguration = proto
        manager.localizedDescription = "Passthrough"
        manager.isEnabled = true
        // On-demand "always connect": iOS itself relaunches the extension if it
        // is killed (memory pressure, crash) or after a reboot, so the proxy
        // survives without the user reopening the app. Cleared on manual stop.
        manager.isOnDemandEnabled = true
        manager.onDemandRules = [NEOnDemandRuleConnect()]
        try await manager.saveToPreferences()
        try await manager.loadFromPreferences()
        self.manager = manager
        observe()
    }

    /// An iPad's "Internet through iPhone": the extension as the iPhone's
    /// client. It takes every route, local ones and push included, so with the
    /// link down nothing leaves over the hotspot (the guard). On demand, so iOS
    /// brings it back after it's killed or the iPad restarts, but only on an
    /// iPhone's Personal Hotspot: on any other network the iPad uses that
    /// network as usual (the iPhone only reaches it over the hotspot, so
    /// holding the routes there would only cut the iPad off).
    func configureClient(name: String) async throws {
        if manager == nil { try await load() }
        let manager = self.manager ?? NETunnelProviderManager()
        let proto = NETunnelProviderProtocol()
        proto.providerBundleIdentifier = Self.providerBundleID
        proto.serverAddress = "iPhone"
        proto.providerConfiguration = [HotspotTunnel.roleKey: HotspotTunnel.clientRole, HotspotTunnel.nameKey: name]
        proto.disconnectOnSleep = false
        proto.includeAllNetworks = true
        proto.excludeLocalNetworks = false
        proto.excludeAPNs = false
        manager.protocolConfiguration = proto
        manager.localizedDescription = "Passthrough"
        manager.isEnabled = true
        manager.isOnDemandEnabled = true
        manager.onDemandRules = Self.hotspotOnlyRules
        try await manager.saveToPreferences()
        try await manager.loadFromPreferences()
        self.manager = manager
        observe()
    }

    /// Connect on an iPhone's hotspot, known by its DNS server: 172.20.10.1 on
    /// an IPv4 hotspot, or the ones this iPad learned from the iPhone's hotspot
    /// once a link worked (an IPv6-only hotspot names the iPhone's link-local
    /// address). Anywhere else iOS leaves it alone (Ignore, not Disconnect: a
    /// Disconnect rule also blocks the app's own starts, which an unlearned
    /// IPv6-only hotspot needs); the extension itself steps aside off the
    /// hotspot (`HotspotPresenceWatch`). The tunnel's own DNS address is in
    /// the match too, in case iOS reads the DNS server with the tunnel up.
    static var hotspotOnlyRules: [NEOnDemandRule] {
        let hotspot = NEOnDemandRuleConnect()
        hotspot.interfaceTypeMatch = .wiFi
        hotspot.dnsServerAddressMatch = [WirelessLink.hotspotGateway, HotspotTunnel.dnsAddress]
            + HotspotTunnel.knownHotspotDNS(AppModel.groupDefaults)
        return [hotspot, NEOnDemandRuleIgnore()]
    }

    /// What decides whether saved rules are current: each rule's action and DNS match.
    private static func signature(_ rules: [NEOnDemandRule]?) -> [String] {
        (rules ?? []).map { "\($0.action.rawValue):\(($0.dnsServerAddressMatch ?? []).joined(separator: ","))" }
    }

    /// Whether iOS starts the tunnel by itself (the switch is on).
    var onDemandEnabled: Bool { manager?.isOnDemandEnabled ?? false }

    /// An iPad whose saved rules differ from the current ones (configured
    /// before, or a hotspot's DNS learned since): save the current ones.
    func updateClientRules() async {
        guard let manager, manager.isOnDemandEnabled,
              (manager.protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration?[HotspotTunnel.roleKey] as? String == HotspotTunnel.clientRole,
              Self.signature(manager.onDemandRules) != Self.signature(Self.hotspotOnlyRules) else { return }
        manager.onDemandRules = Self.hotspotOnlyRules
        try? await manager.saveToPreferences()
        try? await manager.loadFromPreferences()
    }

    /// Sends the extension a message and waits (2 s at most) for its answer.
    func message(_ data: Data) async -> Data? {
        guard let session = manager?.connection as? NETunnelProviderSession, session.status == .connected else { return nil }
        return await withCheckedContinuation { continuation in
            let done = NSLock()
            var resumed = false
            func finish(_ value: Data?) {
                done.lock(); defer { done.unlock() }
                guard !resumed else { return }
                resumed = true
                continuation.resume(returning: value)
            }
            do { try session.sendProviderMessage(data) { finish($0) } } catch { finish(nil) }
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { finish(nil) }
        }
    }

    /// `manual`: the user asked (the iPad's tunnel then starts even where it
    /// can't yet tell the iPhone's hotspot from another network).
    func start(manual: Bool = false) throws {
        guard let manager else { throw NSError(domain: "Passthrough", code: 2, userInfo: [NSLocalizedDescriptionKey: "Tunnel not configured"]) }
        try manager.connection.startVPNTunnel(options: manual ? [HotspotTunnel.manualStartKey: NSNumber(value: true)] : nil)
    }

    /// Manual stop: drop the on-demand rule first, otherwise iOS restarts the
    /// tunnel the moment it goes down.
    func stop() async {
        guard let manager else { return }
        if manager.isOnDemandEnabled {
            manager.isOnDemandEnabled = false
            try? await manager.saveToPreferences()
        }
        manager.connection.stopVPNTunnel()
    }

    func fetchStats() async -> ProviderStats? {
        // The extension can be killed between the status check and its reply (`message` times out).
        guard let data = await message(Data("stats".utf8)) else { return nil }
        return try? JSONDecoder().decode(ProviderStats.self, from: data)
    }
}

extension NEVPNStatus {
    /// For the log.
    var name: String {
        switch self {
        case .invalid: "invalid"
        case .disconnected: "disconnected"
        case .connecting: "connecting"
        case .connected: "connected"
        case .reasserting: "reasserting"
        case .disconnecting: "disconnecting"
        @unknown default: "unknown (\(rawValue))"
        }
    }
}
