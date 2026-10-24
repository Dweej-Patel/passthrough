import Foundation
import HelperLogic

/// Exported XPC object. Serialises all engine calls on one queue.
final class HelperService: NSObject, PassthroughHelperProtocol {
    private let engine = TunnelEngine()
    private let queue = DispatchQueue(label: "\(HelperConstants.identifier).helper")
    private lazy var vpn = VPNEngine(queue: queue, tunnel: engine)
    private var vpnOwner: UUID?
    private var owner: UUID?
    /// Connections still open (`ClientID`), kept on `queue` in the order
    /// arrivals and departures happened.
    private var clients: Set<UUID> = []
    private var sleepDisabled = false

    func clientArrived(_ id: UUID) {
        queue.async { self.clients.insert(id) }
    }

    /// Whether a start's caller is still connected. Asked on `queue`: its
    /// connection may have closed between the call and here, and then
    /// `clientGone` has already run for it, so ownership recorded now would
    /// never be released. Such a start is refused instead.
    private func isConnected(_ caller: UUID?) -> Bool {
        caller.map(clients.contains) ?? false
    }

    /// If the app that started the tunnel goes away, tear the tunnel down so the
    /// Mac never sits on a dead default route.
    func clientGone(_ id: UUID) {
        queue.async {
            self.clients.remove(id)
            if self.vpnOwner == id, self.vpn.isActive {
                // Not a stopVPN: the app crashed or was killed (a clean quit
                // turns the VPN off first). The kill switch, if on, holds.
                HelperLog.info("owning client disconnected; stopping the VPN session")
                self.vpn.hold()
                self.vpnOwner = nil
            }
            if self.owner == id {
                HelperLog.info("owning client disconnected; stopping tunnel")
                self.engine.stop()
                self.owner = nil
                self.vpn.underlayChanged()
            }
            if self.clients.isEmpty && HotspotGuard.isOn {
                HelperLog.info("last client gone; lifting the hotspot guard")
                HotspotGuard.set(false)
            }
            if self.clients.isEmpty && self.sleepDisabled {
                HelperLog.info("last client gone; re-enabling system sleep")
                self.applyDisableSleep(false)
            }
        }
    }

    func setDisableSleep(_ on: Bool, reply: @escaping (Bool) -> Void) {
        queue.async {
            self.applyDisableSleep(on)
            reply(self.sleepDisabled == on)
        }
    }

