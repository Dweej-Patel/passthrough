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

    /// True while the menu-bar panel is on screen; animations stop otherwise.
    @Published var panelVisible = false

    // VPN layer (bundled WireGuard/OpenVPN run by the helper on top of the passthrough)
    @Published private(set) var vpn = VPNStatus()
    @Published private(set) var vpnWanted = false
    @Published private(set) var vpnError: String?
    @Published private(set) var vpnProfiles: [VPNProfile] = VPNProfileStore.load()
    @AppStorage("vpnKillSwitch") var vpnKillSwitch = true
    @AppStorage("vpnBlockIPv6") var vpnBlockIPv6 = true
    @AppStorage("vpnAutoStart") var vpnAutoStart = false
    @AppStorage("vpnActiveProfile") var vpnActiveProfileID = ""
    var activeVPNProfile: VPNProfile? { vpnProfiles.first { $0.id.uuidString == vpnActiveProfileID } ?? vpnProfiles.first }

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
    private var watchRestartTask: Task<Void, Never>?
    private var statusPollInFlight = false
    private var vpnGeneration = 0
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
        // Diagnostics: PASSTHROUGH_NO_AUTOCONNECT=1 keeps a fresh launch from
        // taking over the network; PASSTHROUGH_VPN_TEST=<conf> starts the VPN
        // layer from that file (as a temporary profile) so it can be exercised
        // without clicking through the UI.
        // Diagnostic hooks are only read when the app was launched with
        // --diagnostics, so environment variables alone can't steer a normal launch.
        #if DEBUG
        let env = CommandLine.arguments.contains("--diagnostics") ? ProcessInfo.processInfo.environment : [:]
        #else
        let env: [String: String] = [:]
        #endif
        if env["PASSTHROUGH_NO_AUTOCONNECT"] != nil || env["PASSTHROUGH_VPN_TEST"] != nil { suppressAutoConnect = true }
        startDeviceWatch()
        ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect().sink { [weak self] _ in self?.tick() }
        NotificationCenter.default.publisher(for: .passthroughWillTerminate)
            .sink { [weak self] _ in self?.shutdownForQuit() }
            .store(in: &cancellables)
        power.apply(keepAwake)
        Task { await ensureHelperCurrent(); applyLidClose(keepAwake) }
        if let raw = env["PASSTHROUGH_DIRECT_SOCKS"], let port = UInt16(raw) {
            Task { await self.directDiagnosticConnect(socksPort: port) }
        }
        if let path = env["PASSTHROUGH_VPN_TEST"] {
            Task {
                try? await Task.sleep(for: .seconds(1))
                do {
                    try self.importProfile(from: URL(fileURLWithPath: path))
                    if let p = self.vpnProfiles.last {
                        self.temporaryProfile = p
                        self.vpnActiveProfileID = p.id.uuidString
                        if let user = env["PASSTHROUGH_VPN_TEST_USER"], let pass = env["PASSTHROUGH_VPN_TEST_PASS"] {
                            self.setCredentials(username: user, password: pass, for: p)
                        }
                        ptLog(.info, "DIAG: VPN test profile \(p.name); turning VPN layer on")
                        self.setVPN(true)
                    }
                } catch { ptLog(.error, "DIAG: \(error.localizedDescription)") }
            }
        }
    }

    private var suppressAutoConnect = false
    private var temporaryProfile: VPNProfile?

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
            retryAttempts = 0
            ptLog(.info, "iPhone attached over USB (\(d.udid.prefix(8))…)")
            if device == nil {
                device = d
                phase = .deviceFound
                if autoConnect, !suppressAutoConnect { connect() }
            }
        case .detached(let id):
            devices[id] = nil
            if device?.id == id {
                ptLog(.info, "iPhone detached")
                teardown(to: devices.values.first.map { _ in .deviceFound } ?? .noDevice)
                device = devices.values.first
                if device != nil, autoConnect, !suppressAutoConnect { connect() }
            }
        case .failed(let error):
            // Coalesce: a connection can report waiting then failed; one restart only.
            guard watchRestartTask == nil else { return }
            ptLog(.error, "usbmuxd watch failed: \(error.localizedDescription); retrying")
            watchRestartTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(3))
                guard let self else { return }
                self.watchRestartTask = nil
                self.startDeviceWatch()
            }
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
            // 32 random bytes, base64: anything else is not a token this phone issued.
            guard token.count == 44, token.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "+/=".contains($0)) }) else {
                pairingInFlight = false
                fail("The iPhone sent a malformed pairing token")
                return
            }
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
            if vpnAutoStart, !vpnWanted, activeVPNProfile != nil { setVPN(true) }
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
        _ = hadTunnel
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
        connectedSince = nil
        phoneActiveConnections = 0
        pairingInFlight = false
        phase = next
        // Routes first, then the loopback listener: while the utun still owns the
        // default route, a closed listener would just refuse every connection.
        Task {
            if hadTunnel { await helper.stopTunnel() }
            forwarder?.stop()
        }
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
        let vpnOn = vpnWanted
        if let temporaryProfile { deleteProfile(temporaryProfile) }
        Task { if vpnOn { await helper.stopVPN() }; await helper.stopTunnel(); helper.invalidate() }
    }

    // MARK: VPN layer

    /// Turn the VPN layer on/off. The helper runs the engine and owns the
    /// routing; it also restarts the session by itself when passthrough
    /// connects or disconnects underneath it.
    func setVPN(_ on: Bool) {
        vpnError = nil
        vpnGeneration += 1
        guard on else {
            vpnWanted = false
            vpn = VPNStatus()
            Task { await helper.stopVPN() }
            return
        }
        guard let profile = activeVPNProfile else {
            vpnError = "Add a VPN profile in Settings ▸ VPN first."
            return
        }
        guard let text = VPNProfileStore.config(for: profile), !text.isEmpty else {
            if profile.source == .nordvpn {
                // Re-fetch Nord's profile for the same choice, then try again.
                vpnError = nil
                vpn = VPNStatus(state: "starting", name: profile.name, engine: profile.engine.rawValue)
                vpnWanted = true
                Task {
                    do { try await refreshNordServer(profile) } catch { vpnWanted = false; vpn = VPNStatus(); vpnError = error.localizedDescription }
                }
                return
            }
            vpnError = "The profile's configuration is missing. Remove it and add it again."
            return
        }
        let creds = VPNProfileStore.credentials(for: profile)
        if profile.needsCredentials, creds.username.isEmpty || creds.password.isEmpty {
            vpnError = "\(profile.name) needs a username and password. Enter them in Settings ▸ VPN."
            return
        }
        vpnWanted = true
        vpn = VPNStatus(state: "starting", name: profile.name, engine: profile.engine.rawValue)
        let config = HelperClient.VPNConfig(engine: profile.engine.rawValue, name: profile.name, config: text,
                                            username: creds.username, password: creds.password, killSwitch: vpnKillSwitch, blockIPv6: vpnBlockIPv6)
        Task {
            helperAvailability = helper.availability
            if helperAvailability == .notRegistered { helperAvailability = helper.register() }
            guard helperAvailability == .ready else {
                vpnWanted = false; vpn = VPNStatus()
                vpnError = "Approve the helper in System Settings before turning the VPN layer on."
                phase = phase.isConnected ? phase : .helperRequired
                return
            }
            await ensureHelperCurrent()
            guard vpnWanted else { return }
            do {
                try await helper.startVPN(config)
                ptLog(.info, "VPN layer starting: \(profile.name) (\(profile.engine.label))")
                await refreshVPNStatus()
            } catch {
                vpnWanted = false
                vpn = VPNStatus()
                vpnError = error.localizedDescription
                ptLog(.error, "VPN layer failed to start: \(error.localizedDescription)")
            }
        }
    }

    private func refreshVPNStatus() async {
        let status = await helper.status()
        guard vpnWanted else { return }
        let parsed = VPNStatus(from: status[VPNStatusKey.vpn] as? [String: Any] ?? [:])
        if parsed.state == "failed" {
            vpnError = (parsed.error ?? "The VPN layer failed.") + (vpnKillSwitch ? " Traffic stays blocked until you turn the VPN layer off." : "")
            vpn = parsed
            ptLog(.error, "VPN layer failed: \(parsed.error ?? "")")
            return
        }
        if parsed.state == "off" && vpn.state != "starting" {
            // Helper lost it (restart/crash); surface and reset.
            vpnWanted = false
            vpnError = "The VPN layer was stopped by the helper."
            vpn = VPNStatus()
            return
        }
        if parsed.isConnected, !vpn.isConnected {
            ptLog(.info, "VPN layer connected on \(parsed.interface ?? "?") over \(parsed.underlay ?? "?")")
        }
        if parsed.state != "off" { vpn = parsed }
    }

    // Profiles

    private func persistProfiles() { VPNProfileStore.save(vpnProfiles) }

    func selectProfile(_ profile: VPNProfile) { vpnActiveProfileID = profile.id.uuidString }

    func addProfile(_ profile: VPNProfile, config: String, username: String = "", password: String = "") {
        VPNProfileStore.setConfig(config, for: profile)
        if !username.isEmpty || !password.isEmpty { VPNProfileStore.setCredentials(username: username, password: password, for: profile) }
        vpnProfiles.append(profile)
        persistProfiles()
        if vpnProfiles.count == 1 || activeVPNProfile == nil { vpnActiveProfileID = profile.id.uuidString }
    }

    func updateProfile(_ profile: VPNProfile) {
        guard let i = vpnProfiles.firstIndex(where: { $0.id == profile.id }) else { return }
        vpnProfiles[i] = profile
        persistProfiles()
    }

    @discardableResult
    func setCredentials(username: String, password: String, for profile: VPNProfile) -> Bool {
        let ok = VPNProfileStore.setCredentials(username: username, password: password, for: profile)
        objectWillChange.send()
        return ok
    }

    func deleteProfile(_ profile: VPNProfile) {
        if vpnWanted, activeVPNProfile?.id == profile.id { setVPN(false) }
        VPNProfileStore.deleteSecrets(for: profile)
        vpnProfiles.removeAll { $0.id == profile.id }
        persistProfiles()
        if vpnActiveProfileID == profile.id.uuidString { vpnActiveProfileID = vpnProfiles.first?.id.uuidString ?? "" }
    }

    func importProfile(from url: URL) throws {
        let text = try String(contentsOf: url, encoding: .utf8)
        let profile = try VPNProfileStore.importProfile(named: url.lastPathComponent, text: text)
        addProfile(profile, config: text)
        ptLog(.info, "Imported VPN profile \(profile.name) (\(profile.engine.label))")
    }

    /// Creates (or refreshes) a NordVPN profile from Nord's recommended server.
    func addNordProfile(username: String, password: String, countryID: Int?, countryName: String?, cityID: Int? = nil, cityName: String? = nil, tcp: Bool) async throws {
        let server = try await NordVPN.recommend(countryID: countryID, cityID: cityID, tcp: tcp)
        let text = try await NordVPN.profileText(for: server, tcp: tcp)
        var profile = VPNProfile(name: "NordVPN · \(server.hostname.split(separator: ".").first ?? "server")", engine: .openvpn, source: .nordvpn)
        profile.server = server.hostname
        profile.location = server.locationText
        profile.nordProtocol = tcp ? "tcp" : "udp"
        profile.nordCountryID = countryID
        profile.nordCountryName = countryName
        profile.nordCityID = cityID
        profile.nordCityName = cityName
        profile.needsCredentials = true
        addProfile(profile, config: text, username: username, password: password)
        vpnActiveProfileID = profile.id.uuidString
        ptLog(.info, "Added NordVPN profile \(server.hostname) (\(server.locationText), load \(server.load)%)")
    }

    /// Edit a NordVPN profile's area/protocol in place: fetches the matching
    /// server and, if this profile is live, restarts the VPN on it.
    func updateNordProfile(_ profile: VPNProfile, countryID: Int?, countryName: String?, cityID: Int?, cityName: String?, tcp: Bool, name: String?) async throws {
        let server = try await NordVPN.recommend(countryID: countryID, cityID: cityID, tcp: tcp)
        let text = try await NordVPN.profileText(for: server, tcp: tcp)
        var updated = profile
        updated.nordCountryID = countryID; updated.nordCountryName = countryName
        updated.nordCityID = cityID; updated.nordCityName = cityName
        updated.nordProtocol = tcp ? "tcp" : "udp"
        updated.server = server.hostname
        updated.location = server.locationText
        let auto = "NordVPN · \(server.hostname.split(separator: ".").first ?? "server")"
        updated.name = (name?.isEmpty == false && name != profile.name) ? name! : (profile.name.hasPrefix("NordVPN · ") ? auto : profile.name)
        VPNProfileStore.setConfig(text, for: updated)
        updateProfile(updated)
        ptLog(.info, "NordVPN profile updated: \(server.hostname) (\(server.locationText), load \(server.load)%)")
        if vpnWanted, activeVPNProfile?.id == profile.id { setVPN(false); setVPN(true) }
    }

    func renameProfile(_ profile: VPNProfile, to name: String) {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        var updated = profile; updated.name = name
        updateProfile(updated)
    }

    func refreshNordServer(_ profile: VPNProfile) async throws {
        let tcp = profile.nordProtocol == "tcp"
        let server = try await NordVPN.recommend(countryID: profile.nordCountryID, cityID: profile.nordCityID, tcp: tcp)
        let text = try await NordVPN.profileText(for: server, tcp: tcp)
        var updated = profile
        updated.name = "NordVPN · \(server.hostname.split(separator: ".").first ?? "server")"
        updated.server = server.hostname
        updated.location = server.locationText
        VPNProfileStore.setConfig(text, for: updated)
        updateProfile(updated)
        ptLog(.info, "NordVPN profile now uses \(server.hostname) (\(server.locationText), load \(server.load)%)")
        if vpnWanted, activeVPNProfile?.id == profile.id {
            vpnWanted = false
            Task { await helper.stopVPN(); setVPN(true) }
        }
    }

    // MARK: Helper version management

    private func ensureHelperCurrent() async {
        guard helper.availability == .ready else { return }
        guard let v = await helper.version() else { return }
        var restart = false
        if v != HelperConstants.version {
            ptLog(.warning, "Helper version \(v) ≠ \(HelperConstants.version); restarting helper")
            restart = true
        }
        // Only re-home the daemon when nothing is running through it.
        if !phase.isConnected, !vpnWanted, Bundle.main.bundleURL.path.hasPrefix("/Applications/") {
            let status = await helper.status()
            if let path = status[TunnelStatusKey.helperPath] as? String, await helper.reregisterIfStale(helperPath: path) {
                helperAvailability = helper.availability
                restart = true
            }
        }
        guard restart else { return }
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
        healthTick += 1
        // Idle (nothing connected, panel closed): do the housekeeping every 10 s only.
        let busy = phase.isConnected || phase.isBusy || vpnWanted || panelVisible
        if !busy, healthTick % 10 != 0 { return }
        if healthTick % 10 == 1 || keepAwakeBlockedReason != nil { checkBattery() }
        // Poll every second while the VPN is the only thing carrying traffic (it feeds the meter).
        let pollNow = (vpnWanted && !phase.isConnected) ? true : healthTick % 3 == 0
        if phase.isConnected || vpnWanted, pollNow, !statusPollInFlight {
            let gen = generation
            let vpnGen = vpnGeneration
            let checkTunnel = phase.isConnected
            statusPollInFlight = true
            Task {
                let status = await helper.status()
                self.statusPollInFlight = false
                if self.vpnWanted, vpnGen == self.vpnGeneration {
                    let parsed = VPNStatus(from: status[VPNStatusKey.vpn] as? [String: Any] ?? [:])
                    if parsed.isConnected, !self.phase.isConnected, self.forwarder == nil {
                        // VPN over Wi-Fi: the USB counters are idle, so meter the VPN itself.
                        self.meter.record(ByteCounter.Snapshot(rx: parsed.rx, tx: parsed.tx, active: 0, totalConnections: 0))
                        self.sessionRx = parsed.rx; self.sessionTx = parsed.tx
                    }
                    if parsed.state == "failed" {
                        // Stay "on" with the block in place: only an explicit toggle
                        // off lifts the kill switch after a fatal failure.
                        if self.vpn.state != "failed" {
                            ptLog(.error, "VPN layer failed: \(parsed.error ?? "")")
                            self.vpnError = (parsed.error ?? "The VPN layer failed.") + (self.vpnKillSwitch ? " Traffic stays blocked until you turn the VPN layer off." : "")
                        }
                        self.vpn = parsed
                    } else if parsed.state == "off", !status.isEmpty {
                        self.vpnWanted = false
                        self.vpnError = "The VPN layer was stopped by the helper."
                        self.vpn = VPNStatus()
                    } else if parsed.state != "off" {
                        if parsed.isConnected, !self.vpn.isConnected {
                            ptLog(.info, "VPN layer connected on \(parsed.interface ?? "?") over \(parsed.underlay ?? "?")")
                        }
                        self.vpn = parsed
                    }
                }
                guard checkTunnel, gen == self.generation, self.phase.isConnected else { return }
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
        } else if !(vpnWanted && vpn.isConnected), meter.downRate != 0 || meter.upRate != 0 {
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
    func debugApply(phase: Phase, device: Bool = false, status: DeviceStatus? = nil, traffic: Bool = false, vpn vpnState: String? = nil, underlay: String = "iPhone") {
        ticker?.cancel()
        listenConnection?.cancel()
        panelVisible = true
        self.phase = phase
        if let vpnState {
            vpnWanted = true
            var v = VPNStatus(state: vpnState, name: "NordVPN · us9591", engine: "openvpn")
            v.interface = "utun9"; v.underlay = underlay; v.since = Date().addingTimeInterval(-612)
            vpn = v
        }
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

/// The helper's view of the VPN layer, as reported by `getStatus`.
struct VPNStatus: Equatable {
    var state = "off"
    var name = ""
    var engine = ""
    var interface: String?
    var since: Date?
    var rx: Int64 = 0
    var tx: Int64 = 0
    var error: String?
    var underlay: String?
    var handshakeAge: Int?
    var dns: [String] = []
    var endpoint: String?

    init(state: String = "off", name: String = "", engine: String = "") {
        self.state = state; self.name = name; self.engine = engine
    }

    init(from dict: [String: Any]) {
        state = dict[VPNStatusKey.state] as? String ?? "off"
        name = dict[VPNStatusKey.name] as? String ?? ""
        engine = dict[VPNStatusKey.engine] as? String ?? ""
        interface = dict[VPNStatusKey.interface] as? String
        if let t = dict[VPNStatusKey.since] as? Double { since = Date(timeIntervalSince1970: t) }
        rx = Int64(dict[VPNStatusKey.rxBytes] as? Int ?? 0)
        tx = Int64(dict[VPNStatusKey.txBytes] as? Int ?? 0)
        error = dict[VPNStatusKey.error] as? String
        underlay = dict[VPNStatusKey.underlay] as? String
        handshakeAge = dict[VPNStatusKey.handshakeAge] as? Int
        dns = dict[VPNStatusKey.dns] as? [String] ?? []
        endpoint = dict[VPNStatusKey.endpoint] as? String
    }

    var isConnected: Bool { state == "connected" }
    var isBusy: Bool { state == "starting" || state == "reconnecting" || state == "blocked" }
    var engineLabel: String { engine == "wireguard" ? "WireGuard" : engine == "openvpn" ? "OpenVPN" : engine }
    var duration: TimeInterval? { since.map { Date().timeIntervalSince($0) } }
}
