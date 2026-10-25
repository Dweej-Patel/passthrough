import Foundation
import Combine
import IrohTransport
import PassthroughCore
import PhoneTransport
import ScreenHost
import ShellHost

/// The Mac's remote shell, for the app: a listener while the setting is on,
/// the sessions it hosts, the phones allowed in, and the recorded history.
/// The engine is `ShellHost`; this only wires it up and publishes its state.
@MainActor
final class RemoteShellController: ObservableObject {
    @Published private(set) var sessions: [ShellSessionInfo] = []
    @Published private(set) var phones: [ShellPhone] = []
    @Published private(set) var history: [ShellHistoryEntry] = []
    @Published private(set) var historyBytes: Int64 = 0
    @Published private(set) var listenerError: String?
    /// Phones seeing the screen right now, through Screen Sharing.
    @Published private(set) var screenViewers: [ScreenViewer] = []
    /// Whether macOS's own Screen Sharing is on (and only it listens on its
    /// port); nil until checked.
    @Published private(set) var screenSharingOn: Bool?
    /// Why phones can't be relayed to Screen Sharing even though something
    /// may be listening (an impostor on its port, or no helper to check).
    @Published private(set) var screenSharingProblem: String?
    /// Asks the root helper who listens on Screen Sharing's port (nil: no
    /// answer). Set before `start`: the listeners relay a phone to Screen
    /// Sharing only once it says `.genuine`.
    var screenSharingCheck: (@Sendable () async -> ScreenSharingCheck.Result?)?
    /// What streaming the screen itself needs (Screen Recording, Accessibility); without both, phones fall back to Screen Sharing.
    @Published private(set) var screenVideo = ScreenVideoAccess(capture: false, control: false)

    struct ScreenVideoAccess: Equatable {
        var capture: Bool
        var control: Bool
        var ready: Bool { capture && control }
    }

    struct ScreenViewer: Equatable, Identifiable {
        let phoneID: String
        var label: String
        /// A phone may have more than one view open.
        var connections: Int
        var id: String { phoneID }
    }

    /// "Reach this Mac from anywhere (built-in)": an iroh endpoint beside the
    /// TLS listener while Remote shell is on. Turning it off closes iroh
    /// connections; sessions and the TLS listener carry on.
    @Published var reachAnywhere: Bool = UserDefaults.standard.object(forKey: RemoteShellController.reachAnywhereKey) as? Bool ?? true {
        didSet {
            guard reachAnywhere != oldValue else { return }
            UserDefaults.standard.set(reachAnywhere, forKey: Self.reachAnywhereKey)
            updateReach { $0.reachAnywhere = reachAnywhere }
            if reachAnywhere { startIroh() } else { stopIroh() }
        }
    }
    /// The relays the endpoint uses (n0's public ones unless a URL is set),
    /// handed to phones in grants and `macInfo`. A change restarts the endpoint.
    @Published var relay: IrohRelayConfig = RemoteShellController.loadRelay() {
        didSet {
            guard relay != oldValue else { return }
            saveRelay()
            updateReach { $0.relay = relay }
            restartIroh()
        }
    }
    @Published private(set) var irohStatus = IrohStatus()

    /// How long finished sessions' transcripts are kept. Pruned at launch,
    /// when this changes and whenever a session ends (`pruneHistory`).
    @Published var historyRetention: HistoryRetention = RemoteShellController.loadRetention() {
        didSet {
            guard historyRetention != oldValue else { return }
            UserDefaults.standard.set(historyRetention.rawValue, forKey: Self.historyRetentionKey)
            pruneHistory()
        }
    }

    enum HistoryRetention: Int, CaseIterable, Identifiable {
        case week = 7, month = 30, quarter = 90
        case forever = 0
        static let standard = HistoryRetention.month
        var id: Int { rawValue }
        var title: String {
            switch self {
            case .week: "7 days"
            case .month: "30 days"
            case .quarter: "90 days"
            case .forever: "Forever"
            }
        }
        /// "kept for 30 days", for copy about the recordings.
        var keptFor: String { self == .forever ? "kept until you delete them" : "kept for \(title)" }
        /// Sessions that ended before this go; nil: none for their age (the size cap still holds).
        func cutoff(now: Date = Date()) -> Date? {
            self == .forever ? nil : now.addingTimeInterval(-TimeInterval(rawValue) * 86_400)
        }
    }

