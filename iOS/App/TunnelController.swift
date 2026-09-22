import Foundation
import NetworkExtension
import PassthroughCore

/// Thin wrapper over NETunnelProviderManager for the packet tunnel extension
/// that hosts the proxy in the background.
final class TunnelController {
    static let providerBundleID = "dev.dpatel.passthrough.ios.tunnel"
    private var manager: NETunnelProviderManager?
    private var observer: NSObjectProtocol?
    var onStatusChange: ((NEVPNStatus) -> Void)?

    var status: NEVPNStatus { manager?.connection.status ?? .invalid }

    func load() async throws {
        let managers = try await NETunnelProviderManager.loadAllFromPreferences()
        manager = managers.first { ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == Self.providerBundleID } ?? managers.first
        observe()
    }

    private func observe() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        guard let manager else { return }
        observer = NotificationCenter.default.addObserver(forName: .NEVPNStatusDidChange, object: manager.connection, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.onStatusChange?(self.status)
        }
    }

    func configure(deviceName: String, cellularOnly: Bool, allowUDP: Bool, socksPort: UInt16, controlPort: UInt16) async throws {
        if manager == nil { try await load() }
        let manager = self.manager ?? NETunnelProviderManager()
        let proto = (manager.protocolConfiguration as? NETunnelProviderProtocol) ?? NETunnelProviderProtocol()
        proto.providerBundleIdentifier = Self.providerBundleID
        proto.serverAddress = "USB"
        proto.providerConfiguration = [
            "deviceName": deviceName,
            "cellularOnly": cellularOnly,
            "allowUDP": allowUDP,
            "socksPort": Int(socksPort),
            "controlPort": Int(controlPort),
        ]
        proto.disconnectOnSleep = false
        manager.protocolConfiguration = proto
        manager.localizedDescription = "Passthrough"
        manager.isEnabled = true
        try await manager.saveToPreferences()
        try await manager.loadFromPreferences()
        self.manager = manager
        observe()
    }

    func start() throws {
        guard let manager else { throw NSError(domain: "Passthrough", code: 2, userInfo: [NSLocalizedDescriptionKey: "Tunnel not configured"]) }
        try manager.connection.startVPNTunnel(options: nil)
    }

    func stop() {
        manager?.connection.stopVPNTunnel()
    }

    func fetchStats() async -> ProviderStats? {
        guard let session = manager?.connection as? NETunnelProviderSession, session.status == .connected else { return nil }
        return await withCheckedContinuation { continuation in
            do {
                try session.sendProviderMessage(Data("stats".utf8)) { data in
                    guard let data, let stats = try? JSONDecoder().decode(ProviderStats.self, from: data) else {
                        continuation.resume(returning: nil); return
                    }
                    continuation.resume(returning: stats)
                }
            } catch {
                continuation.resume(returning: nil)
            }
        }
    }
}
