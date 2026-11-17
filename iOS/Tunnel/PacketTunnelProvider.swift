import NetworkExtension
import notify
import PassthroughCore

/// Hosts the SOCKS5 server and control channel as a long-lived background
/// process. The "tunnel" itself routes nothing: a single unreachable /32 keeps
/// the VPN session valid while the phone's real traffic flows untouched.
final class PacketTunnelProvider: NEPacketTunnelProvider {
    private var service: PassthroughService?
    /// On an iPad: "Internet through iPhone" instead of the phone's proxy.
    private var hotspot: HotspotRole?
    private var pairingsToken: Int32?
    /// iPad: watches for this iPad leaving the iPhone's hotspot.
    private var hotspotWatch: HotspotPresenceWatch?
    /// The iPhone is linked right now: proof this iPad is on its hotspot.
    private let hotspotLinked = Locked(false)

    override init() {
        super.init()
        if let url = PassthroughProtocol.sharedLogURL { PassthroughLog.shared.attachFile(url) }
    }

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        let defaults = UserDefaults(suiteName: PassthroughProtocol.appGroup) ?? .standard
        ptLog(.info, "Extension starting")
        let config = (protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration ?? [:]
        if config[HotspotTunnel.roleKey] as? String == HotspotTunnel.clientRole {
            let manual = (options?[HotspotTunnel.manualStartKey] as? NSNumber)?.boolValue ?? false
            startHotspot(name: config[HotspotTunnel.nameKey] as? String ?? "iPad", manual: manual, completionHandler: completionHandler)
            return
        }
        let service = PassthroughService.sharing(defaults, options: .init(providerConfiguration: config), hosting: "background")
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "10.255.255.1")
        let ipv4 = NEIPv4Settings(addresses: ["10.255.255.2"], subnetMasks: ["255.255.255.255"])
        ipv4.includedRoutes = [NEIPv4Route(destinationAddress: "10.255.255.1", subnetMask: "255.255.255.255")]
        settings.ipv4Settings = ipv4
        settings.mtu = 1400

