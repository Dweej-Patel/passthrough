import Foundation
import SwiftUI
import Combine
import Network
import PassthroughCore
import PhoneTransport

/// Drives the passthrough link on the Mac: finds a phone (`DeviceDirectory`),
/// forwards a loopback port over its link, pairs, and asks the root helper to
/// route the Mac through it. The VPN layer and keep-awake are separate
/// objects it owns and ticks.
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
    @Published private(set) var phase: Phase = .noDevice { didSet { if phase.isConnected != oldValue.isConnected { syncHotspotGuard() } } }
    @Published private(set) var device: PhoneDevice? { didSet { refreshWirelessCarrier() } }
    /// Android over adb: whether platform-tools were found, and anything the user must do on the phone.
    @Published private(set) var androidWatch = WatchStatus()
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
    /// True while the menu-bar panel is on screen; animations stop otherwise.
    @Published var panelVisible = false

    // Settings
    @AppStorage("autoConnect") var autoConnect = true
    @AppStorage("ipv6") var ipv6Enabled = true
    @AppStorage("dnsServers") var dnsServers = "1.1.1.1, 1.0.0.1"
    @AppStorage("localPort") var localPort = Int(PassthroughProtocol.defaultLocalSOCKSPort)
    @AppStorage("mtu") var mtu = 8500
    @AppStorage("clientID") private var storedClientID = ""

    /// Which links may carry the passthrough. Cable only unless changed.
    enum ConnectionMode: String, CaseIterable, Identifiable {
        case cable, wireless, automatic
        var id: String { rawValue }
        var title: String {
            switch self {
            case .cable: return "Cable only"
            case .wireless: return "Wireless only"
            case .automatic: return "Automatic"
            }
        }
        func allows(_ device: PhoneDevice) -> Bool {
            switch self {
            case .cable: return device.medium == .usb
            case .wireless: return device.medium == .wireless
            case .automatic: return true
            }
        }
    }
    @Published var connectionMode: ConnectionMode = ConnectionMode(rawValue: UserDefaults.standard.string(forKey: "connectionMode") ?? "") ?? .cable {
        didSet {
            UserDefaults.standard.set(connectionMode.rawValue, forKey: "connectionMode")
            connectionMode == .cable ? wirelessWatcher.stop() : wirelessWatcher.start()
            reconsiderDevice()
            syncHotspotGuard()
        }
    }
    @Published private(set) var wirelessWatch = WatchStatus()
    /// Let the wireless link use Apple peer-to-peer Wi-Fi too (it drops while
    /// an iPhone is locked); otherwise it runs over a shared network such as
    /// the iPhone's Personal Hotspot.
    @Published var peerToPeer: Bool = UserDefaults.standard.bool(forKey: "wirelessPeerToPeer") {
        didSet {
            UserDefaults.standard.set(peerToPeer, forKey: "wirelessPeerToPeer")
            wirelessWatcher.peerToPeer = peerToPeer
            if connectionMode != .cable { wirelessWatcher.stop(); wirelessWatcher.start() }
        }
    }
    /// Block the internet while the Mac is on a phone's hotspot but passthrough
    /// is down, so the hotspot's own data allowance is never used.
    @Published var hotspotGuard: Bool = UserDefaults.standard.object(forKey: "hotspotGuard") as? Bool ?? true {
        didSet { UserDefaults.standard.set(hotspotGuard, forKey: "hotspotGuard"); syncHotspotGuard() }
    }
    /// The Mac's Wi-Fi is a metered network, which is how macOS marks a phone's hotspot.
    @Published private(set) var onPhoneHotspot = false
    private let wifiMonitor = NWPathMonitor(requiredInterfaceType: .wifi)
    private var guardApplied: Bool?

    /// Also watch for Android phones through adb. On by default; harmless without platform-tools.
    @Published var androidEnabled: Bool = UserDefaults.standard.object(forKey: "androidEnabled") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(androidEnabled, forKey: "androidEnabled")
            androidEnabled ? androidWatcher.start() : androidWatcher.stop()
        }
    }

    let vpnLayer: VPNLayer
    let keepAwake: KeepAwakeController

    private let helper = HelperClient()
    private let directory: DeviceDirectory
    private let androidWatcher: ADBWatcher
    private let wirelessWatcher: WirelessWatcher
    private let links = LinkStore()
    private var forwarder: LocalForwarder?
    private var control: ControlClient?
    private var ticker: AnyCancellable?
    private var cancellables: Set<AnyCancellable> = []
    private var retryTask: Task<Void, Never>?
    private var statusPollInFlight = false
    private var retryAttempts = 0
    /// Bumped on every connect and teardown so late callbacks from an old attempt are ignored.
    private var generation = 0
    private var wantsConnection = false
    private var suppressAutoConnect = false
    /// What the helper was last told about IPv6 in the tunnel (it starts open).
    private var tunnelIPv6: Bool?
    /// Whether the phone was last on Wi-Fi, to spot it switching networks.
    private var phoneOnWiFi: Bool?

    var adbStatus: WatchStatus.State { androidWatch.state }
    var androidHint: String? { androidWatch.hint }
    var clientID: String {
        if storedClientID.isEmpty { storedClientID = UUID().uuidString }
        return storedClientID
    }
    var macName: String { Host.current().localizedName ?? "Mac" }
    /// Keychain slot of the attached phone's pairing token (the iPhone slot when none is attached).
    private var pairingSlot: String { device?.pairingSlot ?? PhoneDevice.Kind.iPhone.defaultPairingSlot }
    var hasToken: Bool { Keychain.read(pairingSlot) != nil }
    /// "over USB" or "over Wi-Fi", for status copy.
    var linkedPhoneCount: Int { links.phones.count }
    var linkName: String { device?.medium == .wireless ? "over \(wirelessCarrier ?? "Wi-Fi")" : "over USB" }
    /// What carries the wireless link right now: "Hotspot", "Peer-to-peer" or "Wi-Fi network".
    @Published private(set) var wirelessCarrier: String?
    private func refreshWirelessCarrier() {
        guard let device, device.medium == .wireless, device.id.hasPrefix("wifi:") else { wirelessCarrier = nil; return }
        let carrier = wirelessWatcher.carriers[String(device.id.dropFirst(5))] ?? WirelessLink.carrier(interface: nil)
        wirelessCarrier = carrier == "Wi-Fi network" && onPhoneHotspot ? "Hotspot" : carrier
    }
    /// "iPhone" or "Android phone" for the attached device; "phone" when none.
    var phoneKindName: String { device?.kindName ?? "phone" }
    var dnsList: [String] { dnsServers.split(whereSeparator: { $0 == "," || $0 == " " }).map(String.init).filter { !$0.isEmpty } }
    var sessionDuration: TimeInterval? { connectedSince.map { Date().timeIntervalSince($0) } }

    init() {
        vpnLayer = VPNLayer(helper: helper)
        keepAwake = KeepAwakeController(helper: helper)
        // Diagnostic hooks are only read when the app was launched with
        // --diagnostics, so environment variables alone can't steer a normal launch.
        // PASSTHROUGH_NO_AUTOCONNECT=1 keeps a fresh launch from taking over the
        // network; PASSTHROUGH_VPN_TEST=<conf> starts the VPN layer from that file.
        #if DEBUG
        let env = CommandLine.arguments.contains("--diagnostics") ? ProcessInfo.processInfo.environment : [:]
        #else
        let env: [String: String] = [:]
        #endif
        androidWatcher = ADBWatcher(includeNonUSB: env["PASSTHROUGH_ADB_ANY_TRANSPORT"] == "1")
        let links = self.links
        let clientIDDefault = UserDefaults.standard
        wirelessWatcher = WirelessWatcher(
            macTag: { WirelessLink.macTag(clientID: clientIDDefault.string(forKey: "clientID") ?? "") },
            identity: { try MacIdentity.loadOrCreate(label: SessionCoordinator.identityLabel) },
            phones: { links.phones })
        directory = DeviceDirectory(watchers: [USBMuxWatcher(), androidWatcher, wirelessWatcher])
        suppressAutoConnect = env["PASSTHROUGH_NO_AUTOCONNECT"] != nil || env["PASSTHROUGH_VPN_TEST"] != nil

        logEntries = PassthroughLog.shared.snapshot()
        PassthroughLog.shared.onAppend = { [weak self] entry in
            Task { @MainActor in
                self?.logEntries.append(entry)
                if (self?.logEntries.count ?? 0) > 400 { self?.logEntries.removeFirst() }
            }
        }
        helperAvailability = helper.availability
        vpnLayer.onHelperRequired = { [weak self] in
            guard let self, !self.phase.isConnected else { return }
            self.phase = .helperRequired
        }
        directory.onChange = { [weak self] change in self?.devicesChanged(change) }
        androidWatcher.onStatusChange = { [weak self] status in self?.androidWatch = status }
        wirelessWatcher.onStatusChange = { [weak self] status in self?.wirelessWatch = status }
        wirelessWatcher.peerToPeer = peerToPeer
        wirelessWatcher.onCarrierChange = { [weak self] in self?.refreshWirelessCarrier() }
        wifiMonitor.pathUpdateHandler = { [weak self] path in
            let hotspot = path.status == .satisfied && path.isExpensive
            Task { @MainActor in
                guard let self, self.onPhoneHotspot != hotspot else { return }
                self.onPhoneHotspot = hotspot
                self.refreshWirelessCarrier()
                ptLog(.info, hotspot ? "This Mac is on a phone's hotspot (metered Wi-Fi)" : "This Mac left the phone's hotspot")
                self.syncHotspotGuard()
            }
        }
        wifiMonitor.start(queue: DispatchQueue(label: "dev.dpatel.passthrough.wifi-path"))
        _ = clientID   // the wireless listener advertises a tag derived from it
        for watcher in directory.watchers {
            switch watcher.transport {
            case .usbmux: watcher.start()
            case .adb: if androidEnabled { watcher.start() }
            case .wireless: if connectionMode != .cable { watcher.start() }
            }
        }

        ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect().sink { [weak self] _ in self?.tick() }
        NotificationCenter.default.publisher(for: .passthroughWillTerminate)
            .sink { [weak self] _ in self?.shutdownForQuit() }
            .store(in: &cancellables)
        Task {
            await ensureHelperCurrent()
            keepAwake.resume()
        }
        if let raw = env["PASSTHROUGH_DIRECT_SOCKS"], let port = UInt16(raw) {
            Task { await self.directDiagnosticConnect(socksPort: port) }
        }
        if let path = env["PASSTHROUGH_VPN_TEST"] {
            Task {
                try? await Task.sleep(for: .seconds(1))
                vpnLayer.runDiagnosticProfile(path: path, username: env["PASSTHROUGH_VPN_TEST_USER"], password: env["PASSTHROUGH_VPN_TEST_PASS"])
            }
        }
    }

    // MARK: Devices

    static let identityLabel = "dev.dpatel.passthrough.wireless-identity"

    private func devicesChanged(_ change: DeviceDirectory.Change) {
        switch change {
        case .attached(let d):
            retryAttempts = 0
            ptLog(.info, "\(d.kindName) \(d.medium == .usb ? "attached over USB" : "reachable wirelessly") (\(d.label))")
            reconsiderDevice()
        case .detached(let gone):
            ptLog(.info, "\(gone.kindName) \(gone.medium == .usb ? "detached" : "out of wireless reach")")
            reconsiderDevice()
        }
    }

    /// The phone to use: the current one while it stays attached and allowed,
    /// else the first allowed one, the cable first when both are possible.
    private func preferredDevice() -> PhoneDevice? {
        let allowed = directory.devices.filter { connectionMode.allows($0) }
        return allowed.first { $0.medium == .usb } ?? allowed.first
    }

    private func reconsiderDevice() {
        let best = preferredDevice()
        let currentStillFine = device.map { d in directory.devices.contains { $0.id == d.id } && connectionMode.allows(d) } ?? false
        // Keep a working link unless the cable just became available in Automatic.
        if currentStillFine, !(device?.medium == .wireless && best?.medium == .usb) { return }
        guard best?.id != device?.id else { return }
        if device != nil { teardown(to: best == nil ? .noDevice : .deviceFound) }
        device = best
        if best != nil {
            if phase == .noDevice { phase = .deviceFound }
            if autoConnect, !suppressAutoConnect { connect() }
        } else {
            phase = .noDevice
        }
    }

    /// On while the Mac sits on a phone's hotspot for the wireless link but
    /// passthrough isn't carrying its traffic.
    private func syncHotspotGuard() {
        let on = hotspotGuard && connectionMode != .cable && onPhoneHotspot && !phase.isConnected
        guard on != guardApplied else { return }
        guardApplied = on
        Task { await helper.setHotspotGuard(on) }
    }

    /// Over the cable, after pairing: hand the phone what it needs to reach
    /// this Mac wirelessly later (certificate pin and link key).
    private func sendLink() {
        guard let device, device.medium == .usb, let control else { return }
        do {
            let identity = try MacIdentity.loadOrCreate(label: Self.identityLabel)
            pendingLink = (links.key(forSlot: device.pairingSlot), device)
            control.link(linkKey: pendingLink!.key, certificateSHA256: identity.fingerprint)
        } catch {
            ptLog(.warning, "wireless: could not prepare the link: \(error.localizedDescription)")
        }
    }
    private var pendingLink: (key: Data, device: PhoneDevice)?

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

    private func runConnect(device: PhoneDevice, generation gen: Int) async {
        // 1. Helper
        let ready = helper.ensureRegistered()
        helperAvailability = helper.availability
        guard ready else {
            phase = .helperRequired
            return
        }
        await ensureHelperCurrent()
        await teardownTask?.value
        guard generation == gen else { return }

        // 2. Loopback forwarder over the phone's link
        phase = .connecting(device.medium == .usb ? "Opening USB link" : "Opening wireless link")
        let forwarder = LocalForwarder(device: device, remotePort: PassthroughProtocol.defaultSOCKSPort, localPort: UInt16(localPort))
        do { try forwarder.start() } catch {
            fail("Could not listen on 127.0.0.1:\(localPort): \(error.localizedDescription)")
            return
        }
        self.forwarder = forwarder
        forwarder.onFailure = { [weak self] error in Task { @MainActor in self?.fail(error.localizedDescription) } }

        // 3. Control channel
        phase = .connecting("Talking to the \(device.kindName)")
        let identity = ControlClient.Identity(clientID: clientID, name: macName, token: Keychain.read(device.pairingSlot))
        let control = ControlClient(device: device, identity: identity) { [weak self] event in
            Task { @MainActor in self?.handleControl(event, generation: gen) }
        }
        self.control = control
        control.connect()
    }

    private func handleControl(_ event: ControlClient.Event, generation gen: Int) {
        guard gen == generation, let device else { return }
        switch event {
        case .welcomed(let paired, let status, _):
            phoneStatus = status
            syncTunnelIPv6()
            retryAttempts = 0
            if paired {
                sendLink()
                Task { await bringTunnelUp(generation: gen) }
            } else {
                phase = .pairingRequired
                pairingError = nil
            }
        case .paired(let token):
            pairingInFlight = false
            guard PairingToken.isWellFormed(token) else {
                fail("The \(phoneKindName) sent a malformed pairing token")
                return
            }
            Keychain.write(token, account: device.pairingSlot)
            pairingError = nil
            ptLog(.info, "Paired with \(phoneStatus?.deviceName ?? phoneKindName)")
            sendLink()
            Task { await bringTunnelUp(generation: gen) }
        case .linked(let phoneID, let network, let passphrase):
            guard let pending = pendingLink else { return }
            pendingLink = nil
            links.record(WirelessPhone(phoneID: phoneID, linkKey: pending.key, isAndroid: pending.device.kind == .android,
                                       label: phoneStatus?.deviceName ?? pending.device.kindName,
                                       pairingSlot: pending.device.pairingSlot, network: network, passphrase: passphrase))
            ptLog(.info, "Linked \(phoneStatus?.deviceName ?? phoneKindName) for the wireless link")
        case .pairingFailed(let failure):
            pairingInFlight = false
            switch failure {
            case .badCode: pairingError = "That code didn't match. Check the digits on the \(phoneKindName)."
            case .expired: pairingError = "The code expired or wasn't generated yet. Tap Pair on the \(phoneKindName) and try again."
            case .notAuthenticated: pairingError = "Not authenticated."
            case .unsupportedVersion: pairingError = "The \(phoneKindName) app is a different version. Update both apps."
            }
        case .status(let status, _, _, let active):
            phoneStatus = status
            phoneActiveConnections = active
            syncTunnelIPv6()
            notePhoneNetwork()
        case .disconnected(let error):
            let why = error?.localizedDescription ?? "The \(phoneKindName) closed the connection"
            if case .pairingRequired = phase {
                fail("Lost the \(phoneKindName) while pairing: \(why)")
            } else if phase.isConnected || phase.isBusy {
                ptLog(.warning, "Control channel dropped: \(why)")
                fail(why.contains("refused") ? "Passthrough isn't running on the \(phoneKindName). Start it there, then connect." : why)
            }
        }
    }

    private func bringTunnelUp(generation gen: Int) async {
        guard let device, let token = Keychain.read(device.pairingSlot) else { phase = .pairingRequired; return }
        phase = .connecting("Routing the Mac through the \(phoneKindName)")
        do {
            let iface = try await helper.startTunnel(tunnelConfig(socksPort: UInt16(localPort), username: clientID, password: token, ipv6: ipv6Enabled))
            guard gen == generation else { await helper.stopTunnel(); return }
            tunnelInterface = iface
            connectedSince = Date()
            meter.reset()
            sessionRx = 0; sessionTx = 0
            phase = .connected
            tunnelIPv6 = true
            ptLog(.info, "Connected: Mac traffic now flows \(linkName) through the \(phoneKindName) via \(iface)")
            syncTunnelIPv6()
            vpnLayer.passthroughConnected()
        } catch {
            fail(error.localizedDescription)
        }
    }

    /// Mirrors the phone's IPv6 into the tunnel: without it there, the helper
    /// rejects IPv6 so apps use IPv4 at once instead of hanging. Phones too old
    /// to say leave the tunnel as it is.
    private func syncTunnelIPv6() {
        guard phase.isConnected, ipv6Enabled, let available = phoneStatus?.ipv6, available != tunnelIPv6 else { return }
        tunnelIPv6 = available
        ptLog(.info, available ? "The \(phoneKindName)'s network routes IPv6; IPv6 goes through the tunnel"
                               : "The \(phoneKindName)'s network has no IPv6; IPv6 is blocked so apps use IPv4")
        Task { await helper.setTunnelIPv6(available) }
    }

    /// A VPN session riding the passthrough dies when the phone moves between
    /// Wi-Fi and cellular (new public address); tell the helper at once.
    private func notePhoneNetwork() {
        guard phase.isConnected, let radio = phoneStatus?.radio else { return }
        let onWiFi = radio.hasPrefix("Wi-Fi")
        defer { phoneOnWiFi = onWiFi }
        guard let before = phoneOnWiFi, before != onWiFi else { return }
        ptLog(.info, "The \(phoneKindName) moved to \(onWiFi ? "Wi-Fi" : "cellular")")
        if vpnLayer.isWanted { Task { await helper.phoneNetworkChanged() } }
    }

    private func tunnelConfig(socksPort: UInt16, username: String, password: String, ipv6: Bool) -> HelperClient.TunnelConfig {
        HelperClient.TunnelConfig(socksPort: socksPort, username: username, password: password,
                                  ipv6: ipv6, dns: dnsList.isEmpty ? ["1.1.1.1", "1.0.0.1"] : dnsList, mtu: mtu)
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
        Keychain.delete(pairingSlot)
        links.forget(slot: pairingSlot)
        if phase.isConnected { disconnect() }
        objectWillChange.send()
    }

    private func fail(_ message: String) {
        ptLog(.error, message)
        teardown(to: .error(message))
        // Never give up while the user wants the link and a phone is attached:
        // the phone side may simply not be running yet. Backoff caps at 30 s.
        if wantsConnection, device != nil { scheduleRetry() }
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
        let forwarder = self.forwarder
        self.forwarder = nil
        tunnelInterface = nil
        tunnelIPv6 = nil
        phoneOnWiFi = nil
        connectedSince = nil
        phoneActiveConnections = 0
        pairingInFlight = false
        phase = next
        // Routes first, then the loopback listener: while the utun still owns the
        // default route, a closed listener would just refuse every connection.
        let previous = teardownTask
        teardownTask = Task {
            await previous?.value
            if hadTunnel { await helper.stopTunnel() }
            forwarder?.stop()
        }
    }
    /// The last teardown; a new connection waits for it, or its forwarder
    /// would find the loopback port still taken.
    private var teardownTask: Task<Void, Never>?

    private func shutdownForQuit() {
        wantsConnection = false
        for watcher in directory.watchers { watcher.stop() }
        control?.close()
        forwarder?.stop()
        // The app quits 0.8 s from now: release sleep and tear down routes side by side.
        Task { await keepAwake.shutdown() }
        Task {
            await vpnLayer.shutdown()
            await helper.stopTunnel()
            helper.invalidate()
        }
    }

    /// Restarts a stale helper; moving its registration is only safe while nothing routes through it.
    private func ensureHelperCurrent() async {
        await helper.ensureCurrent(mayReregister: !phase.isConnected && !vpnLayer.isWanted)
        helperAvailability = helper.availability
    }

    // MARK: Ticking

    private var healthTick = 0

    private func tick() {
        healthTick += 1
        // Idle (nothing connected, panel closed): do the housekeeping every 10 s only.
        let vpnWanted = vpnLayer.isWanted
        let busy = phase.isConnected || phase.isBusy || vpnWanted || panelVisible
        if !busy, healthTick % 10 != 0 { return }
        if healthTick % 10 == 1 || keepAwake.blockedReason != nil { keepAwake.checkBattery() }
        // Poll every second while the VPN is the only thing carrying traffic (it feeds the meter).
        let pollNow = (vpnWanted && !phase.isConnected) ? true : healthTick % 3 == 0
        if phase.isConnected || vpnWanted, pollNow, !statusPollInFlight { pollHelper() }
        if let forwarder {
            let snap = forwarder.counter.snapshot()
            meter.record(snap)
            sessionRx = snap.rx
            sessionTx = snap.tx
        } else if !(vpnWanted && vpnLayer.status.isConnected), meter.downRate != 0 || meter.upRate != 0 {
            meter.record(.zero)
        }
        let availability = helper.availability
        if availability != helperAvailability {
            helperAvailability = availability
            if availability == .ready, phase == .helperRequired { connect() }
        }
    }

    /// One `getStatus` round trip: VPN layer state, and whether the tunnel still runs.
    private func pollHelper() {
        let gen = generation
        let vpnGen = vpnLayer.generation
        let checkTunnel = phase.isConnected
        statusPollInFlight = true
        Task {
            let status = await helper.status()
            statusPollInFlight = false
            if vpnGen == vpnLayer.generation {
                vpnLayer.apply(status)
                let vpn = vpnLayer.status
                if vpnLayer.isWanted, vpn.isConnected, !phase.isConnected, forwarder == nil {
                    // VPN over Wi-Fi: the USB counters are idle, so meter the VPN itself.
                    meter.record(ByteCounter.Snapshot(rx: vpn.rx, tx: vpn.tx, active: 0, totalConnections: 0))
                    sessionRx = vpn.rx; sessionTx = vpn.tx
                }
            }
            guard checkTunnel, gen == generation, phase.isConnected else { return }
            if (status[TunnelStatusKey.running] as? Bool) == false {
                fail("The tunnel helper stopped unexpectedly; reconnecting")
            }
        }
    }

    // MARK: Diagnostics and previews

    /// Drive the helper straight at a local SOCKS server so the full utun +
    /// tun2socks path can be exercised without the phone.
    func directDiagnosticConnect(socksPort: UInt16) async {
        _ = helper.ensureRegistered()
        helperAvailability = helper.availability
        await ensureHelperCurrent()
        do {
            let iface = try await helper.startTunnel(tunnelConfig(socksPort: socksPort, username: "", password: "", ipv6: false))
            tunnelInterface = iface
            connectedSince = Date()
            phase = .connected
            ptLog(.info, "DIAG: tunnel up on \(iface) → 127.0.0.1:\(socksPort)")
        } catch {
            ptLog(.error, "DIAG: \(error.localizedDescription)")
        }
    }

    /// Puts the coordinator into a synthetic state for previews and snapshots.
    func debugApply(phase: Phase, device: Bool = false, status: DeviceStatus? = nil, traffic: Bool = false, vpn vpnState: String? = nil, underlay: String = "iPhone") {
        ticker?.cancel()
        for watcher in directory.watchers { watcher.onDevicesChange = nil; watcher.stop() }
        panelVisible = true
        self.phase = phase
        if let vpnState { vpnLayer.debugApply(state: vpnState, underlay: underlay) }
        self.device = device ? .iPhone(deviceID: 1, udid: "preview") : nil
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
