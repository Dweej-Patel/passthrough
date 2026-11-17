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

    @Published private(set) var upstream: UpstreamPhone? {
        // Its Macs see which iPhone this iPad uses (the status the app serves them).
        didSet { AppModel.groupDefaults.set(upstream?.name, forKey: SharedKeys.internetFrom) }
    }
    @Published private(set) var tunnel: NEVPNStatus = .invalid
    @Published private(set) var status: HotspotStatus?
    /// On the iPhone's Personal Hotspot (172.20.10.0/28) right now.
    @Published private(set) var onPhoneHotspot = false
    @Published private(set) var startError: String?
    /// The switch is on: iOS starts the tunnel whenever this iPad is on an iPhone's hotspot.
    @Published private(set) var armed = false

    let store = UpstreamPhoneStore.shared()
    private let controller = TunnelController()
    private var wifi: WiFiPathReader?
    private var ticker: Timer?
    private var loaded = false
    /// The learned hotspots last put in the on-demand rule.
    private var appliedHotspots: [String]?

    init() {
        controller.onStatusChange = { [weak self] status in
            Task { @MainActor in
                if self?.tunnel != status { ptLog(.info, "hotspot: tunnel \(status.name)") }
                self?.tunnel = status
                if status == .disconnected || status == .invalid { self?.status = nil }
            }
        }
        wifi = WiFiPathReader { [weak self] _ in
            Task { @MainActor in self?.refreshOnHotspot() }
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
                    // Read before the tunnel is up: then the DNS servers are the network's.
                    let sign = hotspotSign()
                    ptLog(.info, "hotspot: switched on; hotspot sign: \(sign) (\(networkSummary))")
                    try await controller.configureClient(name: ThisDevice.displayName)
                    appliedHotspots = HotspotTunnel.knownHotspotDNS(AppModel.groupDefaults)
                    armed = true
                    // A known hotspot, or one iOS counts as costly: start now (a
                    // hotspot not yet known gets a minute for the iPhone to dial
                    // in, which is how it becomes known). Anywhere else iOS starts
                    // it once this iPad joins a known one.
                    if sign != .none { startNow(because: "turned on") }
                } catch {
                    startError = error.localizedDescription
                }
            } else {
                await controller.stop()
                armed = false
            }
        }
    }

    /// A new iPhone, already saved to `store` (by the pairing listener). The
    /// hotspots learned belonged to the one before (or were the same iPhone's,
    /// and are learned again on its first link).
    func adopted(_ phone: UpstreamPhone) {
        if upstream?.phoneID != phone.phoneID { HotspotTunnel.forgetHotspots(in: AppModel.groupDefaults) }
        upstream = phone
        notify_post(PairingRegistry.changedNotification)
    }

    /// Forgets the iPhone: the switch goes off, and the iPad uses the hotspot
    /// like any device. Its hotspots are forgotten too.
    func forget() {
        setOn(false)
        store.forget()
        HotspotTunnel.forgetHotspots(in: AppModel.groupDefaults)
        upstream = nil
        notify_post(PairingRegistry.changedNotification)
    }

    /// When the switch is on and this iPad is on a known hotspot, but iOS
    /// didn't start the tunnel: start it (it would otherwise use hotspot data).
    /// Not on a hotspot only iOS counts as costly: that could be anyone's.
    private var standbyOnHotspotSince: Date?
    private var lastNudge: Date?

    private func nudgeIfIOSDidNotStart() async {
        guard phase == .standby, hotspotSign() == .known else { standbyOnHotspotSince = nil; return }
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
        startNow(because: "nudge")
    }

    /// Asks iOS to start the tunnel, saying in the log if it refuses.
    private func startNow(because reason: String) {
        do {
            try controller.start(manual: true)
            ptLog(.info, "hotspot: asked iOS to start the tunnel (\(reason)); it says \(controller.status.name)")
        } catch {
            ptLog(.error, "hotspot: iOS refused to start the tunnel (\(reason)): \(error.localizedDescription)")
            startError = error.localizedDescription
        }
    }

    private var ticks = 0

    private func tick() async {
        ticks += 1
        // The Wi-Fi reader reports changes; this catches what it doesn't (a new
        // DNS server, a hotspot learned by the extension) every few seconds.
        if ticks % 5 == 0 { refreshOnHotspot() }
        await nudgeIfIOSDidNotStart()
        guard tunnel == .connected || tunnel == .reasserting else { return }
        // The extension learns the hotspot once linked: put it in the on-demand rule.
        let learned = HotspotTunnel.knownHotspotDNS(AppModel.groupDefaults)
        if learned != appliedHotspots {
            appliedHotspots = learned
            await controller.updateClientRules()
        }
        if let data = await controller.message(HotspotTunnel.statusMessage),
           let status = try? JSONDecoder().decode(HotspotStatus.self, from: data) {
            self.status = status
        }
    }

    /// The resolver's DNS servers are the network's only while the tunnel is
    /// down; with it up they're the tunnel's, and only the other signs count.
    private func hotspotSign() -> WirelessLink.HotspotSign {
        let tunnelDown = tunnel == .disconnected || tunnel == .invalid
        return WirelessLink.hotspotSign(wifi: wifi?.facts, dnsServers: tunnelDown ? DNSRedirect.systemServers() : [],
                                        knownHotspotDNS: HotspotTunnel.knownHotspotDNS(AppModel.groupDefaults), requireCostly: true)
    }

    private func refreshOnHotspot() {
        pruneMistakenHotspots()
        let on = hotspotSign() != .none
        if on != onPhoneHotspot { onPhoneHotspot = on }
    }

    /// On Wi-Fi iOS doesn't count as costly (never an iPhone's hotspot), with
    /// the tunnel down: anything learned that matches this network was a
    /// mistake. Drop it, and the on-demand rule follows on the next save.
    private func pruneMistakenHotspots() {
        guard tunnel == .disconnected || tunnel == .invalid, let facts = wifi?.facts, facts.up, !facts.expensive else { return }
        let markers = WirelessLink.networkMarkers(wifi: facts, dnsServers: DNSRedirect.systemServers())
        guard HotspotTunnel.forgetHotspots(matching: markers, in: AppModel.groupDefaults) else { return }
        ptLog(.info, "hotspot: this Wi-Fi isn't a hotspot; forgot it as one (\(networkSummary))")
        Task { await controller.updateClientRules() }
    }

    private var networkSummary: String { WirelessLink.networkSummary(wifi: wifi?.facts, dnsServers: DNSRedirect.systemServers()) }
}
