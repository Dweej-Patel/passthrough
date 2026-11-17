import NetworkExtension

/// Runs the probe inside a packet-tunnel extension, the process the real
/// iPad client would live in. "Light" routes nothing (like the iPhone's
/// Passthrough tunnel); "guard" takes every route, as the iPad client must.
final class ProbeTunnelProvider: NEPacketTunnelProvider {
    private var probe: Probe?

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        let config = (protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration ?? [:]
        guard let data = config["config"] as? Data, let probeConfig = try? JSONDecoder().decode(ProbeConfig.self, from: data) else {
            ProbeFiles.append("unknown-ext", "✗ startTunnel without a probe config")
            completionHandler(NSError(domain: "LinkProbe", code: 1, userInfo: [NSLocalizedDescriptionKey: "No probe config"]))
            return
        }
        let guardMode = config["guard"] as? Bool ?? false
        let includeAll = (protocolConfiguration as? NETunnelProviderProtocol)?.includeAllNetworks ?? false
        ProbeFiles.append(probeConfig.me, "startTunnel: guard \(guardMode), includeAllNetworks \(includeAll)")

        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "10.255.254.1")
        let ipv4 = NEIPv4Settings(addresses: ["10.255.254.2"], subnetMasks: ["255.255.255.255"])
        if guardMode {
            ipv4.includedRoutes = [NEIPv4Route.default()]
            let ipv6 = NEIPv6Settings(addresses: ["fd00:ffff::2"], networkPrefixLengths: [128])
            ipv6.includedRoutes = [NEIPv6Route.default()]
            settings.ipv6Settings = ipv6
            settings.dnsSettings = NEDNSSettings(servers: ["10.255.254.1"])
        } else {
            ipv4.includedRoutes = [NEIPv4Route(destinationAddress: "10.255.254.1", subnetMask: "255.255.255.255")]
        }
        settings.ipv4Settings = ipv4
        settings.mtu = 1400

        setTunnelNetworkSettings(settings) { [weak self] error in
            guard let self else { return }
            if let error {
                ProbeFiles.append(probeConfig.me, "✗ tunnel settings rejected: \(error)")
                completionHandler(error)
                return
            }
            let probe = Probe(config: probeConfig)
            self.probe = probe
            probe.start()
            probe.note("tunnel up, \(guardMode ? "GUARD mode: every route goes into the tunnel" : "light mode: routes nothing")")
            self.drain()
            completionHandler(nil)
        }
    }

    /// Packets the tunnel captured: counted and dropped (nowhere to send them).
    private func drain() {
        packetFlow.readPackets { [weak self] packets, _ in
            self?.probe?.countCaptured(packets)
            self?.drain()
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        probe?.note("tunnel stopping, reason \(reason.rawValue)")
        probe?.stop()
        probe = nil
        completionHandler()
    }

    // iOS calls these when the device sleeps (screen locked and off) and wakes.
    override func sleep(completionHandler: @escaping () -> Void) {
        probe?.note("💤 device sleeping")
        completionHandler()
    }

    override func wake() { probe?.note("☀︎ device woke") }
}