    /// Runs `pmset -a disablesleep <0|1>`; keeps the Mac awake even with the lid shut.
    private func applyDisableSleep(_ on: Bool) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["-a", "disablesleep", on ? "1" : "0"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run(); process.waitUntilExit()
            if process.terminationStatus == 0 {
                sleepDisabled = on
                HelperLog.info("system sleep \(on ? "disabled (lid-close stays awake)" : "enabled")")
            } else {
                HelperLog.warn("pmset disablesleep failed status \(process.terminationStatus)")
            }
        } catch {
            HelperLog.warn("pmset failed: \(error.localizedDescription)")
        }
    }

    func getVersion(reply: @escaping (String) -> Void) {
        reply(HelperConstants.version)
    }

    func startTunnel(configuration: [String: Any], reply: @escaping (Bool, String) -> Void) {
        let caller = ClientID.current()
        queue.async {
            guard self.isConnected(caller) else { reply(false, "The app disconnected before the tunnel started"); return }
            var config = TunnelEngine.Config()
            do {
                // Checked, never converted blindly: UInt16(70000) would crash
                // the helper, and the rest reaches ifconfig and configd.
                config.socksPort = try XPCInput.port(configuration, TunnelConfigKey.socksPort, default: 17890)
                config.username = try XPCInput.string(configuration, TunnelConfigKey.username, maxLength: 64, default: "")
                config.password = try XPCInput.string(configuration, TunnelConfigKey.password, maxLength: 64, default: "")
                config.ipv6 = try XPCInput.bool(configuration, TunnelConfigKey.ipv6, default: true)
                config.dns = try XPCInput.ipAddresses(configuration, TunnelConfigKey.dns, maxCount: 8, default: ["1.1.1.1", "1.0.0.1"])
                config.mtu = try XPCInput.integer(configuration, TunnelConfigKey.mtu, in: 576...65535, default: 8500)
            } catch {
                reply(false, error.localizedDescription); return
            }
            let safe = { (s: String) in s.count <= 64 && s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "+/=-_".contains($0)) } }
            guard safe(config.username), safe(config.password) else { reply(false, "Invalid credentials format"); return }
            do {
                try self.engine.start(config)
                self.owner = caller
                reply(true, self.engine.interfaceName ?? "")
                self.vpn.underlayChanged()
            } catch {
                HelperLog.error("start failed: \(error.localizedDescription)")
                self.engine.stop()
                reply(false, error.localizedDescription)
            }
        }
    }

    func stopTunnel(reply: @escaping () -> Void) {
        queue.async {
            let wasRunning = self.engine.isRunning
            self.engine.stop()
            self.owner = nil
            reply()
            if wasRunning { self.vpn.underlayChanged() }
        }
    }

    func setTunnelIPv6(_ available: Bool, reply: @escaping () -> Void) {
        queue.async {
            self.engine.setIPv6Available(available)
            reply()
        }
    }

    func setHotspotGuard(_ on: Bool, reply: @escaping () -> Void) {
        queue.async {
            HotspotGuard.set(on)
            reply()
        }
    }

    func phoneNetworkChanged(reply: @escaping () -> Void) {
        queue.async {
            self.vpn.phoneNetworkChanged()
            reply()
        }
    }

    func getStatus(reply: @escaping ([String: Any]) -> Void) {
        queue.async {
            var status = self.engine.status()
            status[VPNStatusKey.vpn] = self.vpn.status()
            status[TunnelStatusKey.helperPath] = Bundle.main.executableURL?.path ?? ""
            reply(status)
        }
    }

    func startVPN(configuration: [String: Any], reply: @escaping (Bool, String) -> Void) {
        let caller = ClientID.current()
        queue.async {
            guard self.isConnected(caller) else { reply(false, "The app disconnected before the VPN started"); return }
            guard let engineName = configuration[VPNConfigKey.engine] as? String,
                  let engine = VPNEngine.Config.Engine(rawValue: engineName),
                  let text = try? XPCInput.string(configuration, VPNConfigKey.config, maxLength: 1 << 20, allowNewlines: true, default: ""),
                  !text.isEmpty else {
                reply(false, "Invalid VPN configuration"); return
            }
            var config = VPNEngine.Config(engine: engine, name: engineName, configText: text)
            do {
                config.name = try XPCInput.string(configuration, VPNConfigKey.name, maxLength: 256, default: engineName)
                // Credentials go to openvpn on stdin, a line each: no newlines.
                config.username = try XPCInput.string(configuration, VPNConfigKey.username, maxLength: 512, default: "")
                config.password = try XPCInput.string(configuration, VPNConfigKey.password, maxLength: 512, default: "")
                config.killSwitch = try XPCInput.bool(configuration, VPNConfigKey.killSwitch, default: true)
                config.blockIPv6 = try XPCInput.bool(configuration, VPNConfigKey.blockIPv6, default: true)
                config.allowLocalNetwork = try XPCInput.bool(configuration, VPNConfigKey.allowLocalNetwork, default: true)
                config.phoneLink = try KillSwitchRules.PhoneLink.read(configuration, portKey: VPNConfigKey.phoneLinkPort,
                                                                      peersKey: VPNConfigKey.phoneLinkPeers)
            } catch {
                reply(false, error.localizedDescription); return
            }
            do {
                try self.vpn.start(config)
                self.vpnOwner = caller
                reply(true, "")
            } catch {
                HelperLog.error("vpn start failed: \(error.localizedDescription)")
                // A kill switch that was already holding (a reconnect after a
                // crash) keeps holding; turning the VPN off lifts it.
                self.vpn.abandonStart()
                reply(false, error.localizedDescription)
            }
        }
    }

    /// Who listens on Screen Sharing's port, judged as root (only root sees
    /// every process's sockets). Off the queue: a walk of the process table
    /// must not hold up the tunnel's calls.
    func checkScreenSharing(reply: @escaping (Int) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let owners = ProcessTable.tcpListeners(port: ScreenSharingCheck.port)
            let verdict = ScreenSharingOwners.verdict(owners)
            if verdict == .impostor {
                let who = owners.map { "pid \($0.pid) \($0.path ?? "?") uid \($0.uid.map(String.init) ?? "?")" }.joined(separator: ", ")
                HelperLog.warn("port \(ScreenSharingCheck.port) is held by something other than Screen Sharing: \(who)")
            }
            reply(verdict.rawValue)
        }
    }

    func setPhoneLink(configuration: [String: Any], reply: @escaping () -> Void) {
        queue.async {
            do {
                let link = try KillSwitchRules.PhoneLink.read(configuration, portKey: VPNConfigKey.phoneLinkPort,
                                                              peersKey: VPNConfigKey.phoneLinkPeers)
                self.vpn.setPhoneLink(link)
            } catch {
                HelperLog.warn("phone link refused: \(error.localizedDescription)")
            }
            reply()
        }
    }

    func stopVPN(reply: @escaping () -> Void) {
        queue.async {
            self.vpn.stop()
            self.vpnOwner = nil
            reply()
        }
    }

    func quit() {
        queue.async {
            if self.sleepDisabled { self.applyDisableSleep(false) }
            // The app replaces an outdated helper with quit(): a VPN with its
            // kill switch on stays blocked across the swap (the new helper
            // keeps it, the app reconnects).
            self.vpn.hold()
            self.engine.stop()
            HelperLog.info("quit requested")
            exit(0)
        }
    }
}
