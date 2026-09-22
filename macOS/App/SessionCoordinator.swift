import Foundation
import SwiftUI
import Combine
import Network
import PassthroughCore
import USBMux

/// Drives the whole Mac side: watches USB for an iPhone, forwards a loopback
/// port over usbmuxd, pairs, and asks the helper to route the Mac through it.
@MainActor
final class SessionCoordinator: ObservableObject {
    enum Phase: Equatable {
        case noDevice
        case deviceFound
        case helperRequired
        case connecting(String)
        case pairingRequired
        case connected
        case error(String)

        var isConnected: Bool { self == .connected }
        var isBusy: Bool { if case .connecting = self { return true } else { return false } }
    }

    // Observable state
    @Published private(set) var phase: Phase = .noDevice
    @Published private(set) var device: USBMux.Device?
    @Published private(set) var meter = TrafficMeter()
    @Published private(set) var phoneStatus: DeviceStatus?
    @Published private(set) var phoneActiveConnections = 0
    @Published private(set) var connectedSince: Date?
    @Published private(set) var tunnelInterface: String?
    @Published private(set) var helperAvailability: HelperClient.Availability = .notRegistered
    @Published private(set) var pairingError: String?
    @Published private(set) var pairingInFlight = false
    @Published private(set) var logEntries: [PassthroughLog.Entry] = []
    @Published private(set) var sessionRx: Int64 = 0
    @Published private(set) var sessionTx: Int64 = 0

    // Settings
    @AppStorage("autoConnect") var autoConnect = true
    @AppStorage("ipv6") var ipv6Enabled = true
    @AppStorage("dnsServers") var dnsServers = "1.1.1.1, 1.0.0.1"
    @AppStorage("localPort") var localPort = Int(PassthroughProtocol.defaultLocalSOCKSPort)
    @AppStorage("mtu") var mtu = 8500
    @AppStorage("clientID") private var storedClientID = ""

    /// Keep the Mac from idle-sleeping while on, so long sessions survive. Off by default.
    @Published var keepAwake: Bool = UserDefaults.standard.bool(forKey: "keepAwake") {
        didSet {
            UserDefaults.standard.set(keepAwake, forKey: "keepAwake")
            power.apply(keepAwake)
            applyLidClose(keepAwake)
        }
    }
    /// True once the root helper has confirmed lid-close sleep is disabled.
    @Published private(set) var lidCloseHeld = false

    /// Auto-disable keep-awake when the battery falls to the threshold (on battery power).
    @AppStorage("batteryAutoOff") var batteryAutoOff = true
    @AppStorage("batteryAutoOffThreshold") var batteryAutoOffThreshold = 20
    @Published private(set) var battery = BatteryReading(percent: -1, isOnAC: true, hasBattery: false)
    /// Set when keep-awake can't be turned on (or was auto-disabled) due to low battery.
    @Published private(set) var keepAwakeBlockedReason: String?

    private let helper = HelperClient()
    private let power = PowerManager()
    private let queue = DispatchQueue(label: "dev.dpatel.passthrough.mac")
    private var listenConnection: NWConnection?
    private var devices: [Int: USBMux.Device] = [:]
    private var forwarder: LocalForwarder?
    private var control: ControlClient?
    private var ticker: AnyCancellable?
    private var cancellables: Set<AnyCancellable> = []
    private var retryTask: Task<Void, Never>?
    private var retryAttempts = 0
    private var generation = 0
    private var wantsConnection = false

    var clientID: String {
        if storedClientID.isEmpty { storedClientID = UUID().uuidString }
        return storedClientID
    }
    var macName: String { Host.current().localizedName ?? "Mac" }
    var hasToken: Bool { Keychain.read("token") != nil }
    var dnsList: [String] { dnsServers.split(whereSeparator: { $0 == "," || $0 == " " }).map(String.init).filter { !$0.isEmpty } }

    /// Passthrough half of the menu-bar icon. Keep-awake adds a separate glyph.
    var passthroughGlyph: String {
        phase.isConnected ? "iphone.gen3.radiowaves.left.and.right" : "iphone.gen3"
    }

    init() {
        logEntries = PassthroughLog.shared.snapshot()
        PassthroughLog.shared.onAppend = { [weak self] entry in
            Task { @MainActor in
                self?.logEntries.append(entry)
                if (self?.logEntries.count ?? 0) > 400 { self?.logEntries.removeFirst() }
            }
        }
        helperAvailability = helper.availability
        startDeviceWatch()
        ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect().sink { [weak self] _ in self?.tick() }
        NotificationCenter.default.publisher(for: .passthroughWillTerminate)
            .sink { [weak self] _ in self?.shutdownForQuit() }
            .store(in: &cancellables)
        power.apply(keepAwake)
        Task { await ensureHelperCurrent(); applyLidClose(keepAwake) }
        if let raw = ProcessInfo.processInfo.environment["PASSTHROUGH_DIRECT_SOCKS"], let port = UInt16(raw) {
            Task { await self.directDiagnosticConnect(socksPort: port) }
        }
    }

