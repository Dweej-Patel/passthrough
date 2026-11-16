import Foundation
import Network
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
    /// tun2socks, and what it was started with (it signs every stream with
    /// the token's password, so a new token restarts it).
    private var engine: Engine?
    private var tunFD: Int32 = -1
    private var clientID = ""
    private let mtu = 1500

    private struct Engine {
        let thread: Thread
        let exited: DispatchSemaphore
        let token: String
    }

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

    /// `onLinked`: whether the iPhone is linked and has said welcome, on each change.
    func start(name: String, onLinked: @escaping (Bool) -> Void = { _ in }) throws {
        let store = UpstreamPhoneStore.shared()
        guard let phone = store.load() else {
            throw NSError(domain: "Passthrough", code: 10, userInfo: [NSLocalizedDescriptionKey: "Pair this iPad with an iPhone first."])
        }
        let clientID = store.clientID()
        let client = HotspotClient(clientID: clientID, name: name, identity: {
            try MacIdentity.loadOrCreate(label: HotspotTunnel.identityLabel, accessGroup: PassthroughProtocol.appGroup)
        }, upstream: { store.load() }, provenAddresses: FileProvenAddressStore.inApplicationSupport(named: "ipad-proven-addresses"))
        var linked = false
        client.onStatusChange = { status in
            let up = status.phase == .online
            guard up != linked else { return }
            linked = up
            onLinked(up)
        }
        try client.start()
        self.client = client

        let fd = passthrough_utun_fd()
        guard fd >= 0 else {
            throw NSError(domain: "Passthrough", code: 11, userInfo: [NSLocalizedDescriptionKey: "The tunnel's interface wasn't found."])
        }
        tunFD = fd
        self.clientID = clientID
        startEngine(token: phone.token)
        ptLog(.info, "Internet through \(phone.name): waiting for it to dial in")
    }

    private func startEngine(token: String) {
        guard let client else { return }
        let config = Self.engineConfig(mtu: mtu, port: client.localPort, username: clientID,
                                       password: ControlAuth.socksPassword(token: token))
        let fd = tunFD
        let exited = DispatchSemaphore(value: 0)
        let thread = Thread {
            let bytes = Array(config.utf8)
            let result = bytes.withUnsafeBufferPointer { hev_socks5_tunnel_main_from_str($0.baseAddress, UInt32($0.count), fd) }
            ptLog(result == 0 ? .info : .error, "tun2socks stopped (\(result))")
            exited.signal()
        }
        thread.name = "tun2socks"
        thread.stackSize = 4 << 20
        thread.start()
        engine = Engine(thread: thread, exited: exited, token: token)
    }

    /// Stops tun2socks and waits for it to finish (it keeps global state, so a
    /// new one may start only after). The tunnel's descriptor stays open: hev
    /// closes only descriptors it opened itself.
    private func stopEngine() async {
        guard let engine else { return }
        self.engine = nil
        hev_socks5_tunnel_quit()
        let exited = engine.exited
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                _ = exited.wait(timeout: .now() + 5)
                continuation.resume()
            }
        }
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
    /// A new token means new SOCKS credentials, so tun2socks restarts with them.
    func credentialsChanged() {
        client?.credentialsChanged()
        guard let engine, let phone = UpstreamPhoneStore.shared().load(), phone.token != engine.token else { return }
        ptLog(.info, "Internet through \(phone.name): new pairing, restarting tun2socks")
        Task {
            await stopEngine()
            guard client != nil, self.engine == nil else { return }
            startEngine(token: phone.token)
        }
    }

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

/// Reports, once, that this iPad has left the iPhone's hotspot: not linked
/// to the iPhone, and Wi-Fi down or on a network with none of the hotspot's signs
/// (`WirelessLink.leftPhoneHotspot`), two checks in a row so a moment between
/// networks doesn't count. Checked on every Wi-Fi change, and every 30
/// seconds in case a change goes unreported. All state lives on its own queue.
final class HotspotPresenceWatch: @unchecked Sendable {
    private let queue = DispatchQueue(label: "\(PassthroughProtocol.identifier).hotspot-watch")
    private let onLeft: @Sendable () -> Void
    private let isLinked: @Sendable () -> Bool
    private var reader: WiFiPathReader?
    private var timer: DispatchSourceTimer?
    private var misses = 0
    private var checking = false
    private var done = false

    /// `isLinked`: the iPhone is linked right now, which proves the iPad is on its hotspot.
    init(isLinked: @escaping @Sendable () -> Bool, onLeft: @escaping @Sendable () -> Void) {
        self.isLinked = isLinked
        self.onLeft = onLeft
    }

    func start() {
        queue.async { [self] in
            let reader = WiFiPathReader()
            reader.onChange = { [weak self] _ in self?.queue.async { self?.scheduleCheck(after: 2) } }
            self.reader = reader
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + 30, repeating: 30, leeway: .seconds(5))
            timer.setEventHandler { [weak self] in self?.scheduleCheck(after: 0) }
            timer.resume()
            self.timer = timer
        }
    }

    func cancel() {
        queue.async { [self] in finish() }
    }

    /// On the queue.
    private func scheduleCheck(after delay: TimeInterval) {
        guard !done, !checking else { return }
        checking = true
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in self?.check() }
    }

    private func check() {
        checking = false
        guard !done, let wifi = reader?.facts else { return }
        guard !isLinked() else { misses = 0; return }
        let known = HotspotTunnel.knownHotspotDNS(UserDefaults(suiteName: PassthroughProtocol.appGroup) ?? .standard)
        guard WirelessLink.leftPhoneHotspot(wifi: wifi, knownHotspotDNS: known) else { misses = 0; return }
        misses += 1
        guard misses >= 2 else { return scheduleCheck(after: 3) }
        finish()
        ptLog(.info, "Internet through iPhone: \(WirelessLink.networkSummary(wifi: wifi, dnsServers: []))")
        onLeft()
    }

    private func finish() {
        done = true
        reader?.cancel(); reader = nil
        timer?.cancel(); timer = nil
    }
}
