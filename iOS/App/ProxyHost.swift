import Foundation
import UIKit
import NetworkExtension
import PassthroughCore

/// Where the proxy runs: in the VPN extension, which keeps serving in the
/// background, or in this app's own process while it stays open.
@MainActor
protocol ProxyHost: AnyObject {
    /// State changes, including ones the host makes by itself (iOS stopping the extension).
    var onStateChange: ((HostState) -> Void)? { get set }
    func start(_ options: PassthroughService.Options) async throws
    func stop() async
    /// Nil when the host isn't serving or didn't answer.
    func stats() async -> ProviderStats?
}

enum HostState { case stopped, starting, running, stopping }

/// Runs the service inside the packet tunnel extension.
@MainActor
final class ExtensionHost: ProxyHost {
    var onStateChange: ((HostState) -> Void)?
    private let tunnel = TunnelController()

    init() {
        tunnel.onStatusChange = { [weak self] status in Task { @MainActor in self?.report(status) } }
    }

    /// Picks up a tunnel configuration saved earlier (and a running extension).
    func load() async throws {
        try await tunnel.load()
        report(tunnel.status)
    }

    func start(_ options: PassthroughService.Options) async throws {
        try await tunnel.configure(options)
        try tunnel.start()
    }

    func stop() async { await tunnel.stop() }

    func stats() async -> ProviderStats? { await tunnel.fetchStats() }

    private func report(_ status: NEVPNStatus) {
        switch status {
        case .connected: onStateChange?(.running)
        case .connecting, .reasserting: onStateChange?(.starting)
        case .disconnecting: onStateChange?(.stopping)
        case .disconnected, .invalid: onStateChange?(.stopped)
        @unknown default: break
        }
    }
}

/// Runs the service in the app process; iOS suspends it once the app leaves the screen.
@MainActor
final class InProcessHost: ProxyHost {
    var onStateChange: ((HostState) -> Void)?
    private let defaults: UserDefaults
    private let registry: PairingRegistry
    private var service: PassthroughService?

    init(defaults: UserDefaults, registry: PairingRegistry) {
        self.defaults = defaults
        self.registry = registry
    }

    func start(_ options: PassthroughService.Options) async throws {
        let service = PassthroughService.sharing(defaults, registry: registry, options: options, hosting: "foreground")
        try service.start()
        self.service = service
        UIApplication.shared.isIdleTimerDisabled = true
        ptLog(.info, "Serving in the foreground. Keep Passthrough open.")
        onStateChange?(.running)
    }

    func stop() async {
        service?.stop()
        service = nil
        UIApplication.shared.isIdleTimerDisabled = false
        onStateChange?(.stopped)
    }

    func stats() async -> ProviderStats? { service?.stats() }
}