    // MARK: Device watching

    private func startDeviceWatch() {
        listenConnection?.cancel()
        listenConnection = USBMux.listen(queue: queue) { [weak self] event in
            Task { @MainActor in self?.handle(event) }
        }
    }

    private func handle(_ event: USBMux.Event) {
        switch event {
        case .listening:
            ptLog(.debug, "Watching usbmuxd for iPhones")
        case .attached(let d):
            guard d.isUSB else { return }
            devices[d.id] = d
            ptLog(.info, "iPhone attached over USB (\(d.udid.prefix(8))…)")
            if device == nil {
                device = d
                phase = .deviceFound
                if autoConnect { connect() }
            }
        case .detached(let id):
            devices[id] = nil
            if device?.id == id {
                ptLog(.info, "iPhone detached")
                teardown(to: devices.values.first.map { _ in .deviceFound } ?? .noDevice)
                device = devices.values.first
                if device != nil, autoConnect { connect() }
            }
        case .failed(let error):
            ptLog(.error, "usbmuxd watch failed: \(error.localizedDescription); retrying")
            Task { try? await Task.sleep(for: .seconds(3)); self.startDeviceWatch() }
        }
    }

    // MARK: Connect flow

    func connect() {
        guard let device else { phase = .noDevice; return }
        guard !phase.isConnected, !phase.isBusy else { return }
        wantsConnection = true
        retryTask?.cancel()
        generation += 1
        let gen = generation
        phase = .connecting("Checking helper")
        Task { await runConnect(device: device, generation: gen) }
    }

    private func runConnect(device: USBMux.Device, generation gen: Int) async {
        // 1. Helper
        helperAvailability = helper.availability
        if helperAvailability == .notRegistered { helperAvailability = helper.register() }
        guard helperAvailability == .ready else {
            phase = .helperRequired
            return
        }
        await ensureHelperCurrent()
        guard generation == gen else { return }

        // 2. Loopback forwarder over usbmuxd
        phase = .connecting("Opening USB link")
        let forwarder = LocalForwarder(deviceID: device.id, remotePort: PassthroughProtocol.defaultSOCKSPort, localPort: UInt16(localPort))
        do { try forwarder.start() } catch {
            fail("Could not listen on 127.0.0.1:\(localPort): \(error.localizedDescription)")
            return
        }
        self.forwarder = forwarder
        forwarder.onFailure = { [weak self] error in Task { @MainActor in self?.fail(error.localizedDescription) } }

        // 3. Control channel
        phase = .connecting("Talking to iPhone")
        let identity = ControlClient.Identity(clientID: clientID, name: macName, token: Keychain.read("token"))
        let control = ControlClient(deviceID: device.id, identity: identity) { [weak self] event in
            Task { @MainActor in self?.handleControl(event, generation: gen) }
        }
        self.control = control
        control.connect()
    }

    private func handleControl(_ event: ControlClient.Event, generation gen: Int) {
        guard gen == generation else { return }
        switch event {
        case .welcomed(let paired, let status, _):
            phoneStatus = status
            retryAttempts = 0
            if paired {
                Task { await bringTunnelUp(generation: gen) }
            } else {
                phase = .pairingRequired
                pairingError = nil
            }
        case .paired(let token):
            Keychain.write(token, account: "token")
            pairingInFlight = false
            pairingError = nil
            ptLog(.info, "Paired with \(phoneStatus?.deviceName ?? "iPhone")")
            Task { await bringTunnelUp(generation: gen) }
        case .pairingFailed(let failure):
            pairingInFlight = false
            switch failure {
            case .badCode: pairingError = "That code didn't match. Check the digits on the iPhone."
            case .expired: pairingError = "The code expired or wasn't generated yet. Tap Pair on the iPhone and try again."
            case .notAuthenticated: pairingError = "Not authenticated."
            case .unsupportedVersion: pairingError = "The iPhone app is a different version. Update both apps."
            }
        case .status(let status, _, _, let active):
            phoneStatus = status
            phoneActiveConnections = active
        case .disconnected(let error):
            let why = error?.localizedDescription ?? "The iPhone closed the connection"
            if case .pairingRequired = phase {
                fail("Lost the iPhone while pairing: \(why)")
            } else if phase.isConnected || phase.isBusy {
                ptLog(.warning, "Control channel dropped: \(why)")
                fail(friendlyDrop(why))
            }
        }
    }