    struct IrohStatus: Equatable {
        enum State: Equatable { case off, starting, running, failed(String) }
        var state = State.off
        var endpointID: String?
        var homeRelay: String?
        /// Phones connected over iroh, by phone ID.
        var paths: [String: IrohPath] = [:]
        var shortID: String? { endpointID.map { String($0.prefix(10)) } }
    }

    nonisolated private static let reachAnywhereKey = "remoteShellReachAnywhere"
    nonisolated private static let relayURLKey = "remoteShellRelayURL"
    nonisolated private static let secretKeyAccount = "iroh.secretKey"
    nonisolated private static let relayTokenAccount = "iroh.relayToken"
    nonisolated private static let historyRetentionKey = "remoteShellHistoryRetentionDays"

    private let store = ShellAccessStore(secrets: KeychainSecretStore())
    /// What `macInfo` and grants say, kept current here and read on the
    /// listeners' queues (cached values only). Written on the main actor.
    private let reach = Locked(ShellReach(reachAnywhere: true))
    /// The running iroh endpoint and its listener; a new one on each start.
    private var iroh: IrohRun?
    private var statusRefresh: Task<Void, Never>?
    private let transcripts: TranscriptStore?
    private let manager: ShellSessionManager?
    /// A stopped listener cannot start again: each start makes a new one.
    private var listener: ShellListener?
    /// Shared by both listeners, so the caps on views of the screen hold across them.
    private let screenViews = ScreenViewLimit()
    /// Phones' addresses that proved a shell key lately, kept across launches
    /// for the LAN/Tailscale listener's reserved handshake slots.
    private let provenPeers = FileProvenAddressStore.inApplicationSupport(named: "ProvenShellPeers")
    /// Starts and stops in order, off the main thread (ending sessions waits for them).
    private let lifecycle = DispatchQueue(label: "\(PassthroughProtocol.identifier).shell-lifecycle")
    /// History reads: at most one a second from session changes, and only the latest one's result is kept.
    private static let historyRefreshInterval: TimeInterval = 1
    private var historyRefreshScheduled = false
    private var lastHistoryRefresh = Date.distantPast
    private var historyReads = 0

    /// Shell access was revoked (from Settings or a forgotten pairing), with
    /// the pairing slots of the phones that lost it.
    var onAccessRevoked: ((Set<String>) -> Void)?

    /// What happened on this Mac, for phones' timelines (`MacEventRecorder` writes it).
    let events: MacEventLog = (try? MacEventLog.defaultFile()).map { MacEventLog(file: $0) } ?? MacEventLog(file: nil)

    /// A phone allowed to change Keep awake and the VPN asked to (`MacStateBridge` carries it out).
    var onMacControl: ((_ label: String, _ change: MacControl) -> Void)?
    /// The Mac's state as phones see it, without each phone's own `control`;
    /// read on the listeners' queues. Nil until the app sets one.
    private let macState = Locked<MacState?>(nil)

    /// The port the listener is on, once listening.
    var port: UInt16? { listener?.port }

    init() {
        do {
            let transcripts = try TranscriptStore(directory: TranscriptStore.defaultDirectory())
            let manager = ShellSessionManager(transcripts: transcripts)
            self.transcripts = transcripts
            self.manager = manager
            manager.onChange = { [weak self] in
                Task { @MainActor in
                    self?.refreshSessions()
                    // Phones hear of new, ended and waiting sessions without asking.
                    self?.listener?.pushSessions()
                    self?.iroh?.listener?.pushSessions()
                }
            }
        } catch {
            ptLog(.error, "shell: could not open the history folder: \(error.localizedDescription)")
            transcripts = nil
            manager = nil
            listenerError = "Could not open the shell history folder: \(error.localizedDescription)"
        }
        reach.set(ShellReach(reachAnywhere: reachAnywhere, relay: relay))
        refreshPhones()
        pruneHistory()
    }

    // MARK: Listener

