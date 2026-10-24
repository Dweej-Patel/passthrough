import Foundation
import SwiftUI
import Combine
import Network
import PassthroughCore
import PhoneTransport
import ShellHost

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
    /// The outcome of the last "Register again", for Settings.
    @Published private(set) var helperNote: String?
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

    /// Also watch for Android phones through adb. On by default; harmless without platform-tools.
    @Published var androidEnabled: Bool = UserDefaults.standard.object(forKey: "androidEnabled") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(androidEnabled, forKey: "androidEnabled")
            androidEnabled ? androidWatcher.start() : androidWatcher.stop()
        }
    }

    /// Let paired phones open a shell on this Mac. Off by default.
    @Published var remoteShellEnabled: Bool = UserDefaults.standard.object(forKey: "remoteShellEnabled") as? Bool ?? false {
        didSet {
            // A snapshot run only shows the setting: nothing is saved or started.
            guard remoteShellEnabled != oldValue, !Self.isSnapshotRun else { return }
            UserDefaults.standard.set(remoteShellEnabled, forKey: "remoteShellEnabled")
            if remoteShellEnabled {
                startShell()
                if !FullDiskAccess.isGranted { fullDiskAccessPrompt = true }
                // A fresh key for every attached phone, now rather than on the next connection.
                shellGrants.reset()
                shellControlRetryAt = .distantPast
                if control != nil { sendShellGrant() } else { ensureShellControl() }
            } else {
                pendingShellGrant = nil
                shell.stop()
                // A control channel that was only open for the shell key goes too.
                if control != nil, !tunnelUsesControl {
                    ptLog(.info, "shell: closing the control channel that was open for the shell key")
                    closeControl()
                    if phase == .pairingRequired { phase = device == nil ? .noDevice : .deviceFound }
                }
            }
        }
    }
    /// Shown once when Remote shell is turned on without Full Disk Access.
    @Published var fullDiskAccessPrompt = false

    let vpnLayer: VPNLayer
    /// Per-app usage while connected (menu panel).
    let appUsage = NettopSampler()
    let keepAwake: KeepAwakeController
    let shell = RemoteShellController()

    private let helper = HelperClient()
    private let directory: DeviceDirectory
    private let androidWatcher: ADBWatcher
    private let wirelessWatcher: WirelessWatcher
    private let links = LinkStore()
    private let tokens = KeychainPairingTokens()
    private var forwarder: LocalForwarder?
    /// The control channel to the current phone. Opened by a connect, or on
    /// its own over the cable with Remote shell on (pairing, wireless link and
    /// shell key need no tunnel); a later connect reuses it.
    private var control: ControlClient?
    private var controlDeviceID: String?
    /// Bumped whenever the control channel is opened or closed, so late events from an old one are ignored.
    private var controlGeneration = 0
    private enum ControlState { case opening, paired, needsPairing }
    private var controlState = ControlState.opening
    /// The token the open control channel proves, and the slot it came from.
    private var controlPairing: PairingSlots.Stored?
    private var controlOpenedAt = Date.distantPast
    /// The connect attempt that reached the control step and waits on it.
    private var tunnelGen: Int?
    private var tunnelRequested = false
    private var tunnelUsesControl: Bool { phase.isConnected || (tunnelGen != nil && tunnelGen == generation) }
    /// Not before this, reopen a shell-only control channel the phone closed.
    private var shellControlRetryAt = Date.distantPast
    private var shellControlBackoff = ShellChannelBackoff()
    /// One automatic helper re-registration per series of connect attempts.
    private var helperRecovery = HelperRecoveryPolicy()
    /// Shell keys go out once per cable connection, not on every tunnel retry.
    private var shellGrants = ShellGrantLedger()
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
    /// Keychain slot of the attached phone's pairing token (the slot iPhones
    /// once shared when none is attached).
    private var pairingSlot: String { device?.pairingSlot ?? PhoneDevice.sharediPhonePairingSlot }
    var hasToken: Bool { device.map { PairingSlots.lookup(for: $0, in: tokens) != nil } ?? (Keychain.read(pairingSlot) != nil) }
    var linkedPhoneCount: Int { links.phones.count }
    /// "over USB" or "over Hotspot" (the wireless carrier), for status copy.
    var linkName: String { device?.medium == .wireless ? "over \(wirelessCarrier ?? "Wi-Fi")" : "over USB" }
    /// What carries the wireless link right now: "Hotspot", "Peer-to-peer",
    /// "USB", "Wi-Fi network", or "Wireless" when not known.
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
        wirelessWatcher = WirelessWatcher(
            macTag: { WirelessLink.macTag(clientID: UserDefaults.standard.string(forKey: "clientID") ?? "") },
            identity: { try MacIdentity.loadOrCreate(label: SessionCoordinator.identityLabel) },
            phones: { links.phones })
        directory = DeviceDirectory(watchers: [USBMuxWatcher(), androidWatcher, wirelessWatcher])
        suppressAutoConnect = env["PASSTHROUGH_NO_AUTOCONNECT"] != nil || env["PASSTHROUGH_VPN_TEST"] != nil
        // A snapshot run only draws views: no devices, helper, shell or network,
        // so it can't disturb the copy of the app that is routing traffic.
        guard !Self.isSnapshotRun else { return }

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
        helper.onInterrupted = { [weak self] in Task { @MainActor in self?.syncHotspotGuard() } }
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
        wifiMonitor.start(queue: DispatchQueue(label: "\(PassthroughProtocol.identifier).wifi-path"))
        _ = clientID   // the wireless listener advertises a tag derived from it
        for watcher in directory.watchers {
            switch watcher.transport {
            case .usbmux: watcher.start()
            case .adb: if androidEnabled { watcher.start() }
            case .wireless: if connectionMode != .cable { watcher.start() }
            }
        }

        // Before any listener starts: a phone is relayed to Screen Sharing
        // only once the root helper has checked who listens on its port.
        shell.screenSharingCheck = { [helper] in await ScreenSharing.check(helper) }
        if remoteShellEnabled { startShell() }
        // Revoked access: the next grant hands out a key again (also after re-pairing).
        shell.onAccessRevoked = { [weak self] slots in self?.shellAccessRevoked(pairingSlots: slots) }
        // What grants carry changed (endpoint up or down, relay, reach from
        // anywhere, identity reset): tell the phone on the cable. The ledger
        // only sends when the contents differ from what the phone holds; the
        // status also changes on every path refresh, which grants don't carry,
        // so those don't each load the identity from the Keychain.
        Publishers.Merge3(shell.$irohStatus.map { _ in () }, shell.$relay.map { _ in () }, shell.$reachAnywhere.map { _ in () })
            .receive(on: DispatchQueue.main)
            .map { [weak self] in self?.shell.irohGrant }   // nil too: the endpoint went down
            .removeDuplicates()
            .sink { [weak self] _ in self?.sendShellGrant() }
            .store(in: &cancellables)

        ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect().sink { [weak self] _ in self?.tick() }
        NotificationCenter.default.publisher(for: .passthroughWillTerminate)
            .sink { [weak self] _ in self?.shutdownForQuit() }
            .store(in: &cancellables)
        Task {
            await ensureHelperCurrent()
            keepAwake.resume()
            // A kill switch still blocking from before Passthrough crashed or
            // was killed with the VPN on: reconnect it (or show it, to turn off).
            if helper.availability == .ready { vpnLayer.checkHeld(await helper.status()) }
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

    static let identityLabel = "\(PassthroughProtocol.identifier).wireless-identity"

    private func devicesChanged(_ change: DeviceDirectory.Change) {
        switch change {
        case .attached(let d):
            retryAttempts = 0
            if d.medium == .usb { helperRecovery.reset() }
            ptLog(.info, "\(d.kindName) \(d.medium == .usb ? "attached over USB" : "reachable wirelessly") (\(d.label))")
            reconsiderDevice()
        case .detached(let gone):
            shellGrants.detached(deviceID: gone.id)
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
        if device != nil { teardown(to: best == nil ? .noDevice : .deviceFound, keepControl: false) }
        device = best
        if best != nil {
            if phase == .noDevice { phase = .deviceFound }
            shellControlRetryAt = .distantPast
            shellControlBackoff.succeeded()
            ensureShellControl()
            if autoConnect, !suppressAutoConnect { beginConnect() }
        } else {
            phase = .noDevice
        }
    }

    /// On while the Mac sits on a phone's hotspot for the wireless link but
    /// passthrough isn't carrying its traffic.
    /// Always sent, never cached here: the helper ignores repeats, and it
    /// loses the guard when it restarts or its last client goes away.
    private func syncHotspotGuard() {
        let on = hotspotGuard && connectionMode != .cable && onPhoneHotspot && !phase.isConnected
        Task { await helper.setHotspotGuard(on) }
    }

    /// Over the cable, after pairing: hand the phone what it needs to reach
    /// this Mac wirelessly later (certificate pin and link key).
    private func sendLink() {
        guard let device, device.medium == .usb, let control else { return }
        do {
            let identity = try MacIdentity.loadOrCreate(label: Self.identityLabel)
            guard let key = links.key(forSlot: device.pairingSlot) else {
                ptLog(.warning, "wireless: could not store a link key; the phone is not linked this time")
                return
            }
            pendingLink = (key, device)
            control.link(linkKey: key, certificateSHA256: identity.fingerprint)
        } catch {
            ptLog(.warning, "wireless: could not prepare the link: \(error.localizedDescription)")
        }
    }
    private var pendingLink: (key: Data, device: PhoneDevice)?

    /// The phone proved the token from the slot iPhones once shared, so the
    /// token is its own: move it, and the link key, into the phone's own slot.
    private func adoptSharedPairing(_ device: PhoneDevice) {
        guard let stored = controlPairing, stored.isShared, PairingSlots.adopt(stored, for: device, in: tokens) else { return }
        links.moveKey(fromSlot: stored.slot, toSlot: device.pairingSlot)
        controlPairing = PairingSlots.Stored(token: stored.token, slot: device.pairingSlot)
        ptLog(.info, "Moved the \(device.kindName)'s pairing to its own keychain slot")
    }

    /// An iPhone answering on the cable after proving its pairing: shell
    /// access it was granted through the slot iPhones once shared moves to
    /// its own slot, as its pairing did, so the grant now on its way can
    /// replace it. (Any iPhone could renew such access before, through the
    /// shared slot; access granted through any other slot never moves.)
    private func moveSharedShellAccess(phoneID: String, device: PhoneDevice) {
        guard device.mayUseSharedSlot else { return }
        shell.movePairing(phoneID: phoneID, fromSlot: PhoneDevice.sharediPhonePairingSlot, toSlot: device.pairingSlot)
    }

    private func startShell() {
        do {
            shell.start(identity: try MacIdentity.loadOrCreate(label: Self.identityLabel))
        } catch {
            ptLog(.error, "shell: could not load this Mac's identity: \(error.localizedDescription)")
        }
    }

    /// Over the cable, after pairing, with Remote shell on: give the phone a
    /// fresh shell key and how to reach this Mac's shell.
    private func sendShellGrant() {
        guard remoteShellEnabled, let device, device.medium == .usb, let control, controlDeviceID == device.id,
              controlState == .paired else { return }
        do {
            let identity = try MacIdentity.loadOrCreate(label: Self.identityLabel)
            // The iroh details only while the endpoint is up.
            let iroh = shell.irohGrant
            let port = shell.port ?? RemoteShell.defaultPort
            // Once per cable connection, and again whenever what a grant says changes.
            let contents = ShellGrantLedger.contents(certificateSHA256: identity.fingerprint, port: port, macName: macName,
                                                     irohID: iroh?.id, irohRelay: iroh?.relay, relayToken: iroh?.token)
            guard shellGrants.shouldGrant(deviceID: device.id, contents: contents) else { return }
            let key = ShellAccessStore.newKey()
            let grantID = UUID().uuidString
            pendingShellGrant = (key, device, grantID)
            shellGrants.sent(deviceID: device.id, contents: contents, grantID: grantID)
            control.grantShell(shellKey: key, certificateSHA256: identity.fingerprint, port: port,
                               addresses: RemoteShellController.localAddresses(), macName: macName,
                               irohID: iroh?.id, irohRelay: iroh?.relay, relayToken: iroh?.token, grantID: grantID)
            // A phone that can't store the key may never answer: don't let that block later grants.
            let deviceID = device.id
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(ShellGrantLedger.answerTimeout))
                self?.shellGrantTimedOut(deviceID: deviceID, grantID: grantID)
            }
        } catch {
            ptLog(.warning, "shell: could not prepare the grant: \(error.localizedDescription)")
        }
    }
    /// The one grant in flight (the ledger allows one per device); the
    /// phone's answer records exactly this key.
    private var pendingShellGrant: (key: Data, device: PhoneDevice, grantID: String)?

    /// The phone did not answer grant `grantID` in time: grant again after a
    /// growing delay, then every few minutes (see `ShellGrantLedger.expired`).
    private func shellGrantTimedOut(deviceID: String, grantID: String) {
        let expiry = shellGrants.expired(deviceID: deviceID, grantID: grantID)
        if expiry != .stale, pendingShellGrant?.grantID == grantID { pendingShellGrant = nil }
        let waited = Int(ShellGrantLedger.answerTimeout)
        switch expiry {
        case .stale:
            return
        case .retry(let delay, let first):
            ptLog(first ? .warning : .debug,
                  "shell: the \(phoneKindName) did not confirm its shell key in \(waited) s; it may not have stored it. Trying again in \(Int(delay)) s")
            // A little slack so the ledger's wait is surely over when this runs.
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(delay + 0.5))
                self?.sendShellGrant()
            }
        }
    }

    /// Access revoked for these pairing slots: hold grants to the attached
    /// phone if it is one of them (until a new channel or a new pairing), and
    /// drop its grant in flight so a late answer can't record that key.
    private func shellAccessRevoked(pairingSlots: Set<String>) {
        guard let device, pairingSlots.contains(device.pairingSlot) else { return }
        shellGrants.revoked(deviceID: device.id)
        if pendingShellGrant?.device.id == device.id { pendingShellGrant = nil }
    }

    // MARK: Control channel

    private func openControl(for device: PhoneDevice) {
        if control != nil, controlDeviceID == device.id { return }
        closeControl()
        controlGeneration += 1
        let cgen = controlGeneration
        let stored = PairingSlots.lookup(for: device, in: tokens)
        controlPairing = stored
        let identity = ControlClient.Identity(clientID: clientID, name: macName, token: stored?.token, tokenIsGuess: stored?.isShared ?? false)
        let control = ControlClient(device: device, identity: identity) { [weak self] event in
            Task { @MainActor in self?.handleControl(event, control: cgen) }
        }
        self.control = control
        controlDeviceID = device.id
        controlState = .opening
        controlOpenedAt = Date()
        shellGrants.channelOpened(deviceID: device.id)
        control.connect()
    }

    private func closeControl() {
        guard let control else { return }
        control.close()
        self.control = nil
        if let id = controlDeviceID { shellGrants.channelClosed(deviceID: id) }
        controlDeviceID = nil
        controlGeneration += 1
        controlState = .opening
        controlPairing = nil
        pairingInFlight = false
        pendingLink = nil
        pendingShellGrant = nil
    }

    /// With Remote shell on and a phone on the cable, keep a control channel
    /// open whether or not the Mac routes through the phone, so the phone gets
    /// paired, linked and its shell key.
    private func ensureShellControl() {
        guard remoteShellEnabled, let device, device.medium == .usb, control == nil, Date() >= shellControlRetryAt else { return }
        ptLog(.info, "shell: opening the control channel to the \(device.kindName) for pairing and the shell key")
        openControl(for: device)
    }

    /// The channel kept open for the shell waits for a pairing code.
    private var shellNeedsPairing: Bool { control != nil && controlState == .needsPairing }

    /// The connect attempt waiting on the control channel may route now.
    private func continueTunnel() {
        guard let gen = tunnelGen, gen == generation, !tunnelRequested else { return }
        tunnelRequested = true
        Task { await bringTunnelUp(generation: gen) }
    }

    // MARK: Connect flow

    /// The user asked to connect: a new series of attempts.
    func connect() {
        helperRecovery.reset()
        beginConnect()
    }

    private func beginConnect() {
        guard let device else { phase = .noDevice; return }
        // "Register again" is replacing the helper: connect once it is done.
        guard !helperRetryInFlight else {
            connectAfterHelperRetry = true
            return
        }
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
            // Pairing and the shell key still go ahead over the shell's channel.
            phase = .helperRequired
            ensureShellControl()
            return
        }
        // The previous tunnel must be gone first: whether the helper may be
        // re-registered depends on nothing still running through it.
        await teardownTask?.value
        var responded = await ensureHelperCurrent()
        guard generation == gen else { return }
        // launchd can list the helper as enabled while nothing runs behind it
        // (e.g. it was booted out); register() then only says "already
        // registered". Unregister and register it once per series of attempts.
        if helperRecovery.shouldReregister(registered: helper.availability == .ready, responded: responded,
                                           inUse: phase.isConnected || vpnLayer.isWanted) {
            ptLog(.warning, "Helper is registered but did not respond; re-registering it (once for this connection)")
            phase = .connecting("Restarting the helper")
            let result = await helper.reregister()
            helperAvailability = result.availability
            syncHotspotGuard()   // a re-registered helper starts without it
            guard generation == gen else { return }
            guard result.availability == .ready else {
                phase = .helperRequired
                ensureShellControl()
                return
            }
            responded = result.responds
            ptLog(responded ? .info : .error, responded ? "Helper responds again after re-registering"
                                                        : "Helper still does not respond after re-registering")
        }
        guard responded else {
            fail(HelperClient.HelperError.unreachable.localizedDescription)
            return
        }

        // 2. Loopback forwarder over the phone's link
        phase = .connecting(device.medium == .usb ? "Opening USB link" : "Opening wireless link")
        let forwarder = LocalForwarder(device: device, remotePort: PassthroughProtocol.defaultSOCKSPort, localPort: UInt16(localPort))
        do { try forwarder.start() } catch {
            fail("Could not listen on 127.0.0.1:\(localPort): \(error.localizedDescription)")
            return
        }
        self.forwarder = forwarder
        forwarder.onFailure = { [weak self] error in Task { @MainActor in self?.fail(error.localizedDescription) } }

        // 3. Control channel: the one already open (for the shell) or a new one
        phase = .connecting("Talking to the \(device.kindName)")
        tunnelGen = gen
        tunnelRequested = false
        if control != nil, controlDeviceID == device.id {
            switch controlState {
            case .paired: continueTunnel()
            case .needsPairing:
                phase = .pairingRequired
                pairingError = nil
            case .opening: break   // its welcome continues from here
            }
        } else {
            openControl(for: device)
        }
    }

    private func handleControl(_ event: ControlClient.Event, control cgen: Int) {
        guard cgen == controlGeneration, let device, device.id == controlDeviceID else { return }
        switch event {
        case .welcomed(let paired, let status, _):
            shellControlBackoff.succeeded()
            phoneStatus = status
            syncTunnelIPv6()
            if paired {
                controlState = .paired
                adoptSharedPairing(device)
                sendLink()
                sendShellGrant()
                continueTunnel()
            } else {
                controlState = .needsPairing
                // A connect still checking the helper reaches the control step and shows pairing itself.
                // Pairing takes the panel even over .helperRequired: it is the one
                // step the user can finish now (and it gets the phone its shell key).
                // Once paired, or if pairing is cancelled, .helperRequired returns.
                if !phase.isBusy || tunnelUsesControl {
                    phase = .pairingRequired
                    pairingError = nil
                }
            }
        case .paired(let token):
            // Only the answer to a code the user entered on this channel, once.
            guard pairingInFlight else {
                ptLog(.warning, "Ignoring a pairing the \(phoneKindName) sent unasked")
                return
            }
            pairingInFlight = false
            guard PairingToken.isWellFormed(token) else {
                fail("The \(phoneKindName) sent a malformed pairing token")
                return
            }
            Keychain.write(token, account: device.pairingSlot)
            controlPairing = PairingSlots.Stored(token: token, slot: device.pairingSlot)
            pairingError = nil
            controlState = .paired
            shellGrants.paired(deviceID: device.id)
            ptLog(.info, "Paired with \(phoneStatus?.deviceName ?? phoneKindName)")
            sendLink()
            sendShellGrant()
            if tunnelUsesControl {
                continueTunnel()
            } else if phase == .pairingRequired {
                // Paired over a channel opened for the shell. A helper that is
                // not ready comes back into view; otherwise route if that was wanted.
                helperAvailability = helper.availability
                if helperAvailability != .ready {
                    phase = .helperRequired
                } else {
                    phase = .deviceFound
                    if wantsConnection { beginConnect() }
                }
            }
        case .linked(let phoneID, let network, let passphrase):
            guard let pending = pendingLink else { return }
            pendingLink = nil
            moveSharedShellAccess(phoneID: phoneID, device: pending.device)
            links.record(WirelessPhone(phoneID: phoneID, linkKey: pending.key, isAndroid: pending.device.kind == .android,
                                       label: phoneStatus?.deviceName ?? pending.device.kindName,
                                       pairingSlot: pending.device.pairingSlot, network: network, passphrase: passphrase))
            ptLog(.info, "Linked \(phoneStatus?.deviceName ?? phoneKindName) for the wireless link")
        case .shellGranted(let phoneID, let grantID):
            guard let pending = pendingShellGrant else { return }
            // An answer to an earlier grant (e.g. one that timed out) says
            // nothing about the key in flight now. Phones that predate grant
            // IDs echo none; theirs counts for the grant in flight.
            guard ShellGrantLedger.answerMatches(echoedGrantID: grantID, inFlightGrantID: pending.grantID) else {
                ptLog(.debug, "shell: ignoring the \(phoneKindName)'s answer to an earlier shell grant")
                return
            }
            pendingShellGrant = nil
            moveSharedShellAccess(phoneID: phoneID, device: pending.device)
            guard shellGrants.confirmed(deviceID: pending.device.id, grantID: pending.grantID) else {
                // A stale answer: still make sure the phone gets what it should hold now.
                if !shellGrants.isHeld(deviceID: pending.device.id) { sendShellGrant() }
                return
            }
            shell.record(ShellPhone(phoneID: phoneID, label: phoneStatus?.deviceName ?? pending.device.kindName,
                                    pairingSlot: pending.device.pairingSlot, key: pending.key, grantedAt: Date()))
            // What grants carry may have changed while this one was in flight.
            sendShellGrant()
        case .pairingFailed(let failure):
            pairingInFlight = false
            switch failure {
            case .badCode: pairingError = "That code didn't match. Check the digits on the \(phoneKindName)."
            case .expired: pairingError = "The code expired or wasn't generated yet. Tap Pair on the \(phoneKindName) and try again."
            case .notAuthenticated: pairingError = "Not authenticated."
            case .unsupportedVersion: pairingError = "The \(phoneKindName) app is a different version. Update both apps."
            case .locked: pairingError = "Too many wrong codes. Wait \(Int(PassthroughProtocol.pairingLockout)) seconds, then try again."
            }
        case .status(let status, _, _, let active):
            phoneStatus = status
            phoneActiveConnections = active
            syncTunnelIPv6()
            notePhoneNetwork()
        case .disconnected(let error):
            let why = error?.localizedDescription ?? "The \(phoneKindName) closed the connection"
            let forTunnel = tunnelUsesControl
            // The phone closes a channel that has not paired within seconds
            // unless a code is showing. A user still reading the code off the
            // phone gets a fresh channel to type it into (not in a tight loop
            // if something closes channels at once).
            if error == nil, controlState == .needsPairing, !pairingInFlight, phase == .pairingRequired,
               Date().timeIntervalSince(controlOpenedAt) >= PassthroughProtocol.unauthenticatedTimeout / 2 {
                closeControl()
                openControl(for: device)
                return
            }
            closeControl()
            if let refused = error as? ControlClient.ControlError {
                // Retrying can't help until the user acts: say what to do.
                ptLog(.error, refused.localizedDescription)
                if !forTunnel, !phase.isConnected { phase = .error(refused.localizedDescription) }
            }
            if !forTunnel {
                // Only open for the shell: try again later, backing off while the phone keeps refusing.
                let retry = shellControlBackoff.failed()
                if retry.log { ptLog(.warning, "shell: control channel to the \(phoneKindName) closed: \(why); retrying in the background") }
                shellControlRetryAt = Date().addingTimeInterval(retry.delay)
                if phase == .pairingRequired { phase = .error("Lost the \(phoneKindName) while pairing: \(why)") }
            } else if case .pairingRequired = phase {
                fail("Lost the \(phoneKindName) while pairing: \(why)")
            } else if phase.isConnected || phase.isBusy {
                ptLog(.warning, "Control channel dropped: \(why)")
                fail(why.contains("refused") ? "Passthrough isn't running on the \(phoneKindName). Start it there, then connect." : why)
            }
        }
    }

    private func bringTunnelUp(generation gen: Int) async {
        guard gen == generation else { return }
        guard let device, let stored = PairingSlots.lookup(for: device, in: tokens) else { phase = .pairingRequired; return }
        phase = .connecting("Routing the Mac through the \(phoneKindName)")
        tunnelStartInFlight = true
        defer { if gen == generation { tunnelStartInFlight = false } }
        do {
            // The phone checks a password derived from the token, never the token itself.
            let password = ControlAuth.socksPassword(token: stored.token)
            let iface = try await helper.startTunnel(tunnelConfig(socksPort: UInt16(localPort), username: clientID, password: password, ipv6: ipv6Enabled))
            // Torn down meanwhile: teardown already queued a stop behind this start.
            guard gen == generation else { return }
            tunnelInterface = iface
            connectedSince = Date()
            retryAttempts = 0
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
        connectAfterHelperRetry = false
        // Cancelling a pairing shown over a helper that isn't ready shows the helper again.
        let helperPending = phase == .pairingRequired && !tunnelUsesControl && helper.availability != .ready
        teardown(to: device == nil ? .noDevice : helperPending ? .helperRequired : .deviceFound)
    }

    func toggle() {
        phase.isConnected || phase.isBusy || phase == .pairingRequired ? disconnect() : connect()
    }

    /// "Register again": unregister then register, which also recovers a
    /// helper launchd lists as enabled but that no longer runs.
    func retryHelper() {
        guard !helperRetryInFlight else { return }
        guard !phase.isConnected, !vpnLayer.isWanted else {
            helperNote = "The helper is in use. Disconnect first to register it again."
            return
        }
        guard !phase.isBusy, !tunnelStartInFlight else {
            helperNote = "A connection is starting. Try again once it has finished or failed."
            return
        }
        helperRetryInFlight = true
        connectAfterHelperRetry = false
        retryTask?.cancel()
        if phase == .helperRequired { teardown(to: device == nil ? .noDevice : .deviceFound) }
        helperNote = "Registering the helper again…"
        Task {
            defer { finishHelperRetry() }
            // Nothing may still be on its way to the old helper.
            await teardownTask?.value
            guard !phase.isBusy, !tunnelStartInFlight else {
                helperNote = "A connection is starting. Try again once it has finished or failed."
                return
            }
            let result = await helper.reregister()
            helperAvailability = result.availability
            helperRecovery.reset()
            syncHotspotGuard()   // a re-registered helper starts without it
            switch result.availability {
            case .ready:
                helperNote = result.responds ? "Registered again; the helper responds."
                    : "Registered again, but the helper does not respond. Check Login Items in System Settings."
                ptLog(result.responds ? .info : .error, "Helper \(result.responds ? "responds" : "does not respond") after Register again")
                if result.responds {
                    // Connect now; finishHelperRetry then has nothing left to run.
                    helperRetryInFlight = false
                    connectAfterHelperRetry = false
                    if device != nil, !phase.isConnected, !phase.isBusy { beginConnect() }
                }
            case .needsApproval:
                helperNote = "Registered again; approve Passthrough in Login Items in System Settings."
                if device != nil, !phase.isConnected, !phase.isBusy { phase = .helperRequired }
            case .notRegistered:
                helperNote = "The helper is still not registered."
            case .failed(let why):
                helperNote = "Registration failed: \(why)"
            }
        }
    }
    private var helperRetryInFlight = false
    /// A connect asked for while "Register again" ran; it runs when that ends.
    private var connectAfterHelperRetry = false

    private func finishHelperRetry() {
        helperRetryInFlight = false
        guard connectAfterHelperRetry else { return }
        connectAfterHelperRetry = false
        if device != nil, !phase.isConnected, !phase.isBusy { beginConnect() }
    }

    func openLoginItems() { HelperClient.openLoginItemsSettings() }

    func forgetPairing() {
        // Mid-connect too: the attempt's forwarder and control step go with it.
        if phase.isConnected || phase.isBusy || tunnelUsesControl || phase == .pairingRequired { disconnect() }
        // The open channel was authenticated with the forgotten token; a fresh one asks to pair.
        closeControl()
        if phase == .pairingRequired { phase = device == nil ? .noDevice : .deviceFound }
        // An iPhone still on the slot iPhones once shared forgets that one too.
        var slots = [pairingSlot]
        if let device, let stored = PairingSlots.lookup(for: device, in: tokens), stored.slot != pairingSlot { slots.append(stored.slot) }
        for slot in slots {
            Keychain.delete(slot)
            let forgotten = links.phones.filter { $0.pairingSlot == slot }.map(\.phoneID)
            links.forget(slot: slot)
            forgotten.forEach { wirelessWatcher.drop(phoneID: $0) }
            shell.revoke(pairingSlot: slot)
        }
        // The fresh channel below grants again once the phone is paired anew.
        shellGrants.reset()
        shellControlRetryAt = .distantPast
        shellControlBackoff.succeeded()
        ensureShellControl()
        objectWillChange.send()
    }

    private func fail(_ message: String) {
        ptLog(.error, message)
        teardown(to: .error(message))
        // A phone waiting to pair over the shell's channel: show pairing, and
        // connect again once paired rather than retrying behind it.
        if shellNeedsPairing {
            phase = .pairingRequired
            pairingError = nil
            return
        }
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
            self?.beginConnect()
        }
    }

    /// `keepControl`: with Remote shell on over the cable, the control channel
    /// stays open (for the shell, and for the next retry to reuse) unless the
    /// phone itself is changing.
    private func teardown(to next: Phase, keepControl: Bool = true) {
        generation += 1
        // A start still in flight counts: the helper handles calls in order, so
        // a stop sent now lands after it and before any new connection's start.
        let hadTunnel = phase.isConnected || tunnelInterface != nil || tunnelStartInFlight
        tunnelStartInFlight = false
        tunnelGen = nil
        tunnelRequested = false
        let keep = keepControl && remoteShellEnabled && device?.medium == .usb && control != nil && controlDeviceID == device?.id
        if !keep { closeControl() }
        let forwarder = self.forwarder
        self.forwarder = nil
        tunnelInterface = nil
        tunnelIPv6 = nil
        phoneOnWiFi = nil
        connectedSince = nil
        appUsage.stop()
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
    private var tunnelStartInFlight = false

    private func shutdownForQuit() {
        wantsConnection = false
        for watcher in directory.watchers { watcher.stop() }
        closeControl()
        forwarder?.stop()
        // Quitting ends every session; wait so their transcripts are finished.
        shell.stop(wait: true)
        // Release sleep and tear down routes side by side; the app quits once
        // both are done (or after a few seconds). The VPN must be turned off
        // explicitly here: the helper takes a connection that merely drops
        // for a crash, and keeps the kill switch blocking.
        let sleep = Task { await keepAwake.shutdown() }
        Task {
            await vpnLayer.shutdown()
            await helper.stopTunnel()
            await sleep.value
            helper.invalidate()
            NotificationCenter.default.post(name: .passthroughReadyToQuit, object: nil)
        }
    }

    /// Restarts a stale helper; moving its registration is only safe while nothing routes through it.
    /// False when the helper is registered but did not answer.
    @discardableResult
    private func ensureHelperCurrent() async -> Bool {
        let responded = await helper.ensureCurrent(mayReregister: !phase.isConnected && !vpnLayer.isWanted)
        helperAvailability = helper.availability
        syncHotspotGuard()   // a re-registered helper starts without it
        return responded
    }

    // MARK: Ticking

    private var healthTick = 0

    private func tick() {
        healthTick += 1
        // Idle (nothing connected, panel closed): do the housekeeping every 10 s only.
        let vpnWanted = vpnLayer.isWanted
        let busy = phase.isConnected || phase.isBusy || vpnWanted || panelVisible
        if !busy, healthTick % 10 != 0 { return }
        // Every 10 s, busy or not: these ticks are the ones that get here when
        // idle, which is exactly when a closed, kept-awake Mac needs the check.
        if healthTick % 10 == 0 || keepAwake.blockedReason != nil { keepAwake.checkBattery(); keepAwake.checkThermal() }
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
        syncAppUsage()
        let availability = helper.availability
        if availability != helperAvailability {
            helperAvailability = availability
            if availability == .ready, phase == .helperRequired { beginConnect() }
        }
        ensureShellControl()
    }

    /// Counts per-app usage on the interface apps' traffic is on: the VPN's
    /// while the VPN layer is up, otherwise the passthrough tunnel's.
    private func syncAppUsage() {
        guard phase.isConnected, let tunnelInterface, let connectedSince else {
            appUsage.stop()
            return
        }
        let vpn = vpnLayer.status
        let interface = vpn.isConnected ? (vpn.interface ?? tunnelInterface) : tunnelInterface
        appUsage.sync(session: connectedSince, interfaces: [interface])
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

    /// Launched with `--snapshot` (`PanelSnapshots`).
    static let isSnapshotRun = CommandLine.arguments.contains("--snapshot")

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
            appUsage.debugApply([
                AppUsageEntry(app: AppIdentity(key: "/Applications/Safari.app", name: "Safari"), bytesIn: 31_400_000, bytesOut: 1_200_000),
                AppUsageEntry(app: AppIdentity(key: "/System/Applications/Music.app", name: "Music"), bytesIn: 18_900_000, bytesOut: 300_000),
                AppUsageEntry(app: AppIdentity(key: "/System/Applications/Mail.app", name: "Mail"), bytesIn: 4_100_000, bytesOut: 900_000),
                AppUsageEntry(app: AppIdentity(key: "/usr/libexec/softwareupdated", name: "softwareupdated"), bytesIn: 2_600_000, bytesOut: 40_000),
                AppUsageEntry(app: AppIdentity(key: "/usr/bin/curl", name: "curl"), bytesIn: 900_000, bytesOut: 12_000),
            ])
        }
    }
}

/// Pairing tokens by keychain slot, for `PairingSlots`.
private struct KeychainPairingTokens: PairingTokenStore {
    func read(_ slot: String) -> String? { Keychain.read(slot) }
    @discardableResult func write(_ token: String, slot: String) -> Bool { Keychain.write(token, account: slot) }
    func delete(_ slot: String) { Keychain.delete(slot) }
}
