import Combine
import Foundation
import Network
import UIKit
import IrohTransport
import PassthroughCore

/// The phone's remote-shell state, a thin layer over `ShellClient`: which
/// Macs granted the shell (keys from `ShellKeyVault`), the connection to the
/// selected one, its sessions and history. Bytes and keys are never logged.
@MainActor
final class ShellModel: ObservableObject {
    enum Reach: Equatable {
        /// No Mac has granted this iPhone the shell (or the Mac refused the key).
        case noAccess
        /// Keys exist but can't be read until the app is unlocked.
        case locked
        /// The device has no passcode, so the vault can't hold the keys.
        case needsPasscode
        /// A key stays unreadable even right after a fresh unlock.
        case keyUnavailable
        case connecting
        case unreachable
        case ready

        /// What to tell the user; `fromAnywhere` when this connect also tried iroh.
        func message(fromAnywhere: Bool) -> String? {
            switch self {
            case .needsPasscode: "Set a device passcode to use Remote shell."
            case .locked: "Unlock Passthrough to use Remote shell."
            case .keyUnavailable: "Couldn't read the Remote shell key. Plug into the Mac again to renew access."
            case .noAccess: "Turn on Remote shell in Passthrough on your Mac, then connect this iPhone with the cable once."
            case .unreachable: fromAnywhere
                ? "Can't reach your Mac. Check that Remote shell is on and the Mac is awake."
                : "Can't reach your Mac. Use the same Wi-Fi, or turn on Tailscale on both devices."
            case .connecting, .ready: nil
            }
        }
    }

    @Published var macs: [ShellCredential] = []
    @Published var selectedMacID: String? {
        didSet { if selectedMacID != oldValue, !applyingRefresh { connect() } }
    }
    @Published private(set) var reach: Reach = .noAccess {
        didSet {
            // Remember when each Mac last answered, for "last heard" while it can't be reached.
            guard reach == .ready || oldValue == .ready, let mac = clientMacID else { return }
            var heard = Self.lastHeardStore
            heard[mac] = Date().timeIntervalSince1970
            UserDefaults.standard.set(heard, forKey: Self.lastHeardKey)
        }
    }
    @Published private(set) var sessions: [ShellSessionInfo] = []
    @Published private(set) var history: [ShellHistoryEntry] = []
    /// The Mac has answered a history request since this Mac was selected.
    @Published private(set) var historyLoaded = false
    @Published var openTabs: [String] = []
    @Published var activeSession: String?
    /// Sessions that have ended: their tabs show a read-only log of their output.
    @Published private(set) var ended = ShellEndedSessions()
    /// The last thing the Mac refused (too many sessions, no such session…).
    @Published private(set) var lastError: ShellError?
    /// The session another connection took over while this phone showed it;
    /// cleared when this phone attaches or opens a session again.
    @Published private(set) var detachedSession: String?
    /// How the ready connection is carried, when known.
    @Published private(set) var path: ShellPath?
    /// The selected Mac's state as it last said (kept while it can't be
    /// reached, as "last known"); nil from a Mac too old to send it.
    @Published private(set) var macState: MacState?
    /// A Keep awake or VPN change sent and not yet answered.
    @Published private(set) var pendingControl: MacControl?
    /// Why the Mac refused the last Keep awake or VPN change.
    @Published private(set) var controlError: ShellError?
    /// "Connect using": this device's choice, kept in the app's own defaults.
    @Published var connectMode: ShellConnectMode {
        didSet {
            guard connectMode != oldValue else { return }
            UserDefaults.standard.set(connectMode.rawValue, forKey: Self.connectModeKey)
            if !macs.isEmpty { connect() }
        }
    }
    /// Output for `(session, bytes)`, for the terminal views.
    let output = PassthroughSubject<(String, Data), Never>()
    /// A session's output is about to start over: sent before an attach request
    /// (`replay` true: its scrollback comes first) and when a session was just
    /// opened, so a terminal can clear first.
    let streamStarting = PassthroughSubject<(session: String, replay: Bool), Never>()
    /// The scrollback replay of an attach is complete; later output is live.
    let replayFinished = PassthroughSubject<String, Never>()

    private static let manualAddressPrefix = "shell.manualAddress."
    private static let connectModeKey = "shell.connectMode"

