import Foundation
import NetworkExtension
import PassthroughCore
import PhoneTransport
import CUtun
import HevSocks5Tunnel

/// The extension on an iPad: "Internet through iPhone". It takes every route
/// (the app sets includeAllNetworks, so nothing leaves over the hotspot by
/// itself), and tun2socks sends the iPad's traffic as SOCKS streams over the
/// link the iPhone dials in on (`HotspotClient`). With the link down, streams
/// fail at once: the iPad is offline on purpose until the iPhone is back.
@MainActor
final class HotspotRole {
    private var client: HotspotClient?
    private var engine: Thread?
    private let mtu = 1500

    /// The settings to apply before `start`.
    nonisolated static func settings(ipv6: Bool) -> NEPacketTunnelNetworkSettings {
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "10.255.253.1")
        let ipv4 = NEIPv4Settings(addresses: [HotspotTunnel.ipv4Address], subnetMasks: ["255.255.255.0"])
        ipv4.includedRoutes = [NEIPv4Route.default()]
        settings.ipv4Settings = ipv4
        let dns = NEDNSSettings(servers: [HotspotTunnel.dnsAddress])
        dns.matchDomains = [""]
        settings.dnsSettings = dns
        settings.mtu = 1500
        return settings
    }

    func start(name: String) throws {
        let store = UpstreamPhoneStore.shared()
        guard let phone = store.load() else {
            throw NSError(domain: "Passthrough", code: 10, userInfo: [NSLocalizedDescriptionKey: "Pair this iPad with an iPhone first."])
        }
        let clientID = store.clientID()
        let client = HotspotClient(clientID: clientID, name: name, identity: {
            try MacIdentity.loadOrCreate(label: HotspotTunnel.identityLabel, accessGroup: PassthroughProtocol.appGroup)
        }, upstream: { store.load() }, provenAddresses: FileProvenAddressStore.inApplicationSupport(named: "ipad-proven-addresses"))
        try client.start()
        self.client = client

        let fd = passthrough_utun_fd()
        guard fd >= 0 else {
            throw NSError(domain: "Passthrough", code: 11, userInfo: [NSLocalizedDescriptionKey: "The tunnel's interface wasn't found."])
        }
        let config = Self.engineConfig(mtu: mtu, port: client.localPort, username: clientID,
                                       password: ControlAuth.socksPassword(token: phone.token))
        let engine = Thread {
            let bytes = Array(config.utf8)
            let result = bytes.withUnsafeBufferPointer { hev_socks5_tunnel_main_from_str($0.baseAddress, UInt32($0.count), fd) }
            ptLog(result == 0 ? .info : .error, "tun2socks stopped (\(result))")
        }
        engine.name = "tun2socks"
        engine.stackSize = 4 << 20
        engine.start()
        self.engine = engine
        ptLog(.info, "Internet through \(phone.name): waiting for it to dial in")
    }

    func stop() {
        if engine != nil { hev_socks5_tunnel_quit() }
        engine = nil
        client?.stop()
        client = nil
    }

    func status() -> HotspotStatus {
        guard let client else { return HotspotStatus(phase: .waiting) }
        var status = client.status
        let counters = client.counters
        status.rx = counters.rx
        status.tx = counters.tx
        return status
    }

    /// The iPhone was re-paired or forgotten in the app (another process).
    func credentialsChanged() { client?.credentialsChanged() }

    /// hev's settings, kept small for the extension's memory limit. The
    /// credentials are generated (UUID, base64url), so quoting is safe.
    nonisolated static func engineConfig(mtu: Int, port: UInt16, username: String, password: String) -> String {
        """
        tunnel:
          mtu: \(mtu)
          ipv4: \(HotspotTunnel.ipv4Address)
        socks5:
          port: \(port)
          address: 127.0.0.1
          udp: 'tcp'
          username: '\(username)'
          password: '\(password)'
        misc:
          log-level: warn
          task-stack-size: 24576
          tcp-buffer-size: 16384
          max-session-count: 256
          connect-timeout: 10000
          tcp-read-write-timeout: 300000
          udp-read-write-timeout: 60000
        """ + "\n"
    }
}