    func start(identity: MacIdentity) {
        guard listener == nil else { return }
        guard let manager, let transcripts else { return }
        let store = self.store, reach = self.reach
        updateReach { $0.addresses = Self.localAddresses() }
        let listener = ShellListener(
            identity: identity, manager: manager, transcripts: transcripts,
            shellKeys: { store.candidateKeys(forPhone: $0) },
            keyConfirmed: { store.confirmCurrentKey(phoneID: $0, proven: $1) },
            phoneLabel: { id in store.phones.first { $0.phoneID == id }?.label ?? "Phone" },
            provenAddresses: provenPeers,
            macInfo: { reach.get().macInfo() })
        listener.onSessionEvent = { text in ptLog(.info, "shell: \(text)") }
        listener.screenAllowed = { store.screenAllowed(forPhone: $0) }
        listener.screenSharingVerified = screenSharingVerifier()
        listener.screenVideo = Self.screenVideoSource
        listener.screenViews = screenViews
        listener.onScreenViewer = screenViewerHandler()
        listener.macState = macStateProvider()
        listener.onMacControl = macControlHandler()
        listener.macEvents = { [events] _, since in events.since(since) }
        listener.onFailure = { [weak self, weak listener] error in
            Task { @MainActor in
                guard let self, let listener, self.listener === listener else { return }
                self.listenerError = "Remote shell stopped: \(error.localizedDescription). Turn it off and on to try again."
            }
        }
        self.listener = listener
        listenerError = nil
        // After any earlier stop has finished, so its port is free again.
        lifecycle.async {
            do {
                try listener.start()
                ptLog(.info, "shell: listener started")
            } catch {
                ptLog(.error, "shell: listener could not start: \(error.localizedDescription)")
                Task { @MainActor [weak self] in
                    guard let self, self.listener === listener else { return }
                    self.listenerError = "Remote shell could not start: \(error.localizedDescription)"
                }
            }
        }
        startIroh()
        startStatusRefresh()
    }

    /// Ends every session, then stops listening, then ends any session a phone
    /// opened meanwhile: no shell outlives the setting. Returns at once; `wait`
    /// (quitting) also ends the sessions before returning, so transcripts get
    /// their end time, without queueing behind an iroh bind or waiting for the
    /// teardown (the process exiting closes the sockets).
    func stop(wait: Bool = false) {
        guard let listener else { return }
        self.listener = nil
        listenerError = nil
        statusRefresh?.cancel(); statusRefresh = nil
        let run = detachIroh()
        let manager = self.manager
        let work = {
            manager?.closeAll()
            // Done once the port is free (so a restart can bind it) and no
            // connection is left to open a session.
            let released = DispatchSemaphore(value: 0)
            listener.stop { released.signal() }
            if released.wait(timeout: .now() + 5) == .timedOut {
                ptLog(.warning, "shell: the listener took too long to stop")
            }
            run?.teardown()
            manager?.closeAll()
            ptLog(.info, "shell: listener stopped")
        }
        lifecycle.async(execute: work)
        if wait { manager?.closeAll() }
        screenViewers = []
    }

    // MARK: Reach from anywhere (iroh)

    /// The iroh details for a cable grant: nil unless the endpoint is up.
    var irohGrant: ShellReach.Iroh? { reach.get().iroh }

    private func updateReach(_ change: (inout ShellReach) -> Void) {
        var value = reach.get()
        change(&value)
        reach.set(value)
    }

    /// While Remote shell is on and the setting is: a new endpoint (from the
    /// stored secret key) and its listener, set up on `lifecycle` after any
    /// earlier one is torn down.
    private func startIroh() {
        guard iroh == nil, listener != nil, reachAnywhere, let manager, let transcripts else { return }
        let run = IrohRun()
        iroh = run
        irohStatus = IrohStatus(state: .starting)
        let store = self.store, reach = self.reach, relay = self.relay, onScreenViewer = screenViewerHandler()
        let screenViews = self.screenViews
        let macState = macStateProvider(), onMacControl = macControlHandler(), events = self.events
        let screenSharingVerified = screenSharingVerifier()
        lifecycle.async { [weak self] in
            let host: IrohEndpointHost
            do {
                let key = try Self.loadOrCreateSecretKey()
                host = try IrohRun.bind(secretKey: key, relay: relay)
            } catch {
                ptLog(.error, "iroh: endpoint could not start: \(error.localizedDescription)")
                Task { @MainActor [weak self] in
                    guard let self, self.iroh === run else { return }
                    self.irohStatus = IrohStatus(state: .failed("Could not start: \(error.localizedDescription)"))
                }
                return
            }
            // n0's relays: give the endpoint a moment to pick its home relay,
            // so the first phones told about it hear of the relay too.
            // Bounded (5 s) and cut short by a stop, so quitting never waits on it.
            if relay.url == nil {
                for _ in 0..<20 where host.homeRelay == nil && !run.isStopped {
                    Thread.sleep(forTimeInterval: 0.25)
                }
            }
            if run.isStopped {
                IrohRun.shutdown(host)
                return
            }
            let listener = IrohShellListener(
                host: host, manager: manager, transcripts: transcripts,
                shellKeys: { store.candidateKeys(forPhone: $0) },
                keyConfirmed: { store.confirmCurrentKey(phoneID: $0, proven: $1) },
                phoneLabel: { id in store.phones.first { $0.phoneID == id }?.label ?? "Phone" },
                macInfo: { reach.get().macInfo() })
            listener.onSessionEvent = { text in ptLog(.info, "shell: \(text)") }
            listener.screenAllowed = { store.screenAllowed(forPhone: $0) }
            listener.screenSharingVerified = screenSharingVerified
            listener.screenVideo = Self.screenVideoSource
            listener.screenViews = screenViews
            listener.onScreenViewer = onScreenViewer
            listener.macState = macState
            listener.onMacControl = onMacControl
            listener.macEvents = { _, since in events.since(since) }
            listener.onFailure = { [weak self] error in
                Task { @MainActor in
                    guard let self, self.iroh === run else { return }
                    // No more handing out a dead endpoint in grants and macInfo.
                    self.updateReach { $0.endpointID = nil; $0.homeRelay = nil }
                    self.irohStatus.state = .failed("Stopped: \(error.localizedDescription). Turn it off and on to try again.")
                }
            }
            guard run.attach(host: host, listener: listener) else {
                // Stopped meanwhile.
                IrohRun.shutdown(host)
                return
            }
            listener.start()
            let id = host.endpointID, home = host.homeRelay
            ptLog(.info, "iroh: endpoint \(id.prefix(10)) started")
            Task { @MainActor [weak self] in
                guard let self, self.iroh === run else { return }
                self.updateReach { $0.endpointID = id; $0.homeRelay = home }
                self.irohStatus = IrohStatus(state: .running, endpointID: id, homeRelay: home)
            }
        }
    }