    private var client: ShellClient?
    private var clientMacID: String?
    /// Whether the current (or last) connect also dialled iroh.
    private var clientTriesIroh = false
    /// Where a Mac's `macInfo` is kept; set by `refresh`.
    private weak var registry: PairingRegistry?
    /// Whose evaluated context lists and deletes vault keys; set by `refresh`.
    private weak var lock: AppLock?
    /// Bumped per `ShellClient`, so a replaced client's late events are dropped.
    private var generation = 0
    private var applyingRefresh = false
    /// A relock was requested because a key read needed authentication; until a
    /// refresh reads every key, another failure shows `.keyUnavailable` instead of looping.
    private var relockRequested = false
    /// The Bonjour endpoint the current connect was given, to tell when a better one appears.
    private var dialedDiscovered: NWEndpoint?
    /// A working connection dropped (the cable unplugged while the shell
    /// used its link, Wi-Fi lost; `ShellClient` notices within seconds):
    /// how many redials have been made since. Nil when not redialling.
    private var redialsMade: Int?
    private var redialTask: Task<Void, Never>?
    /// The wait before each redial after a drop: the first at once (another
    /// path, iroh say, usually answers), then backing off. After the last,
    /// the card offers Try again.
    static let redialDelays: [TimeInterval] = [0, 1, 2, 4, 8, 15]
    /// The addresses each Mac granted, so a manual address can be applied without re-reading keys.
    private var granted: [String: [String]] = [:]
    private var size = (cols: 80, rows: 24)
    private var browser: NWBrowser?
    private var browseResults: [NWEndpoint] = []
    /// The transcript request in flight; `token` tells it from a later request for the same session.
    private var pendingTranscript: (id: String, token: UUID, replay: ShellReplay.Collector,
                                    continuation: CheckedContinuation<[ShellReplayChunk]?, Never>)?
    private var observers: [NSObjectProtocol] = []