        setTunnelNetworkSettings(settings) { [weak self] error in
            if let error {
                ptLog(.error, "Tunnel settings rejected: \(error.localizedDescription)")
                completionHandler(error)
                return
            }
            do {
                try service.start()
                self?.service = service
                self?.drainPackets()
                ptLog(.info, "Background host started")
                completionHandler(nil)
            } catch {
                ptLog(.error, "Server start failed: \(error.localizedDescription)")
                completionHandler(error)
            }
        }
    }

    /// Nothing should ever be routed here, but keep the packet flow drained.
    private func drainPackets() {
        packetFlow.readPackets { [weak self] _, _ in self?.drainPackets() }
    }

    // MARK: iPad: Internet through iPhone

    /// Holding every route is only right on the iPhone's hotspot (that's where
    /// the iPhone reaches this iPad); anywhere else it would only cut the iPad
    /// off. So iOS's own starts (on demand) go ahead only on a known hotspot.
    /// A start the user asked for (`manual`) goes ahead anyway, since an
    /// IPv6-only hotspot is only "costly Wi-Fi" until its first link: the
    /// watch then gives the iPhone a minute to dial in there, and steps aside
    /// within seconds anywhere else.
    private func startHotspot(name: String, manual: Bool, completionHandler: @escaping (Error?) -> Void) {
        // Read before this tunnel's settings apply, so the DNS servers are the network's.
        let dns = DNSRedirect.systemServers()
        let wifi = WiFiPathReader()
        // The provider and its completion handler only go on to the main queue.
        let resume = UncheckedSendable { [weak self] (facts: WirelessLink.WiFiFacts?) in
            self?.startHotspot(name: name, manual: manual, wifi: facts, dns: dns, completionHandler: completionHandler)
        }
        wifi.whenKnown { facts in
            wifi.cancel()
            DispatchQueue.main.async { resume.value(facts) }
        }
    }

    private func startHotspot(name: String, manual: Bool, wifi: WirelessLink.WiFiFacts?, dns: [String],
                              completionHandler: @escaping (Error?) -> Void) {
        let defaults = UserDefaults(suiteName: PassthroughProtocol.appGroup) ?? .standard
        let known = HotspotTunnel.knownHotspotDNS(defaults)
        let network = WirelessLink.networkSummary(wifi: wifi, dnsServers: dns)
        let sign = WirelessLink.hotspotSign(wifi: wifi, dnsServers: dns, knownHotspotDNS: known, requireCostly: true)
        guard manual || sign == .known else {
            ptLog(.info, "Internet through iPhone: not on an iPhone's hotspot, so not starting (\(network))")
            completionHandler(NSError(domain: "Passthrough", code: 12,
                                      userInfo: [NSLocalizedDescriptionKey: "This iPad isn't on the iPhone's Personal Hotspot."]))
            return
        }
        ptLog(.info, "Internet through iPhone: \(manual ? "turned on" : "on a known hotspot"), applying the tunnel (hotspot sign: \(sign); \(network))")
        setTunnelNetworkSettings(HotspotRole.settings(ipv6: false)) { [weak self] error in
            if let error {
                ptLog(.error, "Tunnel settings rejected: \(error.localizedDescription)")
                completionHandler(error)
                return
            }
            ptLog(.info, "Internet through iPhone: tunnel applied, starting the link")
            Task { @MainActor in
                guard let self else { return }
                let role = HotspotRole()
                do {
                    let linked = self.hotspotLinked
                    try role.start(name: name, onLinked: { up in
                        linked.set(up)
                        // A link worked over this network, and the iPhone links an iPad
                        // over its hotspot only: remember the network's DNS servers and
                        // routers, so the on-demand rule (the app applies it) and the
                        // hotspot check know this hotspot next time.
                        if up, HotspotTunnel.rememberHotspotDNS(dns + (wifi?.gateways ?? []), in: defaults) {
                            ptLog(.info, "Internet through iPhone: learned this hotspot (\(network))")
                        }
                    })
                    self.hotspot = role
                    self.watchPairings()
                    self.watchForLeavingTheHotspot()
                    completionHandler(nil)
                } catch {
                    ptLog(.error, "Internet through iPhone could not start: \(error.localizedDescription)")
                    role.stop()
                    completionHandler(error)
                }
            }
        }
    }

    /// Steps aside once this iPad has left the iPhone's hotspot: the iPad
    /// then uses whatever network it's on, and on-demand starts the tunnel
    /// again on the hotspot.
    @MainActor private func watchForLeavingTheHotspot() {
        // Linked = welcomed by the iPhone and the link responding now: a link
        // held for a resume (the iPad walked off the hotspot) doesn't keep the
        // tunnel holding the routes.
        let live = hotspot?.isLinkLive ?? { false }
        let watch = HotspotPresenceWatch(isLinked: { [hotspotLinked] in hotspotLinked.get() && live() }) { [weak self] in
            ptLog(.info, "Internet through iPhone: this iPad left the iPhone's hotspot; stepping aside so it uses its network")
            self?.cancelTunnelWithError(nil)
        }
        watch.start()
        hotspotWatch = watch
    }

    private func stopWatchingTheHotspot() {
        hotspotWatch?.cancel()
        hotspotWatch = nil
    }

    /// The app re-paired or forgot the iPhone: drop the link so it proves itself again.
    private func watchPairings() {
        var token: Int32 = 0
        let status = notify_register_dispatch(PairingRegistry.changedNotification, &token, .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.hotspot?.credentialsChanged() }
        }
        if status == NOTIFY_STATUS_OK { pairingsToken = token }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        ptLog(.info, "Background host stopping (\(reason.rawValue))")
        if let pairingsToken { notify_cancel(pairingsToken) }
        pairingsToken = nil
        stopWatchingTheHotspot()
        // Turned off by the user: tell the Macs and iPads first, and give it a moment to go out.
        if let service, reason == .userInitiated {
            service.sayGoodbye()
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
                service.stop()
                completionHandler()
            }
            self.service = nil
            return
        }
        service?.stop()
        service = nil
        if let hotspot {
            Task { @MainActor in
                hotspot.stop()
                self.hotspot = nil
                completionHandler()
            }
            return
        }
        completionHandler()
    }

    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        if let hotspot {
            Task { @MainActor in completionHandler?(try? JSONEncoder().encode(hotspot.status())) }
            return
        }
        guard let service else { completionHandler?(nil); return }
        completionHandler?(try? JSONEncoder().encode(service.stats()))
    }

    override func sleep(completionHandler: @escaping () -> Void) { completionHandler() }
    override func wake() {}
}

/// Carries a value the compiler can't prove Sendable to the one queue that uses it.
private struct UncheckedSendable<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}