    /// Stops the iroh listener and shuts the endpoint down (on `lifecycle`).
    private func stopIroh() {
        guard let run = detachIroh() else { return }
        lifecycle.async { run.teardown() }
    }

    /// Forgets the running endpoint here; the caller tears it down.
    private func detachIroh() -> IrohRun? {
        guard let run = iroh else { return nil }
        iroh = nil
        run.markStopped()
        updateReach { $0.endpointID = nil; $0.homeRelay = nil }
        irohStatus = IrohStatus()
        return run
    }

    private func restartIroh() {
        guard iroh != nil else { return }
        stopIroh()
        startIroh()
    }

    /// Deletes the endpoint's secret key: phones' iroh details for this Mac
    /// stop working until they hear the new id. A running endpoint restarts
    /// with a new key.
    func resetIrohIdentity() {
        let running = iroh != nil
        stopIroh()
        lifecycle.async {
            KeychainSecretStore().delete(Self.secretKeyAccount)
            ptLog(.info, "iroh: built-in identity reset")
        }
        if running { startIroh() }
    }

    /// The stored endpoint key, or a new one stored first. Never logged.
    private nonisolated static func loadOrCreateSecretKey() throws -> Data {
        let secrets = KeychainSecretStore()
        if let key = secrets.read(secretKeyAccount) {
            guard key.count == 32 else { throw IrohSetupError.unreadableKey }
            return key
        }
        let key = IrohEndpointHost.newSecretKey()
        guard secrets.write(key, account: secretKeyAccount) else { throw IrohSetupError.cannotStoreKey }
        return key
    }

    private static func loadRelay() -> IrohRelayConfig {
        guard let url = UserDefaults.standard.string(forKey: relayURLKey), !url.isEmpty else { return IrohRelayConfig() }
        let token = KeychainSecretStore().read(relayTokenAccount).flatMap { String(data: $0, encoding: .utf8) }
        return IrohRelayConfig(url: url, token: token?.isEmpty == true ? nil : token)
    }

    private func saveRelay() {
        let secrets = KeychainSecretStore()
        if let url = relay.url {
            UserDefaults.standard.set(url, forKey: Self.relayURLKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.relayURLKey)
        }
        if let token = relay.token, !token.isEmpty, relay.url != nil {
            if !secrets.write(Data(token.utf8), account: Self.relayTokenAccount) {
                listenerError = "Could not save the relay token in the Keychain."
            }
        } else {
            secrets.delete(Self.relayTokenAccount)
        }
    }

