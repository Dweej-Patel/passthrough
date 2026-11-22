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

        /// What to tell the user about a Mac; `fromAnywhere` when this connect also tried iroh.
        /// The page for any kind uses `ShellModel.reachMessage`, which knows the computer.
        func message(fromAnywhere: Bool) -> String? {
            let w = HostWords(kind: .mac, name: nil, device: ThisDevice.name)
            switch self {
            case .needsPasscode: return HostCopy.needsPasscode(w)
            case .locked: return HostCopy.locked(w)
            case .keyUnavailable: return HostCopy.keyUnavailable(w)
            case .noAccess: return HostCopy.noAccess(w)
            case .unreachable: return HostCopy.unreachable(w, fromAnywhere: fromAnywhere)
            case .connecting, .ready: return nil
            }
        }
    }

    @Published var macs: [ShellCredential] = []
    /// Changed by the UI only through `select(_:)`.
    @Published private(set) var selectedMacID: String? {
        // The watch on the newly selected Mac ends before the live connection dials it.
        didSet { if selectedMacID != oldValue, !applyingRefresh { updateWatcher(); connect() } }
    }
    @Published private(set) var reach: Reach = .noAccess {
        didSet {
            // Unreachable, no access, locked…: nobody is waiting for that new session any more.
            if reach != .connecting && reach != .ready { openWhenReady = false }
            // For Try again beside a connect that runs long.
            if reach != .connecting { connectingSince = nil } else if oldValue != .connecting { connectingSince = Date() }
            // Remember when each Mac last answered, for "last heard" while it can't be reached.
            guard reach == .ready || oldValue == .ready, let mac = clientMacID else { return }
            Self.noteHeard(mac)
        }
    }
    @Published private(set) var sessions: [ShellSessionInfo] = []
    @Published private(set) var history: [ShellHistoryEntry] = []
    /// The Mac has answered a history request since this Mac was selected.
    @Published private(set) var historyLoaded = false
    @Published var openTabs: [String] = [] { didSet { rememberTabs() } }
    @Published var activeSession: String? { didSet { rememberTabs() } }
    /// Each Mac's open tabs and active tab, so switching back (or relaunching)
    /// brings them back; kept in step with `openTabs`/`activeSession`.
    private(set) var tabMemory: MacTabMemory
    /// Finished sessions removed from this phone, per Mac (the Mac keeps listing them for a while).
    @Published private(set) var hiddenSessions: ShellHiddenSessions
    /// The selected Mac's sessions minus the finished ones removed here.
    var visibleSessions: [ShellSessionInfo] {
        guard let mac = clientMacID ?? selectedMacID else { return sessions }
        return hiddenSessions.visible(sessions, on: mac)
    }
    /// Sessions that have ended: their tabs show a read-only log of their output.
    @Published private(set) var ended = ShellEndedSessions()
    /// The last thing the Mac refused (too many sessions, no such session…).
    @Published private(set) var lastError: ShellError?
    /// What each computer last said about itself (`host`), kept across launches in the app's own defaults.
    @Published private(set) var factsByMac: [String: HostInfo]
    /// The last `screenEnded` this connection heard: which computer, why, and when.
    private(set) var screenEnded: (macID: String, reason: String, at: Date)?
    /// Why each computer last said it was leaving (`goingAway`); dropped at its next `ready`.
    @Published private(set) var farewells: [String: HostFarewell]
    /// The shell last chosen per computer (a `HostShell.id`).
    private(set) var lastShell: [String: String]
    /// The selected computer refused this phone's key (`not_authorized`) while it held one.
    @Published private(set) var accessRefused = false
    /// How the last `open` was refused, when it says a shell can't start there (`signed_out`, `not_allowed`).
    @Published private(set) var shellRefusal: ShellError?
    /// When `reach` entered `.connecting`.
    @Published private(set) var connectingSince: Date?
    /// The session another connection took over while this phone showed it;
    /// cleared when this phone attaches or opens a session again.
    @Published private(set) var detachedSession: String?
    /// How the ready connection is carried, when known.
    @Published private(set) var path: ShellPath?
    /// The selected Mac's state as it last said (kept while it can't be
    /// reached, as "last known"); nil from a Mac too old to send it.
    @Published private(set) var macState: MacState?
    /// Keep awake and VPN changes sent and not yet answered, per switch.
    @Published private(set) var pendingControls: [MacSwitch: PendingControl] = [:]
    /// Changes that didn't take, per switch: the Mac answered without making
    /// it, or never answered. Cleared once the switch gets there, or on the next try.
    @Published private(set) var controlMisses: [MacSwitch: ControlMiss] = [:]
    /// Why the Mac refused the last Keep awake or VPN change.
    @Published private(set) var controlError: ShellError?
    /// The last Keep awake or VPN change wasn't sent: the Mac wasn't connected.
    @Published private(set) var controlUnsent = false
    /// What happened on the selected Mac, as of the last `loadTimeline`.
    @Published private(set) var timeline: MacTimeline?
    @Published private(set) var timelineLoading = false
    /// The Mac answered `events` with `bad_request`: it keeps no log yet.
    @Published private(set) var timelineUnsupported = false
    /// "Connect using": this device's choice, kept in the app's own defaults.
    @Published var connectMode: ShellConnectMode {
        didSet {
            guard connectMode != oldValue else { return }
            UserDefaults.standard.set(connectMode.rawValue, forKey: Self.connectModeKey)
            updateWatcher()
            if !macs.isEmpty { connect() }
        }
    }
    /// The other paired Macs' sessions and state, while the app is in the foreground.
    let watcher = MacWatcher()
    /// Macs watched whatever the cap (the Live Activity's Mac).
    private var watchPinned: Set<String> = []
    /// Watches the Live Activity's Mac whatever the cap (nil: none).
    func pinWatch(_ macID: String?) {
        let pinned = macID.map { Set([$0]) } ?? []
        guard pinned != watchPinned else { return }
        watchPinned = pinned
        updateWatcher()
    }
    /// Output for `(session, bytes)`, for the terminal views.
    let output = PassthroughSubject<(String, Data), Never>()
    /// A session's output is about to start over: sent before an attach request
    /// (`replay` true: its scrollback comes first) and when a session was just
    /// opened, so a terminal can clear first.
    let streamStarting = PassthroughSubject<(session: String, replay: Bool), Never>()
    /// The Mac's replay for an attach begins: output since the request was not part of it.
    let replayStarting = PassthroughSubject<String, Never>()
    /// The scrollback replay of an attach is complete; later output is live.
    let replayFinished = PassthroughSubject<String, Never>()

    private static let manualAddressPrefix = "shell.manualAddress."
    private static let connectModeKey = "shell.connectMode"
    private static let tabMemoryKey = "shell.tabMemory"
    private static let lastMacKey = "shell.lastMac"
    private static let hiddenSessionsKey = "shell.hiddenSessions"
    private static let hostFactsKey = "shell.hostFacts"
    private static let farewellsKey = "shell.farewells"
    private static let lastShellKey = "shell.lastShell"
    /// When each Mac was last selected (seconds since 1970), for which Macs to watch.
    private static let lastSelectedKey = "shell.lastSelectedAt"

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
    /// Set while tabs are cleared or restored for a Mac change: those aren't
    /// changes the user made to the Mac whose tabs are showing.
    private var holdingTabMemory = false
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
    /// Which Macs granted the shell and whose key needed authentication, as of the last
    /// refresh; read when `connect` selects a Mac without a usable credential.
    private var keyFacts = ShellKeyFacts()
    /// Every paired Mac (with or without the shell), as of the last refresh: the
    /// selection stays on any of them, and the header names it.
    private var paired: [PairedClient] = []
    private var size = (cols: 80, rows: 24)
    /// A new session asked for while connecting (or waiting to redial):
    /// opened on `.ready`. Dropped once the Mac can't be reached, or for
    /// another Mac or a tab chosen meanwhile.
    private var openWhenReady = false
    /// The shell that session asked for (nil: the host's default).
    private var openShellWhenReady: String?
    /// That open was sent instead of re-attaching `activeSession`: until
    /// it's answered nothing is attached, and if it's refused the active tab
    /// is re-attached.
    private var reattachIfRefused = false
    private var browser: NWBrowser?
    private var browseResults: [NWEndpoint] = []
    /// The transcript request in flight; `token` tells it from a later request for the same session.
    private var pendingTranscript: (id: String, token: UUID, replay: ShellReplay.Collector,
                                    continuation: CheckedContinuation<[ShellReplayChunk]?, Never>)?
    private var observers: [NSObjectProtocol] = []
    private var watcherChanges: AnyCancellable?
    /// Notices turned on or off, or a new device token: the Mac connected now hears.
    private var pushChanges: AnyCancellable?
    /// What each Mac switched away from had said ended, in memory only: a remembered finished
    /// tab can still be removed after switching back while that Mac is out of reach.
    private var endedByMac: [String: ShellEndedSessions] = [:]

    init() {
        connectMode = UserDefaults.standard.string(forKey: Self.connectModeKey).flatMap(ShellConnectMode.init(rawValue:)) ?? .automatic
        tabMemory = UserDefaults.standard.data(forKey: Self.tabMemoryKey)
            .flatMap { try? JSONDecoder().decode(MacTabMemory.self, from: $0) } ?? MacTabMemory()
        hiddenSessions = UserDefaults.standard.data(forKey: Self.hiddenSessionsKey)
            .flatMap { try? JSONDecoder().decode(ShellHiddenSessions.self, from: $0) } ?? ShellHiddenSessions()
        // Kept cleaned (`HostInfo.cleaned`), so what comes back is what was shown.
        factsByMac = (UserDefaults.standard.data(forKey: Self.hostFactsKey)
            .flatMap { try? JSONDecoder().decode([String: HostInfo].self, from: $0) } ?? [:]).compactMapValues { $0.cleaned() }
        farewells = UserDefaults.standard.data(forKey: Self.farewellsKey)
            .flatMap { try? JSONDecoder().decode([String: HostFarewell].self, from: $0) } ?? [:]
        lastShell = UserDefaults.standard.dictionary(forKey: Self.lastShellKey) as? [String: String] ?? [:]
        // Sockets don't survive suspension; leave cleanly, and `refresh` on return reconnects.
        observers.append(NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.dropConnection()
                self?.watcher.stop()
            }
        })
        // The foreground refresh runs while the app still counts as in the background,
        // when `updateWatcher` stops watches: start them once it is active.
        observers.append(NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateWatcher() }
        })
        // Notices turned on or off, or a new device token: the Mac connected now hears.
        // `@Published` fires before the change lands: read it on the next turn.
        pushChanges = PushRegistrar.shared.$token.combineLatest(PushRegistrar.shared.$enabled, PushRegistrar.shared.$denied)
            .dropFirst()
            .sink { [weak self] _ in DispatchQueue.main.async { self?.sendPushRegistration() } }
        watcher.hiddenSessions = { [weak self] in self?.hiddenSessions ?? ShellHiddenSessions() }
        watcher.discovered = { [weak self] credential in
            guard let self else { return nil }
            return ShellCredentials.discovered(among: self.browseResults, macName: credential.macName, shellMacCount: self.macs.count)
        }
        watcher.recency = { MacProfiles.recency(lastHeard: Self.lastHeardStore, lastSelected: Self.lastSelectedStore) }
        // Views watch this model: pass on what the watched Macs say.
        watcherChanges = watcher.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
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
        paired = clients
        let pairedIDs = clients.map(\.id)
        guard lock.isUnlocked else { return clear(granting.isEmpty ? .noAccess : .locked, paired: pairedIDs) }
        guard ShellKeyVault.passcodeSet else { return clear(granting.isEmpty ? .noAccess : .needsPasscode, paired: pairedIDs) }

        // Read at call time: the lock replaces its context on every relock.
        let context = lock.context
        ShellKeyVault.adoptPending(from: registry, context: context)
        ShellKeyVault.prune(keeping: Set(clients.map(\.id)), context: context)
        var memory = tabMemory
        memory.keepOnly(Set(clients.map(\.id)))
        if memory != tabMemory { tabMemory = memory; saveTabMemory() }
        forgetUnpaired(keeping: Set(pairedIDs))
        var locked: Set<String> = []
        let built = ShellCredentials.build(clients: granting, phoneID: registry.phoneID, key: { id in
            switch ShellKeyVault.read(macID: id, context: context) {
            case let .key(data): return data
            case .locked: locked.insert(id); return nil
            case .missing: return nil
            }
        }, manualAddress: manualAddress(for:), relayToken: { registry.relayToken(clientID: $0) })
        let facts = ShellKeyFacts(granting: Set(granting.map(\.id)), locked: locked)
        if !locked.isEmpty {
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
        keyFacts = facts

        let previous = macs.first { $0.macID == clientMacID }
        applyingRefresh = true
        macs = built
        // A paired Mac stays selected even without a shell credential (internet only).
        selectedMacID = MacProfiles.selection(current: selectedMacID, lastUsed: UserDefaults.standard.string(forKey: Self.lastMacKey),
                                              paired: pairedIDs, withShell: built.map(\.macID))
        applyingRefresh = false

        guard let current = built.first(where: { $0.macID == selectedMacID }) else {
            // A Mac granted access but its key isn't here: plugging in renews it.
            guard let mac = selectedMacID else { return clear(facts.keyUnavailable(for: nil) ? .keyUnavailable : .noAccess) }
            // Before leaving the live connection: the other Macs' watches follow the selection.
            startBrowsing()
            updateWatcher()
            return idleOnMacWithoutShell(facts.keyUnavailable(for: mac) ? .keyUnavailable : .noAccess)
        }
        startBrowsing()
        updateWatcher()
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

    /// What the page says about reaching the selected computer, in its words.
    var reachMessage: String? {
        // A Mac reads exactly as it always has.
        if selectedKind == .mac { return reach.message(fromAnywhere: clientTriesIroh) }
        let w = words
        switch reach {
        case .connecting, .ready: return nil
        case .unreachable:
            return HostCopy.state(page.state, w, fromAnywhere: clientTriesIroh,
                                  lastHeard: lastHeard?.formatted(date: .omitted, time: .shortened),
                                  at: { $0.formatted(date: .omitted, time: .shortened) },
                                  sleepsAfter: hostFacts?.sleepAfter.flatMap(Self.sleepsAfter))
        case .noAccess: return accessRefused ? HostCopy.revoked(w) : HostCopy.noAccess(w)
        case .locked: return HostCopy.locked(w)
        case .needsPasscode: return HostCopy.needsPasscode(w)
        case .keyUnavailable: return HostCopy.keyUnavailable(w)
        }
    }

    /// What to check while it can't be reached, for a page that already says so and when it was last heard.
    var unreachableAdvice: String? { HostCopy.unreachableAdvice(words, fromAnywhere: clientTriesIroh) }

    /// "30 minutes" for a `sleepAfter` in seconds; nil for never.
    private static func sleepsAfter(_ seconds: Int) -> String? {
        guard seconds > 0 else { return nil }
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .full
        formatter.allowedUnits = seconds >= 3600 ? [.hour, .minute] : [.minute]
        return formatter.string(from: TimeInterval(seconds))
    }

    // MARK: What kind of computer

    /// What the selected computer last said about itself.
    var hostFacts: HostInfo? { selectedMacID.flatMap { factsByMac[$0] } }
    /// Why the selected computer said it was leaving, if it did since it last answered.
    var farewell: HostFarewell? { selectedMacID.flatMap { farewells[$0] } }

    /// What kind of computer `id` is: what it last said, else what it said when paired or granted, else a Mac.
    func kind(of id: String?) -> HostKind {
        guard let id else { return .mac }
        return Hosts.kind(live: factsByMac[id], stored: paired.first { $0.id == id }?.hostKind ?? macs.first { $0.macID == id }?.hostKind)
    }

    var selectedKind: HostKind { kind(of: selectedMacID) }
    /// The selected computer's nouns.
    var words: HostWords { HostWords(kind: selectedKind, name: selectedMacName, device: ThisDevice.name) }
    /// Some paired computer isn't a Mac: lists then say which each is.
    var mixedKinds: Bool { paired.contains { kind(of: $0.id) != .mac } }

    /// The shells `id` offers, as it last said.
    func shells(for id: String?) -> [HostShell] { id.flatMap { factsByMac[$0]?.shells } ?? [] }

    /// The shell New shell opens on `id`: the last one chosen there if it still lists it, else its default.
    func preferredShell(for id: String?) -> HostShell? {
        guard let id, let facts = factsByMac[id] else { return nil }
        return facts.shells?.first { $0.id == lastShell[id] } ?? facts.defaultShell
    }

    /// The selected computer's page: state, shell, Screen row, Try again.
    var page: HostPage {
        let hostReach: HostReach
        switch reach {
        case .noAccess: hostReach = .noAccess
        case .locked: hostReach = .locked
        case .needsPasscode: hostReach = .needsPasscode
        case .keyUnavailable: hostReach = .keyUnavailable
        case .connecting: hostReach = .connecting(redialing: isRedialing)
        case .unreachable: hostReach = .unreachable
        case .ready: hostReach = .ready(path)
        }
        return HostPage.make(HostPageInput(kind: selectedKind, reach: hostReach, accessRefused: accessRefused, host: hostFacts,
                                           farewell: farewell, connectingSince: connectingSince, triedFromAnywhere: clientTriesIroh,
                                           shellRefusal: shellRefusal, viewerScreens: viewerScreens))
    }

    /// The screens this app shows for the selected computer: a PC's Remote Desktop only behind the developer switch.
    private var viewerScreens: Set<String> {
        selectedKind == .windows && PCScreen.isOn ? [HostInfo.screenRDP] : ScreenBackends.supported(for: selectedKind)
    }

    /// The one way into the screen: the selected computer is reachable and this app can show its screen.
    /// For a PC only behind the developer switch (`PCScreen`), and then never by the Mac's Screen Sharing path.
    var canOpenScreen: Bool {
        reach == .ready && (selectedKind == .mac || (selectedKind == .windows && PCScreen.isOn)) && page.screen == .available
    }

    private func saveHostFacts() {
        UserDefaults.standard.set(try? JSONEncoder().encode(factsByMac), forKey: Self.hostFactsKey)
    }

    private func saveFarewells() {
        UserDefaults.standard.set(try? JSONEncoder().encode(farewells), forKey: Self.farewellsKey)
    }

    /// Forgets what's kept about what a computer is: for `id`, or for all but `keeping`.
    private func forgetHostFacts(_ id: String? = nil, keeping: Set<String>? = nil) {
        let keep: (String) -> Bool = { key in keeping.map { $0.contains(key) } ?? (key != id) }
        if factsByMac.keys.contains(where: { !keep($0) }) { factsByMac = factsByMac.filter { keep($0.key) }; saveHostFacts() }
        if farewells.keys.contains(where: { !keep($0) }) { farewells = farewells.filter { keep($0.key) }; saveFarewells() }
        if lastShell.keys.contains(where: { !keep($0) }) {
            lastShell = lastShell.filter { keep($0.key) }
            UserDefaults.standard.set(lastShell, forKey: Self.lastShellKey)
        }
    }

    /// The selected Mac's shell grant, if it has one.
    var selectedMac: ShellCredential? { macs.first { $0.macID == selectedMacID } }

    /// The Mac on screen: the selected Mac (with or without the shell), else the first paired one.
    var selectedMacName: String {
        selectedMac?.macName ?? (paired.first { $0.id == selectedMacID } ?? paired.first)?.name
            ?? HostWords(kind: selectedKind, name: nil, device: ThisDevice.name).Your
    }

    /// The selected Mac's shell can be reached off its own network (iroh).
    var selectedReachesFromAnywhere: Bool { selectedMac?.irohID != nil }

    func isPending(_ change: MacSwitch) -> Bool { pendingControls[change] != nil }

    /// Why the last Keep awake or VPN change didn't happen, if it didn't.
    var controlMessage: String? {
        controlError?.message ?? (controlUnsent ? "Your Mac isn't connected right now, so nothing changed. Try again once it shows as reachable." : nil)
    }

    /// When the selected Mac last answered, if it ever has on this phone.
    var lastHeard: Date? {
        guard let mac = selectedMacID, let at = Self.lastHeardStore[mac] else { return nil }
        return Date(timeIntervalSince1970: at)
    }

    private static let lastHeardKey = "PTShellLastHeard"
    /// When each Mac last answered (seconds since 1970), on the live connection or a watch.
    static var lastHeardStore: [String: Double] {
        UserDefaults.standard.dictionary(forKey: lastHeardKey) as? [String: Double] ?? [:]
    }

    static func noteHeard(_ macID: String, at date: Date = Date()) {
        var heard = lastHeardStore
        heard[macID] = date.timeIntervalSince1970
        UserDefaults.standard.set(heard, forKey: lastHeardKey)
    }

    private static var lastSelectedStore: [String: Double] {
        UserDefaults.standard.dictionary(forKey: lastSelectedKey) as? [String: Double] ?? [:]
    }

    /// What a Mac's row in the switcher says: the selected Mac from the live
    /// connection, the others from their watch (or when last heard).
    func status(for macID: String) -> MacStatus {
        let hasShell = macs.contains { $0.macID == macID }
        if macID == selectedMacID {
            return MacProfiles.status(sessions: visibleSessions, reachable: reach == .ready, lastHeard: lastHeard, hasShell: hasShell)
        }
        let seen = watcher.seen[macID]
        let heard = seen?.lastHeard ?? Self.lastHeardStore[macID].map(Date.init(timeIntervalSince1970:))
        return MacProfiles.status(sessions: seen?.sessions, reachable: seen?.reachable ?? false, lastHeard: heard, hasShell: hasShell)
    }

    /// A session on a Mac other than the selected one is waiting on a question.
    var otherMacNeedsYou: Bool {
        macs.contains { mac in
            guard mac.macID != selectedMacID, case .asking = status(for: mac.macID) else { return false }
            return true
        }
    }

    /// Starts or ends watches to match the paired Macs and the selection.
    /// Not while in the background: watches are foreground only.
    private func updateWatcher() {
        #if DEBUG
        if Self.demoState != nil { return applyDemoWatch() }
        #endif
        guard UIApplication.shared.applicationState != .background, lock?.isUnlocked == true else { return watcher.stop() }
        watcher.update(credentials: macs, selected: selectedMacID, pinned: watchPinned, connectMode: connectMode)
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

    /// Makes `macID` the selected Mac: the only way the UI switches. The tabs
    /// showing are kept for the Mac being left (nothing is sent to it), and
    /// the new Mac's own tabs come back once `connect` dials it.
    func select(_ macID: String) {
        guard macID != selectedMacID else { return }
        if let current = clientMacID { tabMemory.save(MacTabs(openTabs: openTabs, active: activeSession), for: current) }
        saveTabMemory()
        UserDefaults.standard.set(macID, forKey: Self.lastMacKey)
        var selectedAt = Self.lastSelectedStore
        selectedAt[macID] = Date().timeIntervalSince1970
        UserDefaults.standard.set(selectedAt, forKey: Self.lastSelectedKey)
        selectedMacID = macID
    }

    /// The phone forgot this Mac: drop its key, address, tabs and any connection to it.
    func forget(macID: String) {
        ShellKeyVault.delete(macID: macID, context: lock?.isUnlocked == true ? lock?.context : nil)
        // Its screen logins too: a computer paired later under the same id is never signed in with them.
        ScreenLoginStore.deleteAll(hostID: macID)
        UserDefaults.standard.removeObject(forKey: Self.manualAddressPrefix + macID)
        granted[macID] = nil
        if clientMacID == macID { dropConnection(); resetSessions() }
        applyingRefresh = true
        macs.removeAll { $0.macID == macID }
        let stillPaired = paired.map(\.id).filter { $0 != macID }
        if selectedMacID == macID {
            // The last used Mac, else one with the shell, else any paired one (internet only).
            let lastUsed = UserDefaults.standard.string(forKey: Self.lastMacKey)
            selectedMacID = MacProfiles.selection(current: nil, lastUsed: lastUsed == macID ? nil : lastUsed,
                                                  paired: stillPaired, withShell: macs.map(\.macID))
        }
        applyingRefresh = false
        if macs.isEmpty { clear(.noAccess, paired: stillPaired) } else {
            // Before dialling: the new selection's watch (if any) ends first.
            updateWatcher()
            if client == nil { connect() }
        }
        var heard = Self.lastHeardStore
        heard[macID] = nil
        UserDefaults.standard.set(heard, forKey: Self.lastHeardKey)
        var selectedAt = Self.lastSelectedStore
        selectedAt[macID] = nil
        UserDefaults.standard.set(selectedAt, forKey: Self.lastSelectedKey)
        tabMemory.forget(macID)
        saveTabMemory()
        hiddenSessions.forget(macID)
        saveHiddenSessions()
        endedByMac[macID] = nil
        forgetHostFacts(macID)
        if UserDefaults.standard.string(forKey: Self.lastMacKey) == macID {
            UserDefaults.standard.removeObject(forKey: Self.lastMacKey)
        }
    }

    func forgetAll() {
        ShellKeyVault.deleteAll()
        for id in Set(macs.map(\.macID) + granted.keys + paired.map(\.id)) { ScreenLoginStore.deleteAll(hostID: id) }
        for id in macs.map(\.macID) + granted.keys {
            UserDefaults.standard.removeObject(forKey: Self.manualAddressPrefix + id)
        }
        granted = [:]
        clear(.noAccess)
        UserDefaults.standard.removeObject(forKey: Self.lastHeardKey)
        UserDefaults.standard.removeObject(forKey: Self.lastSelectedKey)
        tabMemory = MacTabMemory()
        UserDefaults.standard.removeObject(forKey: Self.tabMemoryKey)
        UserDefaults.standard.removeObject(forKey: Self.lastMacKey)
        hiddenSessions = ShellHiddenSessions()
        UserDefaults.standard.removeObject(forKey: Self.hiddenSessionsKey)
        forgetHostFacts(keeping: [])
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
            // A paired Mac without a usable credential: nothing of the Mac left shows, and the
            // same per-Mac key facts the last refresh used say why. Not while locked: unlocking refreshes.
            if let mac = selectedMacID, reach != .locked, reach != .needsPasscode {
                return idleOnMacWithoutShell(keyFacts.keyUnavailable(for: mac) ? .keyUnavailable : .noAccess)
            }
            if macs.isEmpty, reach != .locked, reach != .needsPasscode { reach = .noAccess }
            return
        }
        if clientMacID != credential.macID { switchSessions(to: credential.macID) }
        generation += 1
        let gen = generation
        clientTriesIroh = connectMode == .automatic && credential.irohID.map(IrohInfo.isValidID) == true
        // A fresh iroh endpoint (ephemeral key) per connect; the client shuts it down.
        let client = ShellClient(credential: credential, queue: .main, iroh: clientTriesIroh ? IrohShellDialer() : nil,
                                 mode: connectMode) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event, generation: gen) }
        }
        self.client = client
        lastError = nil
        // Before the new Mac's ID: a drop from `.ready` is "last heard" for the old one.
        reach = .connecting
        clientMacID = credential.macID
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

    /// A connection of its own to any Mac with a shell credential (not only the
    /// selected one), for a one-off request such as a screen pass. The caller
    /// disconnects it and shuts the dialer down when done.
    func oneOffConnection(to credential: ShellCredential, onEvent: @escaping (ShellClient.Event) -> Void) -> (client: ShellClient, dialer: IrohShellDialer?) {
        let triesIroh = connectMode == .automatic && credential.irohID.map(IrohInfo.isValidID) == true
        let dialer = triesIroh ? IrohShellDialer() : nil
        let client = ShellClient(credential: credential, queue: .main, iroh: dialer, mode: connectMode, onEvent: onEvent)
        client.connect(discovered: ShellCredentials.discovered(among: browseResults, macName: credential.macName, shellMacCount: macs.count))
        return (client, dialer)
    }

    /// Opens a session on the selected computer. `shell`: one of the shells it listed
    /// (anything else is dropped, so the host's default opens); remembered as its last choice.
    func newSession(cols: Int, rows: Int, shell: String? = nil) {
        let target = clientMacID ?? selectedMacID
        let listed = shells(for: target)
        let chosen = shell.flatMap { id in listed.contains(where: { $0.id == id }) ? id : nil }
        if let chosen, let target {
            lastShell[target] = chosen
            UserDefaults.standard.set(lastShell, forKey: Self.lastShellKey)
        }
        #if DEBUG
        if Self.demoState != nil { return demoOpen() }
        #endif
        size = (cols, rows)
        lastError = nil
        shellRefusal = nil
        guard reach == .ready, let client else {
            if reach == .connecting { openWhenReady = true; openShellWhenReady = chosen }
            return
        }
        client.open(cols: cols, rows: rows, shell: chosen)
    }

    func attach(_ id: String, cols: Int, rows: Int) {
        size = (cols, rows)
        openWhenReady = false
        reattachIfRefused = false
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

    /// Whether the Mac connected now will send this phone notices (nil: not asked yet).
    @Published private(set) var macSendsNotices: Bool?

    /// Tells the Mac connected now what this phone wants: notices sealed with
    /// that Mac's key, or none. Sent on every connection and whenever it changes.
    func sendPushRegistration() {
        guard reach == .ready, let client, let mac = clientMacID else { return }
        let registration = PushRegistrar.shared.registration(for: mac)
        if registration == nil, !PushRegistrar.shared.enabled { macSendsNotices = nil }
        client.setPush(registration)
    }

    /// The terminal screen is up: what the attached session shows is being
    /// looked at, so a result it reports (Claude Code's "done") is seen.
    /// Said again on each connection. Counted: a screen being replaced can
    /// appear before the one it replaces disappears.
    private var terminalScreens = 0
    var viewing: Bool { terminalScreens > 0 }
    func setViewing(_ on: Bool) {
        let was = viewing
        terminalScreens = max(0, terminalScreens + (on ? 1 : -1))
        if viewing != was { client?.setViewing(viewing) }
    }

    /// Ends a running session. A finished one is removed instead (`remove`):
    /// its tab closes and it's hidden on this phone, since the Mac would refuse to close it again.
    func close(_ id: String) {
        if hiddenSessions.canRemove(id, ended: ended, sessions: sessions) { return remove(id) }
        client?.close(id)
        ended.forget(id)
        openTabs.removeAll { $0 == id }
        if activeSession == id { activeSession = nil }
    }

    /// Removes a finished session from this phone: hides it for this Mac and
    /// drops its tab. Never sends `close` (the Mac ignores it for a session
    /// that has ended), so it works while the Mac is out of reach.
    func remove(_ id: String) {
        guard hiddenSessions.canRemove(id, ended: ended, sessions: sessions) else { return }
        if let mac = clientMacID ?? selectedMacID {
            hiddenSessions.hide(id, on: mac)
            saveHiddenSessions()
        }
        ended.forget(id)
        openTabs.removeAll { $0 == id }
        if activeSession == id { activeSession = nil }
    }

    private func saveHiddenSessions() {
        guard let data = try? JSONEncoder().encode(hiddenSessions) else { return }
        UserDefaults.standard.set(data, forKey: Self.hiddenSessionsKey)
    }

    func loadHistory() { client?.requestHistory() }

    /// Asks the Mac what happened since `since`; `timeline` follows.
    func loadTimeline(since: Date) {
        #if DEBUG
        if Self.demoState != nil { return demoTimeline(since: since) }
        #endif
        guard reach == .ready, let client else { return timelineLoading = false }
        timelineLoading = true
        client.requestEvents(since: since)
    }

    /// Asks the Mac to turn Keep awake or its VPN on or off; `macState` follows
    /// (the Mac answers every accepted change). Not connected: says so in
    /// `controlMessage`. The caller has already asked for Face ID before turning the VPN off.
    func control(_ change: MacControl) {
        controlError = nil
        controlUnsent = false
        #if DEBUG
        if Self.demoState != nil { return demoControl(change) }
        #endif
        let (key, on) = change.parts
        controlMisses[key] = nil
        guard reach == .ready, let client else { return controlUnsent = true }
        let sent = Date()
        pendingControls[key] = PendingControl(on: on, sent: sent)
        switch change {
        case .awake(let on): client.setAwake(on)
        case .vpn(let on): client.setVPN(on)
        case .lock: client.lockMac()
        }
        // An answer that never comes (a dropped reply, an older Mac) doesn't spin forever.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.controlTimeout))
            guard let self, self.pendingControls[key]?.sent == sent else { return }
            self.pendingControls[key] = nil
            self.controlMisses[key] = ControlMiss(on: on, answered: false)
        }
    }

    /// How long a change waits for the Mac before the switch stops spinning.
    static let controlTimeout: TimeInterval = 8
    /// The Mac answers an accepted change about a second later; a `macState`
    /// this long after sending is that answer, whatever it says.
    static let controlAnswerAfter: TimeInterval = 0.8

    /// Ends the waits this state answers: the switch got there, or it's the
    /// Mac's reply without it (a refusal, kept as a miss).
    private func settlePending(_ state: MacState) {
        let now = Date()
        for (key, miss) in controlMisses where Self.reached(key, on: miss.on, in: state) { controlMisses[key] = nil }
        for (key, pending) in pendingControls {
            let reached = Self.reached(key, on: pending.on, in: state)
            if reached {
                pendingControls[key] = nil
            } else if now.timeIntervalSince(pending.sent) >= Self.controlAnswerAfter {
                pendingControls[key] = nil
                controlMisses[key] = ControlMiss(on: pending.on, answered: true)
            }
        }
        if state.control == true, controlError == .notAllowed { controlError = nil }
        if state.vpn != nil, controlError == .vpnNotSetUp { controlError = nil }
    }

    private static func reached(_ key: MacSwitch, on: Bool, in state: MacState) -> Bool {
        switch key {
        case .awake: (state.awake == true) == on
        case .vpn: on ? state.vpnUp : state.vpn == MacState.vpnOff
        case .lock: (state.locked == true) == on
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
            controlUnsent = false
            self.path = path
            // No `list`: the Mac sends `sessions` right after `ready`.
            // An ended session's log is already on screen; it has nothing more to send.
            let active = activeSession.flatMap { ended.isEnded($0) ? nil : $0 }
            if let mac = clientMacID {
                accessRefused = false
                if farewells[mac] != nil { farewells[mac] = nil; saveFarewells() }
            }
            if openWhenReady {
                // Not the active tab first: it would take the keystrokes
                // meant for the new one until the Mac answers.
                openWhenReady = false
                reattachIfRefused = active != nil
                client?.open(cols: size.cols, rows: size.rows, shell: openShellWhenReady)
                openShellWhenReady = nil
            } else if let active, viewing {
                // Only while a terminal is on screen: attaching takes the
                // session over and the Mac sizes it to this phone, so doing
                // it from the home screen would resize a shell someone is
                // using on the Mac. The terminal attaches when it opens.
                reattachIfRefused = false
                streamStarting.send((active, true))
                client?.attach(active, cols: size.cols, rows: size.rows)
            }
            if viewing { client?.setViewing(true) }
            sendPushRegistration()
        case let .macInfo(info):
            apply(info)
        case let .macState(state):
            macState = state
            settlePending(state)
        case let .pushState(on):
            macSendsNotices = on
        case let .events(since, events, battery):
            timeline = MacTimeline(since: Date(timeIntervalSince1970: since), events: events, battery: battery, loadedAt: .now)
            timelineLoading = false
            timelineUnsupported = false
        case let .sessions(list):
            sessions = list
            let ids = Set(list.map(\.id))
            if let mac = clientMacID ?? selectedMacID {
                var hidden = hiddenSessions
                hidden.apply(listed: Array(ids), on: mac)
                if hidden != hiddenSessions { hiddenSessions = hidden; saveHiddenSessions() }
            }
            // The ended session on screen keeps its tab (and log) until the user closes it.
            let kept = activeSession.flatMap { ended.isEnded($0) ? $0 : nil }
            ended.apply(list, keeping: Set([kept].compactMap { $0 }))
            openTabs.removeAll { !ids.contains($0) && $0 != kept }
            if let active = activeSession, !ids.contains(active), active != kept { activeSession = nil }
            if let detached = detachedSession, !ids.contains(detached) { detachedSession = nil }
        case let .opened(id):
            if !openTabs.contains(id) { openTabs.append(id) }
            reattachIfRefused = false
            streamStarting.send((id, false))
            activeSession = id
            detachedSession = nil
            lastError = nil
            client?.list()
        case let .openedDetached(id):
            // The user went to another tab before the Mac answered: the new
            // one waits beside it, and the tab on screen stays.
            if !openTabs.contains(id) { openTabs.append(id) }
        case let .openFailed(error):
            // Unless another open is coming: re-attaching would overtake it.
            if reattachIfRefused, client?.openPending == false, let active = activeSession {
                reattachIfRefused = false
                attach(active, cols: size.cols, rows: size.rows)
            }
            lastError = error
            if error == .signedOut || error == .notAllowed { shellRefusal = error }
        case let .output(session, data):
            output.send((session, data))
        case let .replaying(session):
            replayStarting.send(session)
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
        case .failed(.badRequest, nil) where timelineLoading:
            timelineLoading = false
            timelineUnsupported = true
        case let .failed(error, _) where error == .notAllowed || error == .vpnNotSetUp:
            if error == .notAllowed { pendingControls = [:] } else { pendingControls[.vpn] = nil }
            controlMisses = [:]
            controlError = error
        case let .failed(error, session):
            lastError = error
            if error == .notAuthorized { accessRefused = true; reach = .noAccess }
            // Only a failure naming the requested session ends that request.
            // `signedOut`: a PC whose shells can't run answers `transcript` with it (older apps read it as `badRequest`).
            if error == .noSuchSession || error == .badRequest || error == .signedOut, let session, session == pendingTranscript?.id { finishTranscript(nil) }
        case let .disconnected(error):
            let dropped = reach == .ready
            client = nil
            reattachIfRefused = false
            path = nil
            pendingControls = [:]
            controlMisses = [:]
            timelineLoading = false
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
        case let .screen(stream, _), let .rdp(stream, _, _):
            // The screen has its own client (`ScreenModel`); this one never asks.
            stream.cancel()
        case .rdpRefused:
            break
        case let .screenEnded(reason):
            // Why a PC's screen view ended, for the view whose relay just closed (`ScreenModel`).
            guard let mac = clientMacID else { return }
            screenEnded = (mac, reason, Date())
        case .screenGranted, .screenPassSaved, .screenRevoked, .computerGranted, .computerPassSaved, .computerRevoked, .computerList:
            // Screen passes and computers' access have their own clients (`ScreenShareModel`, `ComputerShareModel`); this one never asks.
            break
        case let .host(info):
            guard let mac = clientMacID else { return }
            if factsByMac[mac] != info { factsByMac[mac] = info; saveHostFacts() }
            registry?.noteHostKind(clientID: mac, kind: info.kind)
            // It says shells can start again: the last refusal no longer holds.
            if info.signedIn != false, info.app != false, info.access?.shell != false { shellRefusal = nil }
        case let .goingAway(reason):
            guard let mac = clientMacID else { return }
            farewells[mac] = HostFarewell(reason: reason, at: Date())
            saveFarewells()
        }
    }

    // MARK: Private

    /// Keeps what the connected Mac says about reaching it (iroh details,
    /// addresses) with its grant, and uses it from the next connect. Never
    /// touches the shell key.
    private func apply(_ info: ShellEnvelope) {
        guard let macID = clientMacID else { return }
        applyMacInfo(info, for: macID)
    }

    /// Keeps what a Mac said about reaching it (`macInfo`, on any connection
    /// to it) with its grant, as `apply` does for the main connection.
    func applyMacInfo(_ info: ShellEnvelope, for macID: String) {
        guard let registry,
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
        reattachIfRefused = false
        path = nil
        pendingControls = [:]
        controlMisses = [:]
        timelineLoading = false
        finishTranscript(nil)
    }

    /// Another Mac's turn: clears what the last one said and brings back the
    /// new one's tabs, which `.ready` re-attaches as after any reconnect.
    private func switchSessions(to macID: String) {
        keepEnded()
        resetSessions()
        accessRefused = false
        ended = endedByMac[macID] ?? ShellEndedSessions()
        let tabs = tabMemory.tabs(for: macID)
        holdingTabMemory = true
        openTabs = tabs.openTabs
        activeSession = tabs.active
        holdingTabMemory = false
    }

    /// The selected Mac is paired but has no usable shell credential: internet only
    /// (`.noAccess`), or a grant whose key can't be read (`.keyUnavailable`). Nothing
    /// of the Mac left (sessions, tabs, state) shows, and no tabs are restored or
    /// saved for this one: `clientMacID` is nil, so the first connect with a
    /// credential brings back its remembered tabs. The Mac left's tabs were saved by `select`.
    private func idleOnMacWithoutShell(_ reach: Reach) {
        redialTask?.cancel()
        redialTask = nil
        redialsMade = nil
        dropConnection()
        keepEnded()
        resetSessions()
        lastError = nil
        // Before dropping the Mac's ID: a drop from `.ready` is "last heard" for the Mac left.
        self.reach = reach
        clientMacID = nil
    }

    /// Keeps the connected Mac's finished sessions before they're cleared, so a finished tab
    /// can still be removed after switching back while that Mac is out of reach. Every path
    /// that leaves a Mac (another shell Mac, an internet-only one, no access) goes through here.
    private func keepEnded() {
        if let left = clientMacID { endedByMac[left] = ended }
    }

    /// Keeps the tabs showing as the connected Mac's.
    private func rememberTabs() {
        guard !holdingTabMemory, let mac = clientMacID else { return }
        let tabs = MacTabs(openTabs: openTabs, active: activeSession)
        guard tabMemory.tabs(for: mac) != tabs else { return }
        tabMemory.save(tabs, for: mac)
        saveTabMemory()
    }

    /// Drops what's kept per Mac for Macs no longer paired (the Android app does the same).
    private func forgetUnpaired(keeping paired: Set<String>) {
        var hidden = hiddenSessions
        hidden.keepOnly(paired)
        if hidden != hiddenSessions { hiddenSessions = hidden; saveHiddenSessions() }
        endedByMac = endedByMac.filter { paired.contains($0.key) }
        forgetHostFacts(keeping: paired)
        let defaults = UserDefaults.standard
        if let last = defaults.string(forKey: Self.lastMacKey), !paired.contains(last) { defaults.removeObject(forKey: Self.lastMacKey) }
        let heard = Self.lastHeardStore
        if heard.keys.contains(where: { !paired.contains($0) }) { defaults.set(heard.filter { paired.contains($0.key) }, forKey: Self.lastHeardKey) }
        let selectedAt = Self.lastSelectedStore
        if selectedAt.keys.contains(where: { !paired.contains($0) }) { defaults.set(selectedAt.filter { paired.contains($0.key) }, forKey: Self.lastSelectedKey) }
    }

    private func saveTabMemory() {
        guard let data = try? JSONEncoder().encode(tabMemory) else { return }
        UserDefaults.standard.set(data, forKey: Self.tabMemoryKey)
    }

    /// Clears everything the connected Mac said, tabs included (its tabs stay
    /// in `tabMemory`).
    private func resetSessions() {
        holdingTabMemory = true
        defer { holdingTabMemory = false }
        openWhenReady = false
        openShellWhenReady = nil
        shellRefusal = nil
        macState = nil
        timeline = nil
        timelineLoading = false
        timelineUnsupported = false
        pendingControls = [:]
        controlMisses = [:]
        controlError = nil
        controlUnsent = false
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
    /// `paired`: the paired Macs, one of which stays selected on `.noAccess` (internet only, or no grant yet).
    private func clear(_ reach: Reach, paired: [String] = []) {
        redialTask?.cancel()
        redialTask = nil
        redialsMade = nil
        dropConnection()
        watcher.stop()
        keyFacts = ShellKeyFacts()
        // Browsing exposes nothing secret: keep it across relocks so results are ready on unlock.
        if reach == .noAccess { stopBrowsing() }
        applyingRefresh = true
        macs = []
        if reach == .noAccess {
            // A paired Mac (internet only, or no grant yet) stays selected; with none paired, nothing is.
            selectedMacID = MacProfiles.selection(current: selectedMacID, lastUsed: UserDefaults.standard.string(forKey: Self.lastMacKey),
                                                  paired: paired, withShell: [])
            keepEnded()
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
    /// Copy for a refusal worth telling the user about, worded for a Mac; nil for
    /// ones the UI shows another way (a refused key is `Reach.noAccess`).
    var message: String? { message(for: HostWords(kind: .mac, name: nil, device: ThisDevice.name)) }

    /// The same, in the words of the computer that refused.
    func message(for w: HostWords) -> String? { HostCopy.error(self, w) }
}

#if DEBUG
// MARK: - Demo data (DEBUG builds only)

/// Sample sessions and output for looking at the shell screens without a Mac:
/// launch a Debug build with `-PTDemoShell ready` (or `empty`, `connecting`,
/// `unreachable`, `keyUnavailable`). The demo PC, "Office-PC", is chosen in the
/// switcher, or selected by the PC's own states: `pcSignedOut`, `pcOtherUser`,
/// `pcAppClosed`, `pcShellOff`, `pcAsleep`, `pcTurnedOff`, `pcRevoked`, `pcNoAccess`,
/// `pcHome`. Compiled out of Release; without the argument nothing here runs.
/// No network, no Keychain.
extension ShellModel {
    static var demoState: String? { UserDefaults.standard.string(forKey: "PTDemoShell") }

    /// The demo's paired computers: two Macs with the shell, one paired for internet only, and a PC.
    static let demoPaired: [PairedClient] = [
        PairedClient(id: "demo-mac", name: "MacBook Pro", tokenHash: "", pairedAt: .now),
        PairedClient(id: "demo-mac-2", name: "Home Studio", tokenHash: "", pairedAt: .now),
        PairedClient(id: "demo-mac-3", name: "Office iMac", tokenHash: "", pairedAt: .now),
        {
            var pc = PairedClient(id: ShellModel.demoPCID, name: "Office-PC", tokenHash: "", pairedAt: .now)
            pc.hostKind = HostInfo.kindWindows
            return pc
        }(),
    ]

    static let demoPCID = "demo-pc"

    /// What the demo PC says about itself in each of its states.
    fileprivate static func demoPCFacts(_ state: String) -> HostInfo {
        var info = HostInfo(kind: HostInfo.kindWindows, os: "Windows 11 Pro", signedIn: true, app: true, console: "locked", idleSeconds: 840,
                            shells: [HostShell(id: "pwsh", name: "PowerShell", default: true), HostShell(id: "powershell", name: "Windows PowerShell"),
                                     HostShell(id: "cmd", name: "Command Prompt"), HostShell(id: "wsl:Ubuntu", name: "Ubuntu"),
                                     HostShell(id: "gitbash", name: "Git Bash")],
                            screens: [HostInfo.screenRDP], rdp: "ready", access: HostAccess(shell: true, screen: true, share: false),
                            lock: true, sleepAfter: 1800)
        switch state {
        case "pcSignedOut": info.signedIn = false; info.app = false; info.console = "signedOut"
        case "pcOtherUser": info.signedIn = false; info.app = false; info.console = "otherUser"
        case "pcAppClosed": info.app = false
        case "pcShellOff": info.access = HostAccess(shell: false, screen: true, share: false)
        case "pcHome": info.screens = []; info.rdp = "edition"
        default: break
        }
        return info
    }

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

    /// The demo session waiting on a question.
    fileprivate static let demoAskingID = "8F3A1C2E-5B7D-4E60-8F21-3C4D5E6F7A8B"

    /// The second demo Mac's session waiting on a question.
    fileprivate static let demoStudioAskingID = "2C7E9B14-0A3D-4F5E-9B61-7D8E9FA0B1C2"

    /// Each demo Mac's sessions, kept across switches so opened ones stay.
    private static var demoSessions: [String: [ShellSessionInfo]] = [:]

    private static func demoBaseSessions(_ macID: String, now: Double) -> [ShellSessionInfo] {
        if macID == "demo-mac-2" {
            return [
                ShellSessionInfo(id: "studio-1", title: "zsh — ~/music", startedAt: now - 3000, lastOutputAt: now - 300, running: true),
                ShellSessionInfo(id: demoStudioAskingID, title: "codex", startedAt: now - 1200, lastOutputAt: now - 90, running: true,
                                 waiting: "Allow running `swift test`?"),
            ]
        }
        return [
            ShellSessionInfo(id: demoAskingID, title: "claude", startedAt: now - 1900, lastOutputAt: now - 40, running: true,
                             waiting: "Do you want to make this edit to HomeView.swift?"),
            ShellSessionInfo(id: "demo-1", title: "zsh — ~/dev/passthrough", startedAt: now - 760, lastOutputAt: now - 20, running: true),
            ShellSessionInfo(id: "demo-2", title: "npm run build", startedAt: now - 5400, lastOutputAt: now - 3600, running: false, exitStatus: 0),
        ]
    }

    fileprivate func applyDemo(_ state: String) {
        let now = Date().timeIntervalSince1970
        guard state != "noAccess" else { return clear(.noAccess) }
        applyingRefresh = true
        macs = [
            ShellCredential(macID: "demo-mac", macName: "MacBook Pro", certSHA256: "", shellKey: Data(),
                            phoneID: "demo", port: 0, addresses: []),
            ShellCredential(macID: "demo-mac-2", macName: "Home Studio", certSHA256: "", shellKey: Data(),
                            phoneID: "demo", port: 0, addresses: []),
            ShellCredential(macID: Self.demoPCID, macName: "Office-PC", certSHA256: "", shellKey: Data(),
                            phoneID: "demo", port: 0, addresses: [], hostKind: HostInfo.kindWindows),
        ]
        paired = Self.demoPaired
        selectedMacID = MacProfiles.selection(current: selectedMacID, lastUsed: UserDefaults.standard.string(forKey: Self.lastMacKey),
                                              paired: paired.map(\.id), withShell: macs.map(\.macID))
        // The PC's own states show the PC.
        if state.hasPrefix("pc"), clientMacID == nil { selectedMacID = Self.demoPCID }
        applyingRefresh = false
        guard let mac = selectedMacID else { return }
        // The internet-only demo Mac: the same idle state as a real one.
        guard macs.contains(where: { $0.macID == mac }) else {
            applyDemoWatch()
            return idleOnMacWithoutShell(.noAccess)
        }
        if clientMacID != mac {
            switchSessions(to: mac)
            clientMacID = mac
        }
        if mac == Self.demoPCID { return applyDemoPC(state, now: now) }
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
                                vpn: MacState.vpnOn, vpnName: "NordVPN Germany", killSwitch: true, control: true, internet: false)
        }
        if state == "unreachable", macState == nil {
            macState = MacState(awake: false, awakeStopped: MacState.stoppedBattery, battery: 0.2, charging: false, batteryFloor: 0.2, control: true)
        }
        if state == "ready", sessions.isEmpty {
            sessions = Self.demoSessions[mac] ?? Self.demoBaseSessions(mac, now: now)
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
        applyDemoWatch()
    }

    /// The demo PC in `state` (in memory only: nothing it says is stored).
    private func applyDemoPC(_ state: String, now: Double) {
        factsByMac[Self.demoPCID] = Self.demoPCFacts(state)
        farewells[Self.demoPCID] = nil
        let left = Date().addingTimeInterval(-600)
        switch state {
        case "connecting": reach = .connecting
        case "unreachable": reach = .unreachable
        case "pcAsleep":
            reach = .unreachable
            farewells[Self.demoPCID] = HostFarewell(reason: GoingAwayReason.sleeping.rawValue, at: left)
        case "pcTurnedOff":
            reach = .unreachable
            farewells[Self.demoPCID] = HostFarewell(reason: GoingAwayReason.turnedOff.rawValue, at: left)
        case "pcRevoked":
            accessRefused = true
            reach = .noAccess
        case "pcNoAccess": reach = .noAccess
        default:
            reach = .ready
            path = .local
        }
        if reach == .ready, sessions.isEmpty, factsByMac[Self.demoPCID]?.app != false, factsByMac[Self.demoPCID]?.access?.shell != false {
            sessions = Self.demoSessions[Self.demoPCID]
                ?? [ShellSessionInfo(id: "pc-1", title: "PowerShell \u{2014} C:\\Users\\me\\dev", startedAt: now - 900, lastOutputAt: now - 30, running: true)]
            ended.apply(sessions)
        }
        applyDemoWatch()
    }

    /// The other demo Macs as a watch would see them (the second one's
    /// `codex` session is asking), without dialling anything.
    fileprivate func applyDemoWatch() {
        guard Self.demoState == "ready" else { return watcher.demoShow([:]) }
        let now = Date().timeIntervalSince1970
        let ids = MacProfiles.watched(candidates: macs.map(\.macID), selected: selectedMacID,
                                      recency: [:], pinned: watchPinned, limit: MacWatcher.limit)
        watcher.demoShow(Dictionary(uniqueKeysWithValues: ids.map { id in
            (id, MacWatcher.Seen(sessions: Self.demoSessions[id] ?? Self.demoBaseSessions(id, now: now),
                                 state: id == "demo-mac" ? MacState(awake: true, battery: 0.64, charging: false, minutesLeft: 190, batteryFloor: 0.2, control: true)
                                                 : MacState(awake: true, battery: 0.9, charging: true, control: true),
                                 reachable: true, lastHeard: Date(timeIntervalSince1970: now)))
        }))
    }

    fileprivate func demoTimeline(since: Date) {
        let start = Date.now - 2 * 3600 - 14 * 60
        func at(_ minutes: Double) -> Double { start.timeIntervalSince1970 + minutes * 60 }
        let events = [
            MacEvent(t: at(0), kind: MacEvent.kindAwake, title: "iPhone turned Keep awake on"),
            MacEvent(t: at(0.2), kind: MacEvent.kindLink, title: "Off iPhone's connection"),
            MacEvent(t: at(18), kind: MacEvent.kindVPN, title: "VPN dropped", detail: "Reconnecting", warning: true),
            MacEvent(t: at(18.05), kind: MacEvent.kindVPN, title: "VPN reconnected after 2 s", detail: "Kill switch held: nothing left without it"),
            MacEvent(t: at(38), kind: MacEvent.kindShell, title: "npm run build finished", detail: "exit 0 · 34 min", session: "demo-2"),
            MacEvent(t: at(66), kind: MacEvent.kindAsked, title: "claude asked", detail: "Do you want to make this edit to HomeView.swift?", session: Self.demoAskingID),
            MacEvent(t: at(67), kind: MacEvent.kindAnswered, title: "claude got an answer", session: Self.demoAskingID),
            MacEvent(t: at(131), kind: MacEvent.kindPower, title: "Plugged in at 41%"),
        ]
        // Spelled out: as one expression it outran the type checker's time limit.
        func level(_ m: Double) -> Double {
            if m < 131 { return 0.64 - 0.23 * m / 131 }
            return 0.41 + 0.004 * (m - 131)
        }
        let battery: [BatterySample] = stride(from: 0.0, through: 134, by: 5).map { (m: Double) -> BatterySample in
            BatterySample(t: at(m), level: level(m), charging: m >= 131 ? true : nil)
        }
        timeline = MacTimeline(since: since, events: events.filter { $0.t >= since.timeIntervalSince1970 }, battery: battery, loadedAt: .now)
    }

    fileprivate func demoControl(_ change: MacControl) {
        switch change {
        case .awake(let on): macState?.awake = on
        case .vpn(let on): macState?.vpn = on ? MacState.vpnOn : MacState.vpnOff
        case .lock: macState?.locked = true
        }
    }

    fileprivate func demoOpen() {
        let id = "\(selectedMacID ?? "demo")-new-\(sessions.count + 1)"
        let title = selectedKind == .mac ? "zsh — ~" : (preferredShell(for: selectedMacID)?.name ?? "PowerShell")
        sessions.append(ShellSessionInfo(id: id, title: title, startedAt: Date().timeIntervalSince1970,
                                         lastOutputAt: Date().timeIntervalSince1970, running: true))
        if let mac = selectedMacID { Self.demoSessions[mac] = sessions }
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

/// Keep awake, the VPN or the screen lock: something on the Mac this phone can change.
enum MacSwitch: Hashable { case awake, vpn, lock }

/// A change to one switch, sent and not yet answered.
struct PendingControl: Equatable {
    var on: Bool
    var sent: Date
}

/// A change to one switch that didn't take.
struct ControlMiss: Equatable {
    /// What was asked for.
    var on: Bool
    /// The Mac answered with the switch unchanged (it refused); false: no answer came.
    var answered: Bool
}

extension MacControl {
    var parts: (MacSwitch, Bool) {
        switch self {
        case .awake(let on): (.awake, on)
        case .vpn(let on): (.vpn, on)
        case .lock: (.lock, true)
        }
    }
}

/// What happened on a Mac since a time, as it last said.
struct MacTimeline: Equatable {
    var since: Date
    var events: [MacEvent]
    var battery: [BatterySample]
    var loadedAt: Date
}
