import Foundation

/// Exported XPC object. Serialises all engine calls on one queue.
final class HelperService: NSObject, PassthroughHelperProtocol {
    private let engine = TunnelEngine()
    private let queue = DispatchQueue(label: "dev.dpatel.passthrough.helper")
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
            if self.owner == id {
                HelperLog.info("owning client disconnected; stopping tunnel")
                self.engine.stop()
                self.owner = nil
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
            } catch {
                HelperLog.error("start failed: \(error.localizedDescription)")
                self.engine.stop()
                reply(false, error.localizedDescription)
            }
        }
    }

    func stopTunnel(reply: @escaping () -> Void) {
        queue.async {
            self.engine.stop()
            self.owner = nil
            reply()
        }
    }

    func getStatus(reply: @escaping ([String: Any]) -> Void) {
        queue.async {
            reply(self.engine.status())
        }
    }

    func quit() {
        queue.async {
            if self.sleepDisabled { self.applyDisableSleep(false) }
            self.engine.stop()
            HelperLog.info("quit requested")
            exit(0)
        }
    }
}