    /// While Remote shell is on: this Mac's addresses, the endpoint's home
    /// relay and how each phone is connected, every few seconds.
    private func startStatusRefresh() {
        statusRefresh?.cancel()
        statusRefresh = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard !Task.isCancelled, let self else { return }
                await self.refreshStatus()
            }
        }
    }

    private func refreshStatus() async {
        let run = iroh
        let (addresses, home, paths) = await Task.detached(priority: .utility) {
            let addresses = Self.localAddresses()
            guard let host = run?.host, let listener = run?.listener else { return (addresses, nil as String?, [String: IrohPath]()) }
            let paths = await withCheckedContinuation { done in listener.connectionPaths { done.resume(returning: $0) } }
            return (addresses, host.homeRelay, paths)
        }.value
        guard listener != nil else { return }
        updateReach { $0.addresses = addresses }
        guard let run, iroh === run, irohStatus.state == .running else { return }
        if let home { updateReach { $0.homeRelay = home } }
        var status = irohStatus
        if let home { status.homeRelay = home }
        status.paths = paths
        if status != irohStatus { irohStatus = status }
    }

    // MARK: Sessions

    func close(_ id: String) {
        manager?.close(id)
        ptLog(.info, "shell: closed a session from this Mac")
    }

    /// The history changes when a session opens or ends, not when it gets
    /// its title (that only renames an entry) or is pruned (its entry stays).
    private func refreshSessions() {
        let updated = manager?.sessions ?? []
        let opensAndEnds = { (list: [ShellSessionInfo]) in Set(list.map { "\($0.id) \($0.running)" }) }
        let historyChanged = !opensAndEnds(updated).isSubset(of: opensAndEnds(sessions))
        let wasRunning = Set(sessions.filter(\.running).map(\.id))
        let ended = updated.contains { !$0.running && wasRunning.contains($0.id) }
        sessions = updated
        // A session that ended may be what takes the folder past its size cap.
        if ended { pruneHistory() } else if historyChanged { scheduleHistoryRefresh() }
    }

    // MARK: Phones

    func record(_ phone: ShellPhone) {
        if store.record(phone) {
            ptLog(.info, "shell: granted access to \(phone.label)")
        } else {
            ptLog(.error, "shell: could not store access for \(phone.label); it cannot open a shell")
            listenerError = "Could not save shell access for \(phone.label). Plug it in again to retry."
        }
        refreshPhones()
    }

    /// The phone's pairing moved to another slot; its access follows (see `ShellAccessStore.move`).
    func movePairing(phoneID: String, fromSlot: String, toSlot: String) {
        guard store.move(phoneID: phoneID, fromSlot: fromSlot, toSlot: toSlot) else { return }
        ptLog(.info, "shell: moved a phone's access to its own pairing")
        refreshPhones()
    }

    /// The key goes first, so the phone cannot prove itself again, then its
    /// connections and the sessions it opened (other phones' stay, even
    /// ones it was attached to).
    func revoke(_ phoneID: String) {
        let label = phones.first { $0.phoneID == phoneID }?.label ?? "a phone"
        let slots = Set(store.phones.filter { $0.phoneID == phoneID }.map(\.pairingSlot))
        if !store.revoke(phoneID: phoneID) {
            ptLog(.error, "shell: could not remove \(label)'s access")
            listenerError = "Could not remove \(label)'s access."
        } else {
            ptLog(.info, "shell: revoked access for \(label)")
        }
        listener?.disconnect(phoneID: phoneID)
        iroh?.listener?.disconnect(phoneID: phoneID)
        // The listeners also end one being opened as this runs; this covers them being off.
        manager?.closeSessions(openedBy: phoneID)
        refreshPhones()
        onAccessRevoked?(slots)
    }

    /// Every phone granted through this pairing (it was forgotten).
    func revoke(pairingSlot: String) {
        let removed = store.phones.filter { $0.pairingSlot == pairingSlot }
        if !store.revoke(pairingSlot: pairingSlot) {
            ptLog(.error, "shell: could not remove the forgotten phone's access")
            listenerError = "Could not remove the forgotten phone's shell access."
        } else if !removed.isEmpty {
            ptLog(.info, "shell: revoked access for \(removed.map(\.label).joined(separator: ", "))")
        }
        let irohListener = iroh?.listener
        for phone in removed {
            listener?.disconnect(phoneID: phone.phoneID)
            irohListener?.disconnect(phoneID: phone.phoneID)
            manager?.closeSessions(openedBy: phone.phoneID)
        }
        refreshPhones()
        onAccessRevoked?([pairingSlot])
    }

    private func refreshPhones() {
        phones = store.phones.sorted { $0.grantedAt > $1.grantedAt }
    }

    // MARK: Screen

    /// Lets the phone see and control the screen, or stops it (ending any
    /// view it has open). Stopping holds even when it can't be saved
    /// (`ShellAccessStore.setScreenAllowed`), until Passthrough quits.
    func setScreenAllowed(_ allowed: Bool, for phoneID: String) {
        let label = phones.first { $0.phoneID == phoneID }?.label ?? "a phone"
        if store.setScreenAllowed(allowed, forPhone: phoneID) {
            ptLog(.info, "shell: \(allowed ? "allowed" : "stopped allowing") \(label) to see the screen")
        } else if allowed {
            ptLog(.error, "shell: could not change \(label)'s screen access")
            listenerError = "Could not change \(label)'s screen access."
        } else {
            ptLog(.error, "shell: could not save that \(label) may no longer see the screen; off until Passthrough quits")
            listenerError = "Screen is off for \(label), but that could not be saved in the Keychain: "
                + "it may come back when Passthrough restarts. Turn it off again, or remove the phone."
        }
        if !allowed { endScreen(for: phoneID) }
        refreshPhones()
    }

    // MARK: Mac state and control

    /// The Mac's state changed: tell every connected phone.
    func updateMacState(_ state: MacState) {
        guard macState.get() != state else { return }
        macState.set(state)
        pushMacState()
    }

    private func pushMacState() {
        listener?.pushMacState()
        iroh?.listener?.pushMacState()
    }

    private func macStateProvider() -> @Sendable (String) -> MacState? {
        let store = self.store, macState = self.macState
        return { phoneID in
            guard var state = macState.get() else { return nil }
            state.control = store.controlAllowed(forPhone: phoneID)
            return state
        }
    }

    private func macControlHandler() -> @Sendable (String, String, MacControl) -> ShellError? {
        let store = self.store, macState = self.macState
        return { [weak self] phoneID, label, change in
            guard store.controlAllowed(forPhone: phoneID) else { return .notAllowed }
            if change == .vpn(true), macState.get()?.vpn == nil { return .vpnNotSetUp }
            Task { @MainActor in self?.onMacControl?(label, change) }
            return nil
        }
    }

    /// Lets the phone change Keep awake and the VPN, or stops it; as
    /// `setScreenAllowed`, stopping holds even when it can't be saved.
    func setControlAllowed(_ allowed: Bool, for phoneID: String) {
        let label = phones.first { $0.phoneID == phoneID }?.label ?? "a phone"
        if store.setControlAllowed(allowed, forPhone: phoneID) {
            ptLog(.info, "shell: \(allowed ? "allowed" : "stopped allowing") \(label) to change Keep awake and the VPN")
        } else if allowed {
            ptLog(.error, "shell: could not change what \(label) may change")
            listenerError = "Could not let \(label) change Keep awake and the VPN."
        } else {
            ptLog(.error, "shell: could not save that \(label) may no longer change Keep awake and the VPN; off until Passthrough quits")
            listenerError = "\(label) can no longer change Keep awake and the VPN, but that could not be saved in the Keychain: "
                + "it may come back when Passthrough restarts. Turn it off again, or remove the phone."
        }
        refreshPhones()
        pushMacState()
    }

    /// Ends the phone's views of the screen; its shells stay.
    func endScreen(for phoneID: String) {
        listener?.disconnectScreen(phoneID: phoneID)
        iroh?.listener?.disconnectScreen(phoneID: phoneID)
    }

    func refreshScreenSharing() async {
        let result = await screenSharingCheck?()
        screenSharingOn = result == .genuine
        screenSharingProblem = Self.screenSharingProblem(result)
        refreshScreenVideo()
    }

    private static func screenSharingProblem(_ result: ScreenSharingCheck.Result?) -> String? {
        switch result {
        case .genuine, .off: return nil
        case .impostor: return "Another app is listening on Screen Sharing's port (5900). Phones are not relayed to it: it could collect your Mac's password."
        case nil: return "Passthrough's helper isn't running, so it can't check that Screen Sharing is really macOS's. Phones are not relayed to it until it is."
        }
    }

    /// For both listeners: true only when the helper says macOS's own Screen
    /// Sharing alone listens on its port; logs why when not.
    private func screenSharingVerifier() -> @Sendable () async -> Bool {
        let check = screenSharingCheck
        return {
            let result = await check?()
            switch result {
            case .genuine: return true
            case .off: ptLog(.info, "shell: Screen Sharing is off")
            case .impostor: ptLog(.error, "shell: something other than Screen Sharing listens on port \(ScreenSharingCheck.port); not relaying a phone to it")
            case nil: ptLog(.warning, "shell: the helper did not answer, so Screen Sharing can't be checked; not relaying a phone to it")
            }
            return false
        }
    }

    func refreshScreenVideo() {
        screenVideo = ScreenVideoAccess(capture: ScreenVideoPermissions.canCapture, control: ScreenVideoPermissions.canControl)
    }

    /// For both listeners: the Mac's own H.264 stream when it may capture and post input, else nil (the phone then uses Screen Sharing).
    private static let screenVideoSource: @Sendable (String) -> (any ScreenVideoSource)? = { _ in
        ScreenVideoPermissions.isReady ? ScreenVideoStreamer() : nil
    }

    /// For both listeners: in order on the main queue (a stop must not
    /// overtake its start), counted per phone.
    private func screenViewerHandler() -> @Sendable (String, String, Bool) -> Void {
        { [weak self] phoneID, label, viewing in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.screenViewer(phoneID, label: label, viewing: viewing) }
            }
        }
    }

    private func screenViewer(_ phoneID: String, label: String, viewing: Bool) {
        var viewers = screenViewers
        if let index = viewers.firstIndex(where: { $0.phoneID == phoneID }) {
            viewers[index].connections += viewing ? 1 : -1
            if viewers[index].connections <= 0 { viewers.remove(at: index) }
        } else if viewing {
            viewers.append(ScreenViewer(phoneID: phoneID, label: label, connections: 1))
        }
        screenViewers = viewers
    }

    // MARK: History

    /// The session is still running, so its transcript is still being written.
    func isRecording(_ id: String) -> Bool {
        sessions.contains { $0.id == id && $0.running }
    }

    /// Deleting stops a transcript being written, so a running session's stays.
    func deleteHistory(_ id: String) {
        guard let transcripts, !runningIDs().contains(id) else { return }
        transcripts.delete(id: id)
        refreshHistory()
    }

    /// Every finished session's history; running sessions keep recording.
    /// The files are deleted off the main actor, then the list is read again.
    func clearHistory() {
        guard let transcripts else { return }
        Task.detached(priority: .utility) {
            // The store spares every transcript with a live writer, including a session just opening.
            transcripts.deleteFinished()
            ptLog(.info, "shell: cleared the session history")
            await MainActor.run { [weak self] in self?.refreshHistory() }
        }
    }

    /// From the manager itself, not `sessions`, which may lag a session just opened.
    private func runningIDs() -> Set<String> {
        Set((manager?.sessions ?? []).filter(\.running).map(\.id))
    }

    /// The end of the session's recorded output (at most
    /// `TranscriptStore.readLimit`), as the shell wrote it, with the terminal's
    /// sizes (`TranscriptStore.replay`), read off the main actor.
    func transcript(_ id: String) async -> [ShellReplayChunk]? {
        guard let transcripts else { return nil }
        return await Task.detached(priority: .userInitiated) {
            try? transcripts.replay(of: id, maxBytes: TranscriptStore.readLimit)
        }.value
    }

    /// Deletes finished sessions past `historyRetention`, then the oldest
    /// over `TranscriptStore.maxTotalBytes`, off the main actor; running
    /// sessions are never touched. Then reads the history again.
    func pruneHistory() {
        guard let transcripts else { return }
        let cutoff = historyRetention.cutoff()
        Task.detached(priority: .utility) {
            let deleted = transcripts.prune(endedBefore: cutoff)
            if deleted > 0 { ptLog(.info, "shell: deleted \(deleted) old session recording(s)") }
            await MainActor.run { [weak self] in self?.refreshHistory() }
        }
    }

    private static func loadRetention() -> HistoryRetention {
        (UserDefaults.standard.object(forKey: historyRetentionKey) as? Int).flatMap(HistoryRetention.init) ?? .standard
    }

    /// For session changes: refreshes at most once a second, catching up
    /// once the second is over.
    private func scheduleHistoryRefresh() {
        guard !historyRefreshScheduled else { return }
        let wait = Self.historyRefreshInterval - Date().timeIntervalSince(lastHistoryRefresh)
        guard wait > 0 else { return refreshHistory() }
        historyRefreshScheduled = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            guard let self else { return }
            self.historyRefreshScheduled = false
            self.refreshHistory()
        }
    }

    /// Reads the folder off the main thread (only entries whose files changed
    /// are decoded again: `TranscriptStore.entries`).
    func refreshHistory() {
        guard let transcripts else { return }
        lastHistoryRefresh = Date()
        historyReads += 1
        let read = historyReads
        Task.detached(priority: .utility) {
            let entries = transcripts.entries()
            let bytes = transcripts.totalBytes()
            await MainActor.run { [weak self] in
                // An older read finishing late must not undo a newer one.
                guard let self, self.historyReads == read else { return }
                self.history = entries
                self.historyBytes = bytes
            }
        }
    }

    /// This Mac's addresses a phone can dial: private networks and Tailscale.
    nonisolated static func localAddresses() -> [String] {
        LocalAddresses.advertisable()
    }

    /// Puts the controller into a synthetic state for snapshots.
    func debugApply(phones: [ShellPhone], sessions: [ShellSessionInfo], history: [ShellHistoryEntry], iroh: IrohStatus,
                    screenViewers: [ScreenViewer] = [], screenSharingOn: Bool? = nil) {
        self.phones = phones
        self.sessions = sessions
        self.history = history
        historyBytes = history.reduce(0) { $0 + $1.bytes }
        irohStatus = iroh
        self.screenViewers = screenViewers
        self.screenSharingOn = screenSharingOn
    }
}

