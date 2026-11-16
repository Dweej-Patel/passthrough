import Foundation
import Network
import NetworkExtension
import notify
import PassthroughCore

/// An iPad's "Internet through iPhone": the switch, the iPhone it's paired
/// with, and how the link is doing (from the tunnel extension).
@MainActor
final class HotspotModel: ObservableObject {
    /// What the switch shows.
    enum Phase: Equatable {
        /// Not paired with an iPhone yet.
        case unpaired
        case off
        /// On, but this iPad isn't on an iPhone's hotspot: it uses its network
        /// as usual, and the tunnel starts by itself once it joins the hotspot.
        case standby
        case starting
        /// On and linked: traffic goes through the iPhone.
        case online
        /// On, waiting for the iPhone to dial in (or come back). Offline on purpose.
        case waiting
        /// On, but the iPhone doesn't know this iPad (any more), or an update is needed.
        case refused(String)
        case failed(String)
        var isOn: Bool {
            switch self { case .unpaired, .off, .failed: false; default: true }
        }
    }

    @Published private(set) var upstream: UpstreamPhone?
    @Published private(set) var tunnel: NEVPNStatus = .invalid
    @Published private(set) var status: HotspotStatus?
    /// On the iPhone's Personal Hotspot (172.20.10.0/28) right now.
    @Published private(set) var onPhoneHotspot = false
    @Published private(set) var startError: String?
    /// The switch is on: iOS starts the tunnel whenever this iPad is on an iPhone's hotspot.
    @Published private(set) var armed = false

    let store = UpstreamPhoneStore.shared()
    private let controller = TunnelController()
    private let pathMonitor = NWPathMonitor(requiredInterfaceType: .wifi)
    private var ticker: Timer?
    private var loaded = false

    init() {
        controller.onStatusChange = { [weak self] status in
            Task { @MainActor in
                self?.tunnel = status
                if status == .disconnected || status == .invalid { self?.status = nil }
            }
        }
        pathMonitor.pathUpdateHandler = { _ in
            Task { @MainActor [weak self] in self?.onPhoneHotspot = HotspotModel.onHotspotNetwork() }
        }
        pathMonitor.start(queue: DispatchQueue(label: "\(PassthroughProtocol.identifier).hotspot-path"))
    }

    var phase: Phase {
        if let startError { return .failed(startError) }
        guard upstream != nil else { return .unpaired }
        switch tunnel {
        case .invalid, .disconnected: return armed ? .standby : .off
        case .connecting, .disconnecting: return .starting
        case .connected, .reasserting:
            switch status?.phase {
            case .online?: return .online
            case .refused?: return .refused(status?.message ?? "The iPhone no longer knows this iPad.")
            default: return .waiting
            }
        @unknown default: return .off
        }
    }

    var phoneName: String { status?.phoneName ?? upstream?.name ?? "iPhone" }

    func load() async {
        upstream = store.load()
        onPhoneHotspot = Self.onHotspotNetwork()
        if !loaded {
            loaded = true
            try? await controller.load()
            await controller.updateClientRules()
            ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor in await self?.tick() }
            }
        }
        tunnel = controller.status
        armed = controller.onDemandEnabled
        await tick()
    }

    func setOn(_ on: Bool) {
        startError = nil
        // Only the app can raise the Local Network prompt; the extension needs the answer.
        if on { LocalNetworkPermission.request() }
        Task {
            if on {
                do {
                    try await controller.configureClient(name: ThisDevice.displayName)
                    armed = true
                    // Off the hotspot, iOS starts it once this iPad joins one.
                    if HotspotModel.onHotspotNetwork() { try controller.start() }
                } catch {
                    startError = error.localizedDescription
                }
            } else {
                await controller.stop()
                armed = false
            }
        }
    }

    /// Stores a new iPhone (paired here, or introduced by a Mac) and has a
    /// running tunnel use it.
    /// A new iPhone, already saved to `store` (by the pairing listener).
    func adopted(_ phone: UpstreamPhone) {
        upstream = phone
        notify_post(PairingRegistry.changedNotification)
    }

    /// Forgets the iPhone: the switch goes off, and the iPad uses the hotspot like any device.
    func forget() {
        setOn(false)
        store.forget()
        upstream = nil
        notify_post(PairingRegistry.changedNotification)
    }

    private func tick() async {
        guard tunnel == .connected || tunnel == .reasserting else { return }
        if let data = await controller.message(HotspotTunnel.statusMessage),
           let status = try? JSONDecoder().decode(HotspotStatus.self, from: data) {
            self.status = status
        }
    }

    /// Whether this iPad's Wi-Fi address is on an iPhone's Personal Hotspot.
    nonisolated static func onHotspotNetwork() -> Bool {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return false }
        defer { freeifaddrs(list) }
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            guard let address = entry.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
                  String(cString: entry.ifa_name).hasPrefix("en") else { continue }
            var ipv4 = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
            var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            guard inet_ntop(AF_INET, &ipv4, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil else { continue }
            if WirelessLink.isHotspotAddress(.hostPort(host: .init(String(cString: buffer)), port: 1)) { return true }
        }
        return false
    }
}
