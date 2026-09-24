import NetworkExtension
import PassthroughCore

/// Hosts the SOCKS5 server and control channel as a long-lived background
/// process. The "tunnel" itself routes nothing: a single unreachable /32 keeps
/// the VPN session valid while the phone's real traffic flows untouched.
final class PacketTunnelProvider: NEPacketTunnelProvider {
    private var service: PassthroughService?

    override init() {
        super.init()
        if let url = PassthroughProtocol.sharedLogURL { PassthroughLog.shared.attachFile(url) }
    }

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        let defaults = UserDefaults(suiteName: PassthroughProtocol.appGroup) ?? .standard
        ptLog(.info, "Extension starting")
        let config = (protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration ?? [:]
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

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        ptLog(.info, "Background host stopping (\(reason.rawValue))")
        service?.stop()
        service = nil
        completionHandler()
    }

    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        guard let service else { completionHandler?(nil); return }
        completionHandler?(try? JSONEncoder().encode(service.stats()))
    }

    override func sleep(completionHandler: @escaping () -> Void) { completionHandler() }
    override func wake() {}
}