enum IrohSetupError: LocalizedError {
    case unreadableKey, cannotStoreKey, bindTimedOut
    var errorDescription: String? {
        switch self {
        case .unreadableKey: "the built-in identity in the Keychain is unreadable; reset it"
        case .cannotStoreKey: "could not store the built-in identity in the Keychain"
        case .bindTimedOut: "the endpoint took too long to start"
        }
    }
}

/// One iroh endpoint and its listener, from start to teardown. The endpoint
/// is bound on the lifecycle queue; a stop that comes first wins.
final class IrohRun: @unchecked Sendable {
    private let lock = NSLock()
    private var _host: IrohEndpointHost?
    private var _listener: IrohShellListener?
    private var stopped = false

    var host: IrohEndpointHost? { lock.withLock { _host } }
    var listener: IrohShellListener? { lock.withLock { _listener } }

    func markStopped() { lock.withLock { stopped = true } }

    /// True once a stop has come (before or after the endpoint was bound).
    var isStopped: Bool { lock.withLock { stopped } }

    /// False if stopped meanwhile: the caller shuts `host` down.
    func attach(host: IrohEndpointHost, listener: IrohShellListener) -> Bool {
        lock.withLock {
            guard !stopped else { return false }
            _host = host
            _listener = listener
            return true
        }
    }

