import Foundation
import SwiftUI
import Combine
import PassthroughCore

/// Everything the iOS screens observe. Starts the proxy on a `ProxyHost`
/// (the VPN extension, or this process), and owns pairing and usage.
@MainActor
final class AppModel: ObservableObject {
    enum Hosting: String, CaseIterable, Identifiable {
        case background, foreground
        var id: String { rawValue }
        var title: String { self == .background ? "Background (VPN extension)" : "Foreground only" }
    }

    enum ServiceState: Equatable {
        case stopped, starting, running, stopping
        case failed(String)
        var isActive: Bool { self == .starting || self == .running }
    }

    static let groupDefaults = UserDefaults(suiteName: PassthroughProtocol.appGroup) ?? .standard
    let registry = PairingRegistry(defaults: AppModel.groupDefaults, secrets: KeychainSecrets(accessGroup: PassthroughProtocol.appGroup))
    let log = PassthroughLog.shared

    @Published private(set) var state: ServiceState = .stopped
    @Published private(set) var meter = TrafficMeter()
    @Published private(set) var stats = ProviderStats(rx: 0, tx: 0, active: 0, totalConnections: 0, macs: [], startedAt: nil)
    @Published private(set) var pairedClients: [PairedClient] = []
    @Published private(set) var pairingCode: (code: String, expiry: Date)?
    @Published private(set) var radio: String?
    @Published private(set) var batteryLevel: Double?
    /// "Cellular only" is on but the phone is on Wi-Fi, so Macs get its Wi-Fi.
    @Published private(set) var sharingWiFiInsteadOfCellular = false
    @Published private(set) var extensionAvailable = true
    @Published private(set) var logEntries: [PassthroughLog.Entry] = []
    @Published var usage = UsageLedger(defaults: AppModel.groupDefaults)

    // Settings live in the App Group so the extension sees them.
    @AppStorage(SharedKeys.deviceName, store: AppModel.groupDefaults) var deviceName = "iPhone"
    @AppStorage(SharedKeys.cellularOnly, store: AppModel.groupDefaults) var cellularOnly = true
    @AppStorage(SharedKeys.allowUDP, store: AppModel.groupDefaults) var allowUDP = true
    @AppStorage(SharedKeys.socksPort, store: AppModel.groupDefaults) var socksPort = Int(PassthroughProtocol.defaultSOCKSPort)
    @AppStorage(SharedKeys.controlPort, store: AppModel.groupDefaults) var controlPort = Int(PassthroughProtocol.defaultControlPort)
    @AppStorage(SharedKeys.wireless, store: AppModel.groupDefaults) var wireless = false
    @AppStorage("hosting", store: AppModel.groupDefaults) var hostingRaw = Hosting.background.rawValue
    var hosting: Hosting {
        get { Hosting(rawValue: hostingRaw) ?? .background }
        set { hostingRaw = newValue.rawValue }
    }

    private let extensionHost = ExtensionHost()
    private lazy var inProcessHost = InProcessHost(defaults: Self.groupDefaults, registry: registry)
    /// The host serving now. The extension can be running from an earlier launch.
    private var activeHost: any ProxyHost { inProcessIsActive ? inProcessHost : extensionHost }
    private var inProcessIsActive = false
    private let facts = DeviceFacts()
    private var ticker: AnyCancellable?
    private var lastUsageSnapshot: (rx: Int64, tx: Int64)?
    private var cancellables: Set<AnyCancellable> = []

    private var logFileDate: Date?

