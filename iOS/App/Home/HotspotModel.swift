import Foundation
import Network
import NetworkExtension
import notify
import PassthroughCore

/// An iPad's "Internet through iPhone": the switch, the iPhone it's paired
/// with, and how the link is doing (from the tunnel extension).
@MainActor
final class HotspotModel: ObservableObject {
    /// What the switch shows.
    enum Phase: Equatable {
        /// Not paired with an iPhone yet.
        case unpaired
        case off
        /// On, but this iPad isn't on an iPhone's hotspot: it uses its network
        /// as usual, and the tunnel starts by itself once it joins the hotspot.
        case standby
        case starting
        /// On and linked: traffic goes through the iPhone.
        case online
        /// On, waiting for the iPhone to dial in (or come back). Offline on purpose.
        case waiting
        /// On, but the iPhone doesn't know this iPad (any more), or an update is needed.
        case refused(String)
        case failed(String)
        var isOn: Bool {
            switch self { case .unpaired, .off, .failed: false; default: true }
        }
    }

    @Published private(set) var upstream: UpstreamPhone?
    @Published private(set) var tunnel: NEVPNStatus = .invalid
    @Published private(set) var status: HotspotStatus?
    /// On the iPhone's Personal Hotspot (172.20.10.0/28) right now.
    @Published private(set) var onPhoneHotspot = false
    @Published private(set) var startError: String?
    /// The switch is on: iOS starts the tunnel whenever this iPad is on an iPhone's hotspot.
    @Published private(set) var armed = false

    let store = UpstreamPhoneStore.shared()
    private let controller = TunnelController()
    private let wifi = WiFiPathReader()
    private var ticker: Timer?
    private var loaded = false

    init() {
        controller.onStatusChange = { [weak self] status in
            Task { @MainActor in
                self?.tunnel = status
                if status == .disconnected || status == .invalid { self?.status = nil }
            }
        }
        wifi.onChange = { _ in
            Task { @MainActor [weak self] in self?.refreshOnHotspot() }
        }
    }

    var phase: Phase {
        if let startError { return .failed(startError) }
        guard upstream != nil else { return .unpaired }
        switch tunnel {
        case .invalid, .disconnected: return armed ? .standby : .off
        case .connecting, .disconnecting: return .starting
        case .connected, .reasserting:
            switch status?.phase {
            case .online?: return .online
            case .refused?: return .refused(status?.message ?? "The iPhone no longer knows this iPad.")
            default: return .waiting
            }
        @unknown default: return .off
        }
    }

    var phoneName: String { status?.phoneName ?? upstream?.name ?? "iPhone" }

    func load() async {
        upstream = store.load()
        refreshOnHotspot()
        // Every time: the switch may have been changed in Settings meanwhile.
        try? await controller.load()
        if !loaded {
            loaded = true
            await controller.updateClientRules()
            ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor in await self?.tick() }
            }
        }
        tunnel = controller.status
        armed = controller.onDemandEnabled
        await tick()
    }

    func setOn(_ on: Bool) {
        startError = nil
        // Only the app can raise the Local Network prompt; the extension needs the answer.
        if on { LocalNetworkPermission.request() }
        Task {
            if on {
                do {
                    try await controller.configureClient(name: ThisDevice.displayName)
                    armed = true
                    let onHotspot = isOnHotspot()
                    ptLog(.info, "hotspot: switched on; on the hotspot: \(onHotspot) (\(networkSummary))")
                    // Off the hotspot, iOS starts it once this iPad joins one.
                    // On the hotspot, or perhaps on it: before its first link, an
                    // IPv6-only hotspot can't be told from other Wi-Fi. (Anywhere
                    // else the tunnel steps aside within seconds.)
                    let unlearned = HotspotTunnel.knownHotspotDNS(AppModel.groupDefaults).isEmpty
                    if onHotspot || (unlearned && wifi.facts?.up == true) { try controller.start(manual: true) }
                } catch {
                    startError = error.localizedDescription
                }
            } else {
                await controller.stop()
                armed = false
            }
        }
    }

    /// Stores a new iPhone (paired here, or introduced by a Mac) and has a
    /// running tunnel use it.
    /// A new iPhone, already saved to `store` (by the pairing listener).
    func adopted(_ phone: UpstreamPhone) {
        upstream = phone
        notify_post(PairingRegistry.changedNotification)
    }

    /// Forgets the iPhone: the switch goes off, and the iPad uses the hotspot like any device.
    func forget() {
        setOn(false)
        store.forget()
        upstream = nil
        notify_post(PairingRegistry.changedNotification)
    }

    /// When the switch is on and this iPad is on the hotspot, but iOS didn't
    /// start the tunnel: start it (it would otherwise use hotspot data).
    private var standbyOnHotspotSince: Date?
    private var lastNudge: Date?

    private func nudgeIfIOSDidNotStart() async {
        guard phase == .standby, onPhoneHotspot else { standbyOnHotspotSince = nil; return }
        let since = standbyOnHotspotSince ?? Date()
        standbyOnHotspotSince = since
        guard Date().timeIntervalSince(since) >= 5, Date().timeIntervalSince(lastNudge ?? .distantPast) >= 30 else { return }
        lastNudge = Date()
        // Still on? (Turning the VPN off in Settings turns on-demand off too.)
        try? await controller.load()
        armed = controller.onDemandEnabled
        tunnel = controller.status
        guard phase == .standby else { return }
        ptLog(.warning, "hotspot: on the iPhone's hotspot, but iOS didn't start Internet through iPhone; starting it (\(networkSummary))")
        try? controller.start(manual: true)
    }

    private func tick() async {
        refreshOnHotspot()
        await nudgeIfIOSDidNotStart()
        guard tunnel == .connected || tunnel == .reasserting else { return }
        // The extension learns the hotspot's DNS servers once linked: put them in the on-demand rule.
        if status?.phase == .online { await controller.updateClientRules() }
        if let data = await controller.message(HotspotTunnel.statusMessage),
           let status = try? JSONDecoder().decode(HotspotStatus.self, from: data) {
            self.status = status
        }
    }

    /// Whether this iPad's Wi-Fi address is on an iPhone's Personal Hotspot.
    /// The resolver's DNS servers are the network's only while the tunnel is
    /// down; with it up they're the tunnel's, and only the other signs count.
    private func isOnHotspot() -> Bool {
        let tunnelDown = tunnel == .disconnected || tunnel == .invalid
        return WirelessLink.onPhoneHotspot(wifi: wifi.facts, dnsServers: tunnelDown ? DNSRedirect.systemServers() : [],
                                           knownHotspotDNS: HotspotTunnel.knownHotspotDNS(AppModel.groupDefaults))
    }

    private func refreshOnHotspot() { onPhoneHotspot = isOnHotspot() }

    private var networkSummary: String { WirelessLink.networkSummary(wifi: wifi.facts, dnsServers: DNSRedirect.systemServers()) }
}
