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

    func version() async -> String? {
        await withCheckedContinuation { cont in
            guard let proxy = proxy() else { cont.resume(returning: nil); return }
            let done = Locked(false)
            proxy.getVersion { v in if !done.exchange(true) { cont.resume(returning: v) } }
            DispatchQueue.global().asyncAfter(deadline: .now() + 4) { if !done.exchange(true) { cont.resume(returning: nil) } }
        }
    }

    func startTunnel(_ config: TunnelConfig) async throws -> String {
        let dict: [String: Any] = [
            TunnelConfigKey.socksPort: Int(config.socksPort),
            TunnelConfigKey.username: config.username,
            TunnelConfigKey.password: config.password,
            TunnelConfigKey.ipv6: config.ipv6,
            TunnelConfigKey.dns: config.dns,
            TunnelConfigKey.mtu: config.mtu,
        ]
        return try await withCheckedThrowingContinuation { cont in
            guard let proxy = proxy() else {
                cont.resume(throwing: HelperError.unreachable); return
            }
            let done = Locked(false)
            proxy.startTunnel(configuration: dict) { ok, detail in
                guard !done.exchange(true) else { return }
                ok ? cont.resume(returning: detail) : cont.resume(throwing: HelperError.startFailed(detail))
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 15) {
                if !done.exchange(true) { cont.resume(throwing: HelperError.unreachable) }
            }
        }
    }

    func stopTunnel() async {
        await withCheckedContinuation { cont in
            guard let proxy = proxy() else { cont.resume(); return }
            let done = Locked(false)
            proxy.stopTunnel { if !done.exchange(true) { cont.resume() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + 6) { if !done.exchange(true) { cont.resume() } }
        }
    }

    struct VPNConfig {
        var engine: String
        var name: String
        var config: String
        var username: String
        var password: String
        var killSwitch: Bool
    }

    func startVPN(_ config: VPNConfig) async throws {
        let dict: [String: Any] = [
            VPNConfigKey.engine: config.engine,
            VPNConfigKey.name: config.name,
            VPNConfigKey.config: config.config,
            VPNConfigKey.username: config.username,
            VPNConfigKey.password: config.password,
            VPNConfigKey.killSwitch: config.killSwitch,
        ]
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            guard let proxy = proxy() else { cont.resume(throwing: HelperError.unreachable); return }
            let done = Locked(false)
            proxy.startVPN(configuration: dict) { ok, detail in
                guard !done.exchange(true) else { return }
                ok ? cont.resume() : cont.resume(throwing: HelperError.startFailed(detail))
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 20) {
                if !done.exchange(true) { cont.resume(throwing: HelperError.unreachable) }
            }
        }
    }

    func stopVPN() async {
        await withCheckedContinuation { cont in
            guard let proxy = proxy() else { cont.resume(); return }
            let done = Locked(false)
            proxy.stopVPN { if !done.exchange(true) { cont.resume() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + 8) { if !done.exchange(true) { cont.resume() } }
        }
    }

    func setDisableSleep(_ on: Bool) async -> Bool {
        await withCheckedContinuation { cont in
            guard let proxy = proxy() else { cont.resume(returning: false); return }
            let done = Locked(false)
            proxy.setDisableSleep(on) { ok in if !done.exchange(true) { cont.resume(returning: ok) } }
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) { if !done.exchange(true) { cont.resume(returning: false) } }
        }
    }

    func status() async -> [String: Any] {
        await withCheckedContinuation { cont in
            guard let proxy = proxy() else { cont.resume(returning: [:]); return }
            let done = Locked(false)
            proxy.getStatus { s in if !done.exchange(true) { cont.resume(returning: s) } }
            DispatchQueue.global().asyncAfter(deadline: .now() + 4) { if !done.exchange(true) { cont.resume(returning: [:]) } }
        }
    }

    func quitHelper() {
        // quit() is a one-way message; invalidating the connection immediately
        // can cancel it before delivery, leaving the stale helper running. Send
        // it and let the connection drop naturally when the helper exits (its
        // invalidation handler clears our reference), so the next call respawns
        // the updated binary via launchd.
        proxy()?.quit()
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

final class Locked<T>: @unchecked Sendable {
    private var value: T
    private let lock = NSLock()
    init(_ value: T) { self.value = value }
    func exchange(_ new: T) -> T { lock.lock(); defer { lock.unlock() }; let old = value; value = new; return old }
}
