import Foundation

/// Exported XPC object. Serialises all engine calls on one queue.
final class HelperService: NSObject, PassthroughHelperProtocol {
    private let engine = TunnelEngine()
    private let queue = DispatchQueue(label: "dev.dpatel.passthrough.helper")
    private lazy var vpn = VPNEngine(queue: queue, tunnel: engine)
    private var vpnOwner: ObjectIdentifier?
    private var owner: ObjectIdentifier?
    private var clients: Set<ObjectIdentifier> = []
    private var sleepDisabled = false

    func clientArrived(_ id: ObjectIdentifier) {
        queue.async { self.clients.insert(id) }
    }

    /// If the app that started the tunnel goes away, tear the tunnel down so the
    /// Mac never sits on a dead default route.
    func clientGone(_ id: ObjectIdentifier) {
        queue.async {
            self.clients.remove(id)
            if self.vpnOwner == id, self.vpn.isActive {
                HelperLog.info("owning client disconnected; stopping VPN layer")
                self.vpn.stop()
                self.vpnOwner = nil
            }
            if self.owner == id {
                HelperLog.info("owning client disconnected; stopping tunnel")
                self.engine.stop()
                self.owner = nil
                self.vpn.underlayChanged()
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
        let caller = NSXPCConnection.current().map { ObjectIdentifier($0) }
        queue.async {
            var config = TunnelEngine.Config()
            config.socksPort = UInt16(configuration[TunnelConfigKey.socksPort] as? Int ?? 17890)
            config.username = configuration[TunnelConfigKey.username] as? String ?? ""
            config.password = configuration[TunnelConfigKey.password] as? String ?? ""
            config.ipv6 = configuration[TunnelConfigKey.ipv6] as? Bool ?? true
            config.dns = configuration[TunnelConfigKey.dns] as? [String] ?? ["1.1.1.1", "1.0.0.1"]
            config.mtu = configuration[TunnelConfigKey.mtu] as? Int ?? 8500
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

    func getStatus(reply: @escaping ([String: Any]) -> Void) {
        queue.async {
            var status = self.engine.status()
            status[VPNStatusKey.vpn] = self.vpn.status()
            reply(status)
        }
    }

    func startVPN(configuration: [String: Any], reply: @escaping (Bool, String) -> Void) {
        let caller = NSXPCConnection.current().map { ObjectIdentifier($0) }
        queue.async {
            guard let engineName = configuration[VPNConfigKey.engine] as? String,
                  let engine = VPNEngine.Config.Engine(rawValue: engineName),
                  let text = configuration[VPNConfigKey.config] as? String, !text.isEmpty else {
                reply(false, "Invalid VPN configuration"); return
            }
            var config = VPNEngine.Config(engine: engine, name: configuration[VPNConfigKey.name] as? String ?? engineName, configText: text)
            config.username = configuration[VPNConfigKey.username] as? String ?? ""
            config.password = configuration[VPNConfigKey.password] as? String ?? ""
            config.killSwitch = configuration[VPNConfigKey.killSwitch] as? Bool ?? true
            do {
                try self.vpn.start(config)
                self.vpnOwner = caller
                reply(true, "")
            } catch {
                HelperLog.error("vpn start failed: \(error.localizedDescription)")
                self.vpn.stop()
                reply(false, error.localizedDescription)
            }
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
            self.vpn.stop()
            self.engine.stop()
            HelperLog.info("quit requested")
            exit(0)
        }
    }
}