    init() {
        pairedClients = registry.clients
        // The servers run in the tunnel extension, a separate process, so the
        // log lives in a shared file both processes append to.
        if let url = PassthroughProtocol.sharedLogURL { log.attachFile(url) }
        refreshLog(force: true)
        log.onAppend = { [weak self] entry in
            Task { @MainActor in
                guard let self else { return }
                self.logEntries.append(entry)
                if self.logEntries.count > 400 { self.logEntries.removeFirst(self.logEntries.count - 400) }
            }
        }
        registry.onChange = { [weak self] in Task { @MainActor in self?.pairedClients = self?.registry.clients ?? [] } }
        facts.onChange = { [weak self] in self?.refreshDeviceFacts() }
        refreshDeviceFacts()
        extensionHost.onStateChange = { [weak self] state in
            guard let self, !self.inProcessIsActive else { return }
            self.hostStateChanged(state)
        }
        inProcessHost.onStateChange = { [weak self] state in self?.hostStateChanged(state) }
        Task { await bootstrap() }
        ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect().sink { [weak self] _ in
            Task { @MainActor in await self?.tick() }
        }
        NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)
            .sink { [weak self] _ in Task { @MainActor in await self?.bootstrap() } }
            .store(in: &cancellables)
    }

    // MARK: Lifecycle

    private func bootstrap() async {
        pairedClients = registry.clients
        refreshDeviceFacts()
        #if targetEnvironment(simulator)
        extensionAvailable = false
        if hosting == .background { hosting = .foreground }
        #endif
        guard hosting == .background else { return }
        do {
            try await extensionHost.load()
        } catch {
            log.log(.warning, "Tunnel configuration unavailable: \(error.localizedDescription)")
            extensionAvailable = false
        }
    }

    func toggle() {
        state.isActive ? stop() : start()
    }

    func start() {
        guard !state.isActive else { return }
        state = .starting
        meter.reset()
        lastUsageSnapshot = nil
        inProcessIsActive = !(hosting == .background && extensionAvailable)
        var options = PassthroughService.Options()
        options.socksPort = UInt16(socksPort)
        options.controlPort = UInt16(controlPort)
        options.cellularOnly = cellularOnly
        options.allowUDP = allowUDP
        options.wireless = wireless
        let host = activeHost
        Task {
            do {
                try await host.start(options)
            } catch {
                log.log(.error, "Could not start: \(error.localizedDescription)")
                state = .failed(friendly(error))
            }
        }
    }

    func stop() {
        guard state.isActive else { return }
        state = .stopping
        let host = activeHost
        Task { await host.stop() }
    }

    private func hostStateChanged(_ host: HostState) {
        switch host {
        case .running: state = .running
        case .starting: state = .starting
        case .stopping: state = .stopping
        case .stopped:
            if case .failed = state { return }
            state = .stopped
            inProcessIsActive = false
            stats = ProviderStats(rx: stats.rx, tx: stats.tx, active: 0, totalConnections: stats.totalConnections, macs: [], startedAt: nil)
        }
    }

    // MARK: Ticking

    /// Re-reads the shared log when the extension has written to it.
    func refreshLog(force: Bool = false) {
        let stamp = log.persistedModificationDate
        guard force || stamp != logFileDate else { return }
        logFileDate = stamp
        let persisted = log.loadPersisted()
        logEntries = persisted.isEmpty ? log.snapshot() : persisted
    }

    func clearLog() {
        log.clear()
        logEntries = []
        logFileDate = log.persistedModificationDate
    }

    private var logTick = 0

    private func tick() async {
        refreshDeviceFacts()
        logTick += 1
        if logTick % 2 == 0 { refreshLog() }
        if let pairingCode, pairingCode.expiry <= Date() { self.pairingCode = nil }
        guard state == .running, let fresh = await activeHost.stats() else { return }
        if stats.macs.count < fresh.macs.count, pairingCode != nil { pairingCode = nil }
        stats = fresh
        meter.record(ByteCounter.Snapshot(rx: fresh.rx, tx: fresh.tx, active: fresh.active, totalConnections: fresh.totalConnections))
        if let last = lastUsageSnapshot {
            usage.add(rx: max(0, fresh.rx - last.rx), tx: max(0, fresh.tx - last.tx))
        }
        lastUsageSnapshot = (fresh.rx, fresh.tx)
        pairedClients = registry.clients
    }

    /// Publishes the radio and battery, and hands them to whichever process hosts the service.
    private func refreshDeviceFacts() {
        let defaults = Self.groupDefaults
        let egress = defaults.string(forKey: SharedKeys.egress).flatMap(Egress.init(rawValue:)) ?? .cellular
        radio = facts.radio(cellularOnly: cellularOnly, running: state == .running, egress: egress)
        sharingWiFiInsteadOfCellular = cellularOnly && facts.onWiFi
        batteryLevel = facts.battery
        // Cross-process defaults writes are not free; only when something changed.
        if defaults.string(forKey: SharedKeys.radio) != radio { defaults.set(radio, forKey: SharedKeys.radio) }
        if defaults.object(forKey: SharedKeys.battery) as? Double != batteryLevel { defaults.set(batteryLevel, forKey: SharedKeys.battery) }
    }

    // MARK: Pairing

    func beginPairing() {
        pairingCode = registry.issueCode()
    }

    func endPairing() {
        registry.clearCode()
        pairingCode = nil
    }

    func revoke(_ client: PairedClient) {
        registry.revoke(clientID: client.id)
        pairedClients = registry.clients
    }

    var connectedMacIDs: Set<String> { Set(stats.macs.map(\.id)) }

    var sessionDuration: TimeInterval? {
        guard let start = stats.startedAt, state == .running else { return nil }
        return Date().timeIntervalSince(start)
    }

    private func friendly(_ error: Error) -> String {
        let text = error.localizedDescription
        if text.localizedCaseInsensitiveContains("permission") || text.contains("NEVPNErrorDomain") {
            return "iOS did not allow the VPN configuration. Approve it in Settings, or switch to foreground hosting."
        }
        return text
    }
}
