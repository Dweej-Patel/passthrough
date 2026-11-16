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

    override init() {
        super.init()
        if let url = PassthroughProtocol.sharedLogURL { PassthroughLog.shared.attachFile(url) }
    }

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        let defaults = UserDefaults(suiteName: PassthroughProtocol.appGroup) ?? .standard
        ptLog(.info, "Extension starting")
        let config = (protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration ?? [:]
        if config[HotspotTunnel.roleKey] as? String == HotspotTunnel.clientRole {
            startHotspot(name: config[HotspotTunnel.nameKey] as? String ?? "iPad", completionHandler: completionHandler)
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

    private func startHotspot(name: String, completionHandler: @escaping (Error?) -> Void) {
        setTunnelNetworkSettings(HotspotRole.settings(ipv6: false)) { [weak self] error in
            if let error {
                ptLog(.error, "Tunnel settings rejected: \(error.localizedDescription)")
                completionHandler(error)
                return
            }
            Task { @MainActor in
                guard let self else { return }
                let role = HotspotRole()
                do {
                    try role.start(name: name)
                    self.hotspot = role
                    self.watchPairings()
                    completionHandler(nil)
                } catch {
                    ptLog(.error, "Internet through iPhone could not start: \(error.localizedDescription)")
                    role.stop()
                    completionHandler(error)
                }
            }
        }
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
