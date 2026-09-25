import Foundation
import ServiceManagement
import PassthroughCore

/// Registers the privileged helper with launchd and talks to it over XPC.
final class HelperClient {
    enum Availability: Equatable {
        case ready
        case needsApproval
        case notRegistered
        case failed(String)
    }

    struct TunnelConfig {
        var socksPort: UInt16
        var username: String
        var password: String
        var ipv6: Bool
        var dns: [String]
        var mtu: Int
    }

    private let service = SMAppService.daemon(plistName: HelperConstants.plistName)
    private var connection: NSXPCConnection?

    var availability: Availability {
        switch service.status {
        case .enabled: return .ready
        case .requiresApproval: return .needsApproval
        case .notRegistered, .notFound: return .notRegistered
        @unknown default: return .failed("Unknown helper state")
        }
    }

    /// Registers the daemon; returns the resulting availability.
    func register() -> Availability {
        do {
            try service.register()
            ptLog(.info, "Helper registered (\(service.status.rawValue))")
        } catch {
            let nsError = error as NSError
            // kSMErrorAlreadyRegistered is fine; anything else is worth surfacing.
            if nsError.code != 3 {
                ptLog(.error, "Helper registration failed: \(error.localizedDescription)")
                return .failed(error.localizedDescription)
            }
        }
        return availability
    }

    func unregister() async {
        try? await service.unregister()
        invalidate()
    }

    /// launchd remembers the bundle that registered the daemon. If this app now
    /// runs from a different location (e.g. moved to /Applications after a dev
    /// build registered it), re-register so the helper launches from here.
    func reregisterIfStale(helperPath: String) async -> Bool {
        let mine = Bundle.main.bundleURL.standardizedFileURL.path
        guard !helperPath.isEmpty, !helperPath.hasPrefix(mine + "/") else { return false }
        ptLog(.warning, "Helper runs from \(helperPath), not this bundle; re-registering")
        try? await service.unregister()
        invalidate()
        do { try service.register() } catch {
            let nsError = error as NSError
            if nsError.code != 3 { ptLog(.error, "Helper re-registration failed: \(error.localizedDescription)"); return false }
        }
        return true
    }

    static func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    private func proxy() -> PassthroughHelperProtocol? {
        if connection == nil {
            let c = NSXPCConnection(machServiceName: HelperConstants.machService, options: .privileged)
            c.remoteObjectInterface = NSXPCInterface(with: PassthroughHelperProtocol.self)
            c.invalidationHandler = { [weak self] in self?.connection = nil }
            c.interruptionHandler = { ptLog(.warning, "Helper connection interrupted") }
            c.resume()
            connection = c
        }
        return connection?.remoteObjectProxyWithErrorHandler { error in
            ptLog(.error, "Helper XPC error: \(error.localizedDescription)")
        } as? PassthroughHelperProtocol
    }

    func invalidate() {
        connection?.invalidate()
        connection = nil
    }

    /// One XPC round trip: `fallback` when the helper is unreachable or silent for `timeout` seconds.
    private func call<T>(timeout: Double, fallback: T, _ body: (PassthroughHelperProtocol, @escaping (T) -> Void) -> Void) async -> T {
        await withCheckedContinuation { cont in
            guard let proxy = proxy() else { cont.resume(returning: fallback); return }
            let done = Locked(false)
            let finish: (T) -> Void = { value in if !done.exchange(true) { cont.resume(returning: value) } }
            body(proxy, finish)
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { finish(fallback) }
        }
    }

    /// A round trip that reports success or the helper's reason for failing.
    private func start(timeout: Double, _ body: (PassthroughHelperProtocol, @escaping (Bool, String) -> Void) -> Void) async throws -> String {
        let result: Result<String, HelperError> = await call(timeout: timeout, fallback: .failure(.unreachable)) { proxy, finish in
            body(proxy) { ok, detail in finish(ok ? .success(detail) : .failure(.startFailed(detail))) }
        }
        return try result.get()
    }

    func version() async -> String? {
        await call(timeout: 4, fallback: nil) { proxy, finish in proxy.getVersion { finish($0) } }
    }