    private func friendlyDrop(_ why: String) -> String {
        if why.contains("refused") { return "Passthrough isn't running on the iPhone. Start it there, then connect." }
        return why
    }

    private func bringTunnelUp(generation gen: Int) async {
        guard let token = Keychain.read("token") else { phase = .pairingRequired; return }
        phase = .connecting("Routing the Mac through the iPhone")
        let config = HelperClient.TunnelConfig(socksPort: UInt16(localPort), username: clientID, password: token,
                                               ipv6: ipv6Enabled, dns: dnsList.isEmpty ? ["1.1.1.1", "1.0.0.1"] : dnsList, mtu: mtu)
        do {
            let iface = try await helper.startTunnel(config)
            guard gen == generation else { await helper.stopTunnel(); return }
            tunnelInterface = iface
            connectedSince = Date()
            meter.reset()
            sessionRx = 0; sessionTx = 0
            phase = .connected
            ptLog(.info, "Connected: Mac traffic now flows over USB via \(iface)")
        } catch {
            fail(error.localizedDescription)
        }
    }

    func submitPairingCode(_ code: String) {
        guard let control, code.count == 6 else { return }
        pairingInFlight = true
        pairingError = nil
        control.pair(code: code)
    }

    func disconnect() {
        wantsConnection = false
        retryTask?.cancel()
        teardown(to: device == nil ? .noDevice : .deviceFound)
    }

    func toggle() {
        phase.isConnected || phase.isBusy || phase == .pairingRequired ? disconnect() : connect()
    }

    func retryHelper() {
        helperAvailability = helper.register()
        if helperAvailability == .ready { connect() }
    }

    func openLoginItems() { HelperClient.openLoginItemsSettings() }

    func forgetPairing() {
        Keychain.delete("token")
        if phase.isConnected { disconnect() }
        objectWillChange.send()
    }

    private func fail(_ message: String) {
        ptLog(.error, message)
        let hadTunnel = phase.isConnected
        teardown(to: .error(message))
        if wantsConnection, device != nil, hadTunnel || retryAttempts < 5 {
            scheduleRetry()
        }
    }