    init() {
        connectMode = UserDefaults.standard.string(forKey: Self.connectModeKey).flatMap(ShellConnectMode.init(rawValue:)) ?? .automatic
        // Sockets don't survive suspension; leave cleanly, and `refresh` on return reconnects.
        observers.append(NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.dropConnection() }
        })
    }

    // MARK: Credentials

    /// Called on every unlock and return to the foreground: adopts pending
    /// keys, rebuilds `macs`, and (re)connects, re-attaching `activeSession`.
    func refresh(lock: AppLock, registry: PairingRegistry) {
        self.registry = registry
        self.lock = lock
        let clients = registry.clients
        let granting = clients.filter { $0.shell != nil }
        #if DEBUG
        if let demo = Self.demoState { return lock.isUnlocked ? applyDemo(demo) : clear(.locked) }
        #endif
        guard lock.isUnlocked else { return clear(granting.isEmpty ? .noAccess : .locked) }
        guard ShellKeyVault.passcodeSet else { return clear(granting.isEmpty ? .noAccess : .needsPasscode) }

        // Read at call time: the lock replaces its context on every relock.
        let context = lock.context
        ShellKeyVault.adoptPending(from: registry, context: context)
        ShellKeyVault.prune(keeping: Set(clients.map(\.id)), context: context)
        var anyLocked = false
        let built = ShellCredentials.build(clients: granting, phoneID: registry.phoneID, key: { id in
            switch ShellKeyVault.read(macID: id, context: context) {
            case let .key(data): return data
            case .locked: anyLocked = true; return nil
            case .missing: return nil
            }
        }, manualAddress: manualAddress(for:), relayToken: { registry.relayToken(clientID: $0) })
        if anyLocked {
            if !relockRequested {
                // The lock's context no longer satisfies the item: end the session so the
                // lock prompts once. Deferred: this runs inside the lock's own change handler.
                relockRequested = true
                clear(.locked)
                Task { @MainActor in if lock.isUnlocked { lock.invalidateSession() } }
                return
            }
        } else {
            relockRequested = false
        }
        granted = Dictionary(granting.compactMap { c in c.shell.map { (c.id, $0.addresses) } }, uniquingKeysWith: { a, _ in a })

        let previous = macs.first { $0.macID == clientMacID }
        applyingRefresh = true
        macs = built
        if selectedMacID.map({ id in !built.contains { $0.macID == id } }) ?? true { selectedMacID = built.first?.macID }
        applyingRefresh = false

        guard let current = built.first(where: { $0.macID == selectedMacID }) else {
            // A Mac granted access but its key isn't here: plugging in renews it.
            return clear(anyLocked || !granting.isEmpty ? .keyUnavailable : .noAccess)
        }
        startBrowsing()
        // Keep a live connection to the same Mac with the same key: a `macInfo`
        // only changed how to dial it next time. Otherwise dial again.
        if client != nil, clientMacID == current.macID, let previous {
            if reach == .ready, Self.sameKey(previous, current) { return }
            if reach == .connecting, previous == current { return }
        }
        connect()
    }

    private static func sameKey(_ a: ShellCredential, _ b: ShellCredential) -> Bool {
        a.shellKey == b.shellKey && a.certSHA256 == b.certSHA256 && a.phoneID == b.phoneID && a.port == b.port
    }

    /// What `.unreachable` says for the selected Mac.
    var reachMessage: String? { reach.message(fromAnywhere: clientTriesIroh) }

    /// When the selected Mac last answered, if it ever has on this phone.
    var lastHeard: Date? {
        guard let mac = selectedMacID, let at = Self.lastHeardStore[mac] else { return nil }
        return Date(timeIntervalSince1970: at)
    }

    private static let lastHeardKey = "PTShellLastHeard"
    private static var lastHeardStore: [String: Double] {
        UserDefaults.standard.dictionary(forKey: lastHeardKey) as? [String: Double] ?? [:]
    }

    /// Connecting again by itself after a working connection dropped.
    var isRedialing: Bool { redialsMade != nil && reach == .connecting }

    func manualAddress(for macID: String) -> String? {
        UserDefaults.standard.string(forKey: Self.manualAddressPrefix + macID)
    }

    /// Stores the address the user typed for a Mac; used from the next connect.
    func setManualAddress(_ address: String, for macID: String) {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            UserDefaults.standard.removeObject(forKey: Self.manualAddressPrefix + macID)
        } else {
            UserDefaults.standard.set(trimmed, forKey: Self.manualAddressPrefix + macID)
        }
        guard let i = macs.firstIndex(where: { $0.macID == macID }) else { return }
        macs[i].addresses = ShellCredentials.addresses(granted: granted[macID] ?? [], manual: trimmed)
    }

    /// The phone forgot this Mac: drop its key, address and any connection to it.
    func forget(macID: String) {
        ShellKeyVault.delete(macID: macID, context: lock?.isUnlocked == true ? lock?.context : nil)
        UserDefaults.standard.removeObject(forKey: Self.manualAddressPrefix + macID)
        granted[macID] = nil
        if clientMacID == macID { dropConnection(); resetSessions() }
        applyingRefresh = true
        macs.removeAll { $0.macID == macID }
        if selectedMacID == macID { selectedMacID = macs.first?.macID }
        applyingRefresh = false
        if macs.isEmpty { clear(.noAccess) } else if client == nil { connect() }
        var heard = Self.lastHeardStore
        heard[macID] = nil
        UserDefaults.standard.set(heard, forKey: Self.lastHeardKey)
    }

    func forgetAll() {
        ShellKeyVault.deleteAll()
        for id in macs.map(\.macID) + granted.keys {
            UserDefaults.standard.removeObject(forKey: Self.manualAddressPrefix + id)
        }
        granted = [:]
        clear(.noAccess)
        UserDefaults.standard.removeObject(forKey: Self.lastHeardKey)
    }

    // MARK: Connection

    /// Dials the selected Mac (replacing any connection) and, once ready,
    /// re-attaches `activeSession` (the Mac sends its sessions unasked).
    func connect() {
        #if DEBUG
        if let demo = Self.demoState { return applyDemo(demo) }
        #endif
        dropConnection()
        redialTask?.cancel()
        redialTask = nil
        guard let credential = macs.first(where: { $0.macID == selectedMacID }) else {
            redialsMade = nil
            reach = macs.isEmpty ? .noAccess : reach
            return
        }
        if clientMacID != credential.macID { resetSessions() }
        generation += 1
        let gen = generation
        clientTriesIroh = connectMode == .automatic && credential.irohID.map(IrohInfo.isValidID) == true
        // A fresh iroh endpoint (ephemeral key) per connect; the client shuts it down.
        let client = ShellClient(credential: credential, queue: .main, iroh: clientTriesIroh ? IrohShellDialer() : nil,
                                 mode: connectMode) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event, generation: gen) }
        }
        self.client = client
        clientMacID = credential.macID
        lastError = nil
        reach = .connecting
        let discovered = ShellCredentials.discovered(among: browseResults, macName: credential.macName, shellMacCount: macs.count)
        dialedDiscovered = discovered
        client.connect(discovered: discovered)
    }

    /// A connection of its own for the screen, to the selected Mac and dialled
    /// as `connect` dials the shell. The caller shuts the dialer down when done.
    func screenConnection(onEvent: @escaping (ShellClient.Event) -> Void) -> (client: ShellClient, dialer: IrohShellDialer?, mac: ShellCredential)? {
        guard let credential = macs.first(where: { $0.macID == selectedMacID }) else { return nil }
        let triesIroh = connectMode == .automatic && credential.irohID.map(IrohInfo.isValidID) == true
        let dialer = triesIroh ? IrohShellDialer() : nil
        let client = ShellClient(credential: credential, queue: .main, iroh: dialer, mode: connectMode, onEvent: onEvent)
        client.connect(discovered: ShellCredentials.discovered(among: browseResults, macName: credential.macName, shellMacCount: macs.count))
        return (client, dialer, credential)
    }

    func newSession(cols: Int, rows: Int) {
        #if DEBUG
        if Self.demoState != nil { return demoOpen() }
        #endif
        size = (cols, rows)
        lastError = nil
        client?.open(cols: cols, rows: rows)
    }

    func attach(_ id: String, cols: Int, rows: Int) {
        size = (cols, rows)
        if !openTabs.contains(id) { openTabs.append(id) }
        activeSession = id
        detachedSession = nil
        lastError = nil
        #if DEBUG
        if Self.demoState != nil { return demoReplay(id) }
        #endif
        // Not connected yet: `.ready` attaches `activeSession`, so asking now would replay twice.
        guard reach == .ready, let client else { return }
        streamStarting.send((id, true))
        client.attach(id, cols: cols, rows: rows)
    }

    func send(_ data: Data) {
        guard let active = activeSession, ended.isWritable(active) else { return }
        #if DEBUG
        if Self.demoState != nil { return output.send((active, data == Data([13]) ? Data("\r\n".utf8) : data)) }
        #endif
        client?.input(data)
    }

    func resize(cols: Int, rows: Int) {
        size = (cols, rows)
        client?.resize(cols: cols, rows: rows)
    }

    /// Ends a running session, or just closes the tab of an ended one (the
    /// Mac would refuse to close it again).
    func close(_ id: String) {
        if !ended.isEnded(id) { client?.close(id) }
        ended.forget(id)
        openTabs.removeAll { $0 == id }
        if activeSession == id { activeSession = nil }
    }

    func loadHistory() { client?.requestHistory() }

    /// Asks the Mac to turn Keep awake or its VPN on or off; `macState` follows.
    /// The caller has already asked for Face ID before turning the VPN off.
    func control(_ change: MacControl) {
        controlError = nil
        #if DEBUG
        if Self.demoState != nil { return demoControl(change) }
        #endif
        guard reach == .ready, let client else { return }
        pendingControl = change
        switch change {
        case .awake(let on): client.setAwake(on)
        case .vpn(let on): client.setVPN(on)
        }
    }

    /// The saved transcript of a session, with the terminal sizes it was drawn
    /// at (none from an older Mac), or nil when there's no connection, the Mac
    /// refused, or nothing arrived within 30 seconds.
    func transcript(_ id: String) async -> [ShellReplayChunk]? {
        #if DEBUG
        if Self.demoState != nil { return [.resize(cols: 64, rows: 20), .output(Self.demoOutput)] }
        #endif
        guard let client else { return nil }
        finishTranscript(nil)
        let token = UUID()
        return await withCheckedContinuation { continuation in
            pendingTranscript = (id, token, ShellReplay.Collector(), continuation)
            client.requestTranscript(id)
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(30))
                // Only this request's timer ends it, not an earlier one for the same session.
                guard let self, self.pendingTranscript?.token == token else { return }
                self.finishTranscript(nil)
            }
        }
    }

    // MARK: Events

    private func handle(_ event: ShellClient.Event, generation gen: Int) {
        guard gen == generation else { return }
        switch event {
        case let .ready(path):
            reach = .ready
            redialsMade = nil
            self.path = path
            // No `list`: the Mac sends `sessions` right after `ready`.
            // An ended session's log is already on screen; it has nothing more to send.
            if let active = activeSession, !ended.isEnded(active) {
                streamStarting.send((active, true))
                client?.attach(active, cols: size.cols, rows: size.rows)
            }
        case let .macInfo(info):
            apply(info)
        case let .macState(state):
            macState = state
            pendingControl = nil
        case let .sessions(list):
            sessions = list
            let ids = Set(list.map(\.id))
            // The ended session on screen keeps its tab (and log) until the user closes it.
            let kept = activeSession.flatMap { ended.isEnded($0) ? $0 : nil }
            ended.apply(list, keeping: Set([kept].compactMap { $0 }))
            openTabs.removeAll { !ids.contains($0) && $0 != kept }
            if let active = activeSession, !ids.contains(active), active != kept { activeSession = nil }
            if let detached = detachedSession, !ids.contains(detached) { detachedSession = nil }
        case let .opened(id):
            if !openTabs.contains(id) { openTabs.append(id) }
            streamStarting.send((id, false))
            activeSession = id
            detachedSession = nil
            lastError = nil
            client?.list()
        case let .output(session, data):
            output.send((session, data))
        case let .attached(session):
            replayFinished.send(session)
        case let .ended(session, exitStatus):
            ended.ended(session, exitStatus: exitStatus)
            client?.list()
        case let .detached(session):
            // Another connection took it over; don't take it back on reconnect.
            if activeSession == session {
                activeSession = nil
                detachedSession = session
            }
        case let .history(entries):
            history = entries
            historyLoaded = true
        case let .transcriptResize(session, cols, rows):
            guard pendingTranscript?.id == session else { return }
            pendingTranscript?.replay.add(Data(), cols: cols, rows: rows)
        case let .transcript(session, data, done):
            guard pendingTranscript?.id == session else { return }
            pendingTranscript?.replay.add(data)
            if done { finishTranscript(pendingTranscript?.replay.chunks) }
        case let .failed(error, _) where error == .notAllowed || error == .vpnNotSetUp:
            pendingControl = nil
            controlError = error
        case let .failed(error, session):
            lastError = error
            if error == .notAuthorized { reach = .noAccess }
            // Only a failure naming the requested session ends that request.
            if error == .noSuchSession || error == .badRequest, let session, session == pendingTranscript?.id { finishTranscript(nil) }
        case let .disconnected(error):
            let dropped = reach == .ready
            client = nil
            path = nil
            finishTranscript(nil)
            guard error != nil, reach != .noAccess else { return }
            if dropped { redialsMade = 0 }
            if let made = redialsMade, made < Self.redialDelays.count {
                redial(after: Self.redialDelays[made])
                redialsMade = made + 1
            } else {
                redialsMade = nil
                reach = .unreachable
            }
        case let .screen(stream, _):
            // The screen has its own client (`ScreenModel`); this one never asks.
            stream.cancel()
        }
    }

    // MARK: Private

    /// Keeps what the connected Mac says about reaching it (iroh details,
    /// addresses) with its grant, and uses it from the next connect. Never
    /// touches the shell key.
    private func apply(_ info: ShellEnvelope) {
        guard let macID = clientMacID, let registry,
              registry.updateShellInfo(clientID: macID, irohID: info.irohID, irohRelay: info.irohRelay,
                                       relayToken: info.relayToken, addresses: info.addresses),
              let grant = registry.clients.first(where: { $0.id == macID })?.shell else { return }
        granted[macID] = grant.addresses
        guard let i = macs.firstIndex(where: { $0.macID == macID }) else { return }
        macs[i].addresses = ShellCredentials.addresses(granted: grant.addresses, manual: manualAddress(for: macID))
        macs[i].irohID = grant.irohID
        macs[i].irohRelay = grant.irohRelay
        macs[i].relayToken = grant.irohID == nil ? nil : registry.relayToken(clientID: macID)
    }

    private func finishTranscript(_ replay: [ShellReplayChunk]?) {
        guard let pending = pendingTranscript else { return }
        pendingTranscript = nil
        pending.continuation.resume(returning: replay)
    }

    /// Ends the connection without touching tabs, so a later `connect` re-attaches.
    private func dropConnection() {
        generation += 1
        client?.disconnect()
        client = nil
        path = nil
        finishTranscript(nil)
    }

    private func resetSessions() {
        macState = nil
        pendingControl = nil
        controlError = nil
        sessions = []
        history = []
        historyLoaded = false
        openTabs = []
        activeSession = nil
        detachedSession = nil
        ended = ShellEndedSessions()
    }

    /// Dials again after `delay`, showing Reconnecting meanwhile; it
    /// re-attaches the session on screen once ready, as any connect does.
    /// Dropped if something else connects, locks or clears first.
    private func redial(after delay: TimeInterval) {
        reach = .connecting
        redialTask?.cancel()
        redialTask = Task { [weak self] in
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard !Task.isCancelled, let self, self.reach == .connecting, self.client == nil else { return }
            self.connect()
        }
    }

    /// No usable Mac right now: forget keys held in memory, stop dialing and
    /// browsing. While merely locked (or without a passcode) the selection and
    /// tabs stay, so the next unlock reconnects and re-attaches.
    private func clear(_ reach: Reach) {
        redialTask?.cancel()
        redialTask = nil
        redialsMade = nil
        dropConnection()
        // Browsing exposes nothing secret: keep it across relocks so results are ready on unlock.
        if reach == .noAccess { stopBrowsing() }
        applyingRefresh = true
        macs = []
        if reach == .noAccess {
            selectedMacID = nil
            clientMacID = nil
            resetSessions()
        }
        applyingRefresh = false
        self.reach = reach
    }

    private func startBrowsing() {
        guard browser == nil else { return }
        let browser = NWBrowser(for: .bonjour(type: RemoteShell.serviceType, domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let endpoints = results.map(\.endpoint)
            MainActor.assumeIsolated { self?.browseResultsChanged(endpoints) }
        }
        browser.stateUpdateHandler = { [weak self] state in
            guard case .failed = state else { return }
            MainActor.assumeIsolated {
                self?.browser = nil
                self?.browseResults = []
            }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    /// Re-dials when the selected Mac shows up on Bonjour and the current
    /// attempt didn't have it: still dialing addresses, or already failed.
    private func browseResultsChanged(_ endpoints: [NWEndpoint]) {
        browseResults = endpoints
        guard reach == .unreachable || reach == .connecting,
              let credential = macs.first(where: { $0.macID == selectedMacID }),
              let found = ShellCredentials.discovered(among: endpoints, macName: credential.macName, shellMacCount: macs.count),
              found != dialedDiscovered else { return }
        connect()
    }

    private func stopBrowsing() {
        browser?.cancel()
        browser = nil
        browseResults = []
    }
}

extension ShellError {
    /// Copy for a refusal worth telling the user about; nil for ones the UI
    /// shows another way (a refused key is `Reach.noAccess`).
    var message: String? {
        switch self {
        case .tooManySessions: "Your Mac already has \(RemoteShell.maxSessions) sessions open. End one to start another."
        case .noSuchSession: "That session is no longer open on your Mac."
        case .badRequest: "Your Mac couldn't do that. Try again."
        case .screenNotAllowed: "This iPhone isn't allowed to see your Mac's screen. Turn on Screen for it in Passthrough's Remote Shell settings on your Mac."
        // Asked for only after the Mac said it can't stream its screen itself.
        case .screenUnavailable: "Your Mac can't show its screen yet. In Passthrough's Remote Shell settings on your Mac, allow Screen Recording and Accessibility, or turn on Screen Sharing."
        case .screenVideoUnavailable: "Your Mac can't stream its screen itself yet. In Passthrough's Remote Shell settings on your Mac, allow Screen Recording and Accessibility."
        case .tooManyScreens: "Your Mac is already showing its screen as often as it allows (\(RemoteShell.maxScreenViewsPerPhone) views per phone, \(RemoteShell.maxScreenViews) in all). Close one to open another."
        case .notAllowed: "Your Mac doesn't let this iPhone change Keep awake and the VPN. Turn on Awake & VPN for it in Passthrough's Remote Shell settings on your Mac."
        case .vpnNotSetUp: "Your Mac has no VPN set up yet. Add one in Passthrough's VPN settings on the Mac."
        case .notAuthorized: nil
        }
    }
}

#if DEBUG
// MARK: - Demo data (DEBUG builds only)

/// Sample sessions and output for looking at the shell screens without a Mac:
/// launch a Debug build with `-PTDemoShell ready` (or `empty`, `connecting`,
/// `unreachable`, `keyUnavailable`). Compiled out of Release; without the
/// argument nothing here runs. No network, no Keychain.
extension ShellModel {
    static var demoState: String? { UserDefaults.standard.string(forKey: "PTDemoShell") }

    fileprivate static let demoOutput: Data = {
        let esc = "\u{1b}["
        let prompt = "\(esc)1;36mme\(esc)0m@\(esc)1;35mmacbook\(esc)0m \(esc)34m~/dev/passthrough\(esc)0m % "
        let lines = [
            prompt + "git status -sb",
            "## remote-shell...origin/remote-shell",
            " \(esc)31mM\(esc)0m iOS/App/Lock/LockOverlay.swift",
            " \(esc)31mM\(esc)0m iOS/App/Shell/RemoteShellCard.swift",
            prompt + "ls",
            "\(esc)1;34mPackages\(esc)0m  \(esc)1;34mandroid\(esc)0m  \(esc)1;34miOS\(esc)0m  \(esc)1;34mmacOS\(esc)0m  README.md  project.yml",
            prompt + "uptime",
            "11:52  up 3 days,  4:10, 2 users, load averages: 1.42 1.37 1.30",
            prompt,
        ]
        return Data(lines.joined(separator: "\r\n").utf8)
    }()

    fileprivate func applyDemo(_ state: String) {
        let now = Date().timeIntervalSince1970
        guard state != "noAccess" else { return clear(.noAccess) }
        applyingRefresh = true
        macs = [ShellCredential(macID: "demo-mac", macName: "My MacBook Pro", certSHA256: "", shellKey: Data(),
                                phoneID: "demo", port: 0, addresses: [])]
        selectedMacID = "demo-mac"
        applyingRefresh = false
        clientMacID = "demo-mac"
        switch state {
        case "connecting": reach = .connecting
        case "unreachable": reach = .unreachable
        case "keyUnavailable": reach = .keyUnavailable
        default:
            reach = .ready
            path = .relay
        }
        if state == "ready", macState == nil {
            macState = MacState(awake: true, battery: 0.64, charging: false, minutesLeft: 190, batteryFloor: 0.2, hot: false,
                                vpn: MacState.vpnOn, vpnName: "NordVPN Germany", killSwitch: true, control: true)
        }
        if state == "unreachable", macState == nil {
            macState = MacState(awake: false, awakeStopped: "battery", battery: 0.2, charging: false, batteryFloor: 0.2, control: true)
        }
        if state == "ready", sessions.isEmpty {
            sessions = [
                ShellSessionInfo(id: "demo-1", title: "zsh — ~/dev/passthrough", startedAt: now - 760, lastOutputAt: now - 20, running: true),
                ShellSessionInfo(id: "demo-2", title: "npm run build", startedAt: now - 5400, lastOutputAt: now - 3600, running: false, exitStatus: 0),
            ]
            ended.apply(sessions)
        }
        if state == "ready" || state == "empty" {
            history = [
                ShellHistoryEntry(id: "demo-1", title: "zsh — ~/dev/passthrough", phoneLabel: "iPhone", startedAt: now - 760, bytes: 18_000),
                ShellHistoryEntry(id: "demo-2", title: "npm run build", phoneLabel: "iPhone", startedAt: now - 5400, endedAt: now - 3600, exitStatus: 0, bytes: 92_000),
                ShellHistoryEntry(id: "demo-3", title: "top", phoneLabel: "Pixel 9", startedAt: now - 90_000, endedAt: now - 89_000, exitStatus: 130, bytes: 400_000),
                ShellHistoryEntry(id: "demo-4", title: "ssh build-box", phoneLabel: "iPhone", startedAt: now - 260_000, bytes: 3_000),
            ]
            historyLoaded = true
        }
    }

    fileprivate func demoControl(_ change: MacControl) {
        switch change {
        case .awake(let on): macState?.awake = on
        case .vpn(let on): macState?.vpn = on ? MacState.vpnOn : MacState.vpnOff
        }
    }

    fileprivate func demoOpen() {
        let id = "demo-\(sessions.count + 1)"
        sessions.append(ShellSessionInfo(id: id, title: "zsh — ~", startedAt: Date().timeIntervalSince1970,
                                         lastOutputAt: Date().timeIntervalSince1970, running: true))
        if !openTabs.contains(id) { openTabs.append(id) }
        streamStarting.send((id, false))
        activeSession = id
        output.send((id, Self.demoOutput))
    }

    fileprivate func demoReplay(_ id: String) {
        streamStarting.send((id, true))
        output.send((id, Self.demoOutput))
        replayFinished.send(id)
    }
}
#endif