    /// Returns the tunnel's interface name.
    func startTunnel(_ config: TunnelConfig) async throws -> String {
        let dict: [String: Any] = [
            TunnelConfigKey.socksPort: Int(config.socksPort),
            TunnelConfigKey.username: config.username,
            TunnelConfigKey.password: config.password,
            TunnelConfigKey.ipv6: config.ipv6,
            TunnelConfigKey.dns: config.dns,
            TunnelConfigKey.mtu: config.mtu,
        ]
        return try await start(timeout: 15) { proxy, reply in proxy.startTunnel(configuration: dict, reply: reply) }
    }

    func setTunnelIPv6(_ available: Bool) async {
        await call(timeout: 4, fallback: ()) { proxy, finish in proxy.setTunnelIPv6(available) { finish(()) } }
    }

    func phoneNetworkChanged() async {
        await call(timeout: 4, fallback: ()) { proxy, finish in proxy.phoneNetworkChanged { finish(()) } }
    }

    func stopTunnel() async {
        await call(timeout: 6, fallback: ()) { proxy, finish in proxy.stopTunnel { finish(()) } }
    }

    struct VPNConfig {
        var engine: String
        var name: String
        var config: String
        var username: String
        var password: String
        var killSwitch: Bool
        var blockIPv6: Bool
    }

    func startVPN(_ config: VPNConfig) async throws {
        let dict: [String: Any] = [
            VPNConfigKey.engine: config.engine,
            VPNConfigKey.name: config.name,
            VPNConfigKey.config: config.config,
            VPNConfigKey.username: config.username,
            VPNConfigKey.password: config.password,
            VPNConfigKey.killSwitch: config.killSwitch,
            VPNConfigKey.blockIPv6: config.blockIPv6,
        ]
        _ = try await start(timeout: 20) { proxy, reply in proxy.startVPN(configuration: dict, reply: reply) }
    }

    func stopVPN() async {
        await call(timeout: 8, fallback: ()) { proxy, finish in proxy.stopVPN { finish(()) } }
    }

    func setDisableSleep(_ on: Bool) async -> Bool {
        await call(timeout: 5, fallback: false) { proxy, finish in proxy.setDisableSleep(on) { finish($0) } }
    }

    func status() async -> [String: Any] {
        await call(timeout: 4, fallback: [:]) { proxy, finish in proxy.getStatus { finish($0) } }
    }

    func quitHelper() {
        // quit() is a one-way message; invalidating the connection immediately
        // can cancel it before delivery, leaving the stale helper running. Send
        // it and let the connection drop naturally when the helper exits (its
        // invalidation handler clears our reference), so the next call respawns
        // the updated binary via launchd.
        proxy()?.quit()
    }

    /// Registers the helper if it never was; true once launchd runs it.
    func ensureRegistered() -> Bool {
        if availability == .notRegistered { _ = register() }
        return availability == .ready
    }

    /// Restarts a helper older than this app so it runs the bundled binary.
    /// With `mayReregister`, also moves a registration made by another copy of
    /// the app (only safe while nothing routes through the helper).
    func ensureCurrent(mayReregister: Bool) async {
        guard availability == .ready, let v = await version() else { return }
        var restart = false
        if v != HelperConstants.version {
            ptLog(.warning, "Helper version \(v) ≠ \(HelperConstants.version); restarting helper")
            restart = true
        }
        if mayReregister, Bundle.main.bundleURL.path.hasPrefix("/Applications/"),
           let path = await status()[TunnelStatusKey.helperPath] as? String, await reregisterIfStale(helperPath: path) {
            restart = true
        }
        guard restart else { return }
        quitHelper()
        // Wait for launchd to respawn the new binary before we drive it.
        for _ in 0..<10 {
            try? await Task.sleep(for: .milliseconds(400))
            if let nv = await version(), nv == HelperConstants.version {
                ptLog(.info, "Helper upgraded to \(nv)")
                return
            }
        }
        ptLog(.warning, "Helper did not report the expected version after restart")
    }

    enum HelperError: LocalizedError {
        case unreachable
        case startFailed(String)
        var errorDescription: String? {
            switch self {
            case .unreachable: return "The helper did not respond. Check Login Items in System Settings."
            case .startFailed(let why): return why
            }
        }
    }
}