    /// On the lifecycle queue: listener stopped, then the endpoint shut down
    /// (which ends the accept still waiting on it).
    func teardown() {
        let (host, listener) = lock.withLock {
            stopped = true
            defer { _host = nil; _listener = nil }
            return (_host, _listener)
        }
        if let listener {
            let done = DispatchSemaphore(value: 0)
            listener.stop { done.signal() }
            if done.wait(timeout: .now() + 5) == .timedOut {
                ptLog(.warning, "iroh: the shell listener took too long to stop")
            }
        }
        if let host {
            Self.shutdown(host)
            ptLog(.info, "iroh: endpoint stopped")
        }
    }

    /// Shuts `host` down, waiting a few seconds at most.
    static func shutdown(_ host: IrohEndpointHost) {
        let done = DispatchSemaphore(value: 0)
        Task.detached { await host.shutdown(); done.signal() }
        if done.wait(timeout: .now() + 5) == .timedOut {
            ptLog(.warning, "iroh: the endpoint took too long to shut down")
        }
    }

    /// Binds an endpoint, waiting up to 15 s; one that binds later is shut down.
    static func bind(secretKey: Data, relay: IrohRelayConfig) throws -> IrohEndpointHost {
        final class Outcome: @unchecked Sendable {
            let lock = NSLock()
            var result: Result<IrohEndpointHost, Error>?
            var abandoned = false
        }
        let outcome = Outcome()
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            let result: Result<IrohEndpointHost, Error>
            do { result = .success(try await IrohEndpointHost(secretKey: secretKey, relay: relay)) } catch { result = .failure(error) }
            let abandoned = outcome.lock.withLock { () -> Bool in
                outcome.result = result
                return outcome.abandoned
            }
            if abandoned, case .success(let host) = result { await host.shutdown() }
            done.signal()
        }
        if done.wait(timeout: .now() + 15) == .timedOut {
            let finished = outcome.lock.withLock { () -> Result<IrohEndpointHost, Error>? in
                outcome.abandoned = true
                return outcome.result
            }
            // Finished just now, before seeing `abandoned`: ours to use.
            if let finished { return try finished.get() }
            throw IrohSetupError.bindTimedOut
        }
        return try outcome.lock.withLock { outcome.result! }.get()
    }
}
