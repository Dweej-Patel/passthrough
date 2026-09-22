import Foundation
import SwiftUI
import Combine
import Network
import NetworkExtension
import CoreTelephony
import PassthroughCore

/// Everything the iOS screens observe. Owns the tunnel controller (background
/// hosting), the in-process service (foreground hosting), pairing and usage.
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
    let registry = PairingRegistry(defaults: AppModel.groupDefaults)
    let log = PassthroughLog.shared

    @Published private(set) var state: ServiceState = .stopped
    @Published private(set) var meter = TrafficMeter()
    @Published private(set) var stats = ProviderStats(rx: 0, tx: 0, active: 0, totalConnections: 0, macs: [], startedAt: nil)
    @Published private(set) var pairedClients: [PairedClient] = []
    @Published private(set) var pairingCode: (code: String, expiry: Date)?
    @Published private(set) var radio: String?
    @Published private(set) var batteryLevel: Double?
    @Published private(set) var extensionAvailable = true
    @Published private(set) var logEntries: [PassthroughLog.Entry] = []
    @Published var usage = UsageLedger(defaults: AppModel.groupDefaults)

    // Settings live in the App Group so the extension sees them.
    @AppStorage(SharedKeys.deviceName, store: AppModel.groupDefaults) var deviceName = "iPhone"
    @AppStorage(SharedKeys.cellularOnly, store: AppModel.groupDefaults) var cellularOnly = true
    @AppStorage(SharedKeys.allowUDP, store: AppModel.groupDefaults) var allowUDP = true
    @AppStorage(SharedKeys.socksPort, store: AppModel.groupDefaults) var socksPort = Int(PassthroughProtocol.defaultSOCKSPort)
    @AppStorage(SharedKeys.controlPort, store: AppModel.groupDefaults) var controlPort = Int(PassthroughProtocol.defaultControlPort)
    @AppStorage("hosting", store: AppModel.groupDefaults) var hostingRaw = Hosting.background.rawValue
    var hosting: Hosting {
        get { Hosting(rawValue: hostingRaw) ?? .background }
        set { hostingRaw = newValue.rawValue }
    }

    private let tunnel = TunnelController()
    private var localService: PassthroughService?
    private var ticker: AnyCancellable?
    private var lastUsageSnapshot: (rx: Int64, tx: Int64)?
    private let telephony = CTTelephonyNetworkInfo()
    private let pathMonitor = NWPathMonitor()
    @Published private(set) var phoneIsOnWiFi = false
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
        UIDevice.current.isBatteryMonitoringEnabled = true
        pathMonitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                self?.phoneIsOnWiFi = path.usesInterfaceType(.wifi)
                self?.refreshDeviceFacts()
            }
        }
        pathMonitor.start(queue: DispatchQueue(label: "dev.dpatel.passthrough.path"))
        refreshDeviceFacts()
        tunnel.onStatusChange = { [weak self] status in Task { @MainActor in self?.tunnelStatusChanged(status) } }
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
            try await tunnel.load()
            tunnelStatusChanged(tunnel.status)
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
        switch hosting {
        case .background where extensionAvailable:
            Task {
                do {
                    try await tunnel.configure(deviceName: deviceName, cellularOnly: cellularOnly, allowUDP: allowUDP,
                                               socksPort: UInt16(socksPort), controlPort: UInt16(controlPort))
                    try tunnel.start()
                } catch {
                    log.log(.error, "Could not start tunnel: \(error.localizedDescription)")
                    state = .failed(friendly(error))
                }
            }
        default:
            startForeground()
        }
    }

    func stop() {
        guard state.isActive else { return }
        state = .stopping
        if let localService {
            localService.stop()
            self.localService = nil
            UIApplication.shared.isIdleTimerDisabled = false
            state = .stopped
            stats = ProviderStats(rx: stats.rx, tx: stats.tx, active: 0, totalConnections: stats.totalConnections, macs: [], startedAt: nil)
        } else {
            Task { await tunnel.stop() }
        }
    }

    private func startForeground() {
        var options = PassthroughService.Options()
        options.socksPort = UInt16(socksPort)
        options.controlPort = UInt16(controlPort)
        options.cellularOnly = cellularOnly
        options.allowUDP = allowUDP
        let defaults = Self.groupDefaults
        let service = PassthroughService(registry: registry, options: options) {
            DeviceStatus(deviceName: defaults.string(forKey: SharedKeys.deviceName) ?? "iPhone",
                         radio: defaults.string(forKey: SharedKeys.radio),
                         battery: defaults.object(forKey: SharedKeys.battery) as? Double,
                         hosting: "foreground")
        }
        service.onCellularUsableChange = { usable in defaults.set(!usable, forKey: SharedKeys.cellularFallback) }
        defaults.set(false, forKey: SharedKeys.cellularFallback)
        do {
            try service.start()
            localService = service
            UIApplication.shared.isIdleTimerDisabled = true
            state = .running
            log.log(.info, "Serving in the foreground. Keep Passthrough open.")
        } catch {
            state = .failed(friendly(error))
            log.log(.error, "Foreground start failed: \(error.localizedDescription)")
        }
    }

    private func tunnelStatusChanged(_ status: NEVPNStatus) {
        switch status {
        case .connected:
            state = .running
        case .connecting, .reasserting:
            state = .starting
        case .disconnecting:
            state = .stopping
        case .disconnected, .invalid:
            if case .failed = state { return }
            state = .stopped
            stats.macs = []
            stats.active = 0
        @unknown default:
            break
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
        guard state == .running else { return }
        let fresh: ProviderStats?
        if let localService {
            let snap = localService.counter.snapshot()
            fresh = ProviderStats(rx: snap.rx, tx: snap.tx, active: snap.active, totalConnections: snap.totalConnections,
                                  macs: localService.connectedMacs, startedAt: localService.startedAt)
        } else {
            fresh = await tunnel.fetchStats()
        }
        guard let fresh else { return }
        if stats.macs.count < fresh.macs.count, pairingCode != nil { pairingCode = nil }
        stats = fresh
        meter.record(ByteCounter.Snapshot(rx: fresh.rx, tx: fresh.tx, active: fresh.active, totalConnections: fresh.totalConnections))
        if let last = lastUsageSnapshot {
            usage.add(rx: max(0, fresh.rx - last.rx), tx: max(0, fresh.tx - last.tx))
        }
        lastUsageSnapshot = (fresh.rx, fresh.tx)
        pairedClients = registry.clients
    }

    private func refreshDeviceFacts() {
        let techs = telephony.serviceCurrentRadioAccessTechnology ?? [:]
        let tech = techs.values.first
        let cellular = Self.radioLabel(tech)
        // What the Mac's traffic will actually ride on.
        let fallback = cellularOnly && state == .running && Self.groupDefaults.bool(forKey: SharedKeys.cellularFallback)
        radio = fallback ? "Wi-Fi (cell down)" : ((phoneIsOnWiFi && !cellularOnly) ? "Wi-Fi" : cellular)
        let level = UIDevice.current.batteryLevel
        batteryLevel = level >= 0 ? Double(level) : nil
        // Cross-process defaults writes are not free; only when something changed.
        if Self.groupDefaults.string(forKey: SharedKeys.radio) != radio { Self.groupDefaults.set(radio, forKey: SharedKeys.radio) }
        let storedBattery = Self.groupDefaults.object(forKey: SharedKeys.battery) as? Double
        if storedBattery != batteryLevel { Self.groupDefaults.set(batteryLevel, forKey: SharedKeys.battery) }
    }

    static func radioLabel(_ tech: String?) -> String? {
        guard let tech else { return nil }
        if #available(iOS 14.1, *), tech == CTRadioAccessTechnologyNRNSA || tech == CTRadioAccessTechnologyNR { return "5G" }
        switch tech {
        case CTRadioAccessTechnologyLTE: return "LTE"
        case CTRadioAccessTechnologyWCDMA, CTRadioAccessTechnologyHSDPA, CTRadioAccessTechnologyHSUPA: return "3G"
        case CTRadioAccessTechnologyEdge, CTRadioAccessTechnologyGPRS: return "2G"
        default: return "Cellular"
        }
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

/// Persists cumulative data usage so you can keep an eye on the plan.
struct UsageLedger {
    private let defaults: UserDefaults
    private(set) var monthRx: Int64
    private(set) var monthTx: Int64
    private(set) var monthStart: Date
    private(set) var allRx: Int64
    private(set) var allTx: Int64

    init(defaults: UserDefaults) {
        self.defaults = defaults
        monthRx = Int64(defaults.integer(forKey: SharedKeys.usageMonthRx))
        monthTx = Int64(defaults.integer(forKey: SharedKeys.usageMonthTx))
        allRx = Int64(defaults.integer(forKey: SharedKeys.usageAllTimeRx))
        allTx = Int64(defaults.integer(forKey: SharedKeys.usageAllTimeTx))
        let start = defaults.double(forKey: SharedKeys.usageMonthStart)
        monthStart = start > 0 ? Date(timeIntervalSince1970: start) : Date()
        if start == 0 { defaults.set(monthStart.timeIntervalSince1970, forKey: SharedKeys.usageMonthStart) }
        rolloverIfNeeded()
    }

    mutating func add(rx: Int64, tx: Int64) {
        rolloverIfNeeded()
        monthRx += rx; monthTx += tx; allRx += rx; allTx += tx
        persist()
    }

    mutating func resetMonth() {
        monthRx = 0; monthTx = 0; monthStart = Date()
        persist()
    }

    private mutating func rolloverIfNeeded() {
        let cal = Calendar.current
        if !cal.isDate(monthStart, equalTo: Date(), toGranularity: .month) {
            monthRx = 0; monthTx = 0; monthStart = cal.date(from: cal.dateComponents([.year, .month], from: Date())) ?? Date()
            persist()
        }
    }

    private func persist() {
        defaults.set(monthRx, forKey: SharedKeys.usageMonthRx)
        defaults.set(monthTx, forKey: SharedKeys.usageMonthTx)
        defaults.set(allRx, forKey: SharedKeys.usageAllTimeRx)
        defaults.set(allTx, forKey: SharedKeys.usageAllTimeTx)
        defaults.set(monthStart.timeIntervalSince1970, forKey: SharedKeys.usageMonthStart)
    }

    var monthTotal: Int64 { monthRx + monthTx }
    var allTotal: Int64 { allRx + allTx }
}