    private func scheduleRetry() {
        retryAttempts += 1
        let delay = min(30, 2 * retryAttempts)
        ptLog(.info, "Retrying in \(delay)s")
        retryTask?.cancel()
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.connect()
        }
    }

    private func teardown(to next: Phase) {
        generation += 1
        let hadTunnel = phase.isConnected || tunnelInterface != nil
        control?.close()
        control = nil
        forwarder?.stop()
        forwarder = nil
        tunnelInterface = nil
        connectedSince = nil
        phoneActiveConnections = 0
        pairingInFlight = false
        phase = next
        if hadTunnel { Task { await helper.stopTunnel() } }
    }

    /// Turn keep-awake on/off with a low-battery precheck. If the battery is at
    /// or below the configured limit (on battery power), it refuses to turn on
    /// and records a reason to show under the toggle.
    func setKeepAwake(_ on: Bool) {
        if on, batteryAutoOff {
            let r = BatteryMonitor.read()
            battery = r
            if r.hasBattery, !r.isOnAC, r.percent >= 0, r.percent <= batteryAutoOffThreshold {
                keepAwakeBlockedReason = "Battery is \(r.percent)% — at or below your \(batteryAutoOffThreshold)% limit. Plug in, or lower the limit in Settings, to keep the Mac awake."
                if keepAwake { keepAwake = false }
                return
            }
        }
        keepAwakeBlockedReason = nil
        keepAwake = on
    }

    /// Ask the root helper to disable/enable full (lid-close) sleep. The helper
    /// auto-reverts if this app disconnects, so the Mac can never get stuck awake.
    private func applyLidClose(_ on: Bool) {
        if on, helper.availability != .ready {
            helperAvailability = helper.register()
        }
        Task { @MainActor in
            let ok = await helper.setDisableSleep(on)
            self.lidCloseHeld = on && ok
            if on && !ok {
                ptLog(.warning, "Keep awake: idle sleep is held, but lid-close needs the helper approved.")
            }
        }
    }

    private func shutdownForQuit() {
        if keepAwake { Task { _ = await helper.setDisableSleep(false) } }
        wantsConnection = false
        control?.close()
        forwarder?.stop()
        Task { await helper.stopTunnel(); helper.invalidate() }
    }

    // MARK: Helper version management

    private func ensureHelperCurrent() async {
        guard helper.availability == .ready else { return }
        guard let v = await helper.version(), v != HelperConstants.version else { return }
        ptLog(.warning, "Helper version \(v) ≠ \(HelperConstants.version); restarting helper")
        helper.quitHelper()
        // Wait for launchd to respawn the new binary before we drive it.
        for _ in 0..<10 {
            try? await Task.sleep(for: .milliseconds(400))
            if let nv = await helper.version(), nv == HelperConstants.version {
                ptLog(.info, "Helper upgraded to \(nv)")
                return
            }
        }
        ptLog(.warning, "Helper did not report the expected version after restart")
    }

    // MARK: Ticking

    private var healthTick = 0

    private func tick() {
        checkBattery()
        healthTick += 1
        if phase.isConnected, healthTick % 3 == 0 {
            let gen = generation
            Task {
                let status = await helper.status()
                guard gen == self.generation, self.phase.isConnected else { return }
                if (status[TunnelStatusKey.running] as? Bool) == false {
                    self.fail("The tunnel helper stopped unexpectedly; reconnecting")
                }
            }
        }
        if let forwarder {
            let snap = forwarder.counter.snapshot()
            meter.record(snap)
            sessionRx = snap.rx
            sessionTx = snap.tx
        } else if meter.downRate != 0 || meter.upRate != 0 {
            meter.record(.zero)
        }
        let availability = helper.availability
        if availability != helperAvailability {
            helperAvailability = availability
            if availability == .ready, phase == .helperRequired { connect() }
        }
    }

    var sessionDuration: TimeInterval? { connectedSince.map { Date().timeIntervalSince($0) } }

    /// If keep-awake is on and the battery hits the user's threshold while on
    /// battery power, turn keep-awake off automatically so the Mac can sleep and
    /// stop draining, even with the lid closed.
    private func checkBattery() {
        let reading = BatteryMonitor.read()
        battery = reading
        if let _ = keepAwakeBlockedReason, reading.isOnAC || reading.percent > batteryAutoOffThreshold {
            keepAwakeBlockedReason = nil
        }
        guard keepAwake, batteryAutoOff, reading.hasBattery, !reading.isOnAC, reading.percent >= 0 else { return }
        if reading.percent <= batteryAutoOffThreshold {
            ptLog(.warning, "Battery \(reading.percent)% ≤ \(batteryAutoOffThreshold)% on battery: turning keep-awake off")
            keepAwakeBlockedReason = "Turned off at \(reading.percent)% (your \(batteryAutoOffThreshold)% limit). Plug in to keep the Mac awake."
            keepAwake = false
        }
    }

    /// Diagnostics: drive the helper straight at a local SOCKS server so the
    /// full utun + tun2socks path can be exercised without the phone.
    func directDiagnosticConnect(socksPort: UInt16) async {
        helperAvailability = helper.availability
        if helperAvailability == .notRegistered { helperAvailability = helper.register() }
        await ensureHelperCurrent()
        let config = HelperClient.TunnelConfig(socksPort: socksPort, username: "", password: "",
                                               ipv6: false, dns: dnsList.isEmpty ? ["1.1.1.1","1.0.0.1"] : dnsList, mtu: mtu)
        do {
            let iface = try await helper.startTunnel(config)
            tunnelInterface = iface
            connectedSince = Date()
            phase = .connected
            ptLog(.info, "DIAG: tunnel up on \(iface) → 127.0.0.1:\(socksPort)")
        } catch {
            ptLog(.error, "DIAG: \(error.localizedDescription)")
        }
    }

    /// Puts the coordinator into a synthetic state for previews and snapshots.
    func debugApply(phase: Phase, device: Bool = false, status: DeviceStatus? = nil, traffic: Bool = false) {
        ticker?.cancel()
        listenConnection?.cancel()
        self.phase = phase
        self.device = device ? USBMux.Device(id: 1, udid: "preview", connectionType: "USB", productID: 0) : nil
        phoneStatus = status
        if traffic {
            connectedSince = Date().addingTimeInterval(-754)
            tunnelInterface = "utun6"
            phoneActiveConnections = 14
            var m = TrafficMeter()
            var rx: Int64 = 0, tx: Int64 = 0
            for i in 0..<60 {
                let wave = (sin(Double(i) / 6) + 1) / 2
                rx += Int64(2_400_000 * wave + 300_000 * Double.random(in: 0...1))
                tx += Int64(300_000 * (1 - wave) + 80_000 * Double.random(in: 0...1))
                m.record(ByteCounter.Snapshot(rx: rx, tx: tx, active: 14, totalConnections: 120), at: Date().addingTimeInterval(Double(i - 60)))
            }
            meter = m
            sessionRx = rx; sessionTx = tx
        }
    }
}
