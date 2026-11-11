import SwiftUI
import PassthroughCore
import PassthroughUI

/// Opens the terminal, the screen and session history from anywhere in the app,
/// so every "needs you" surface lands in the same unchanged terminal.
@MainActor
final class ShellRouter: ObservableObject {
    @Published var terminal: TerminalIntent?
    @Published var showHistory = false
    @Published var showScreen = false
    /// The Mac tab's "This iPhone" screen is pushed.
    @Published var showThisPhone = false

    func dismissAll() {
        terminal = nil
        showHistory = false
        showScreen = false
    }
}

enum RootTab: Hashable { case mac, shells, activity }

/// The app's sections: the Mac (with this iPhone's own sharing one tap in), its shells, what happened.
struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var lock: AppLock
    @StateObject private var router = ShellRouter()
    @ObservedObject private var links = PendingLinks.shared
    @State private var tab: RootTab = .mac
    @State private var showPairing = false
    @State private var showSettings = false

    var body: some View {
        TabView(selection: $tab) {
            MacHomeView(shell: model.shell, tab: $tab, showPairing: $showPairing, showSettings: $showSettings)
                .tabItem { Label("Mac", systemImage: "laptopcomputer") }
                .badge(asking)
                .tag(RootTab.mac)
            ShellsTab(shell: model.shell)
                .tabItem { Label("Shells", systemImage: "terminal") }
                .tag(RootTab.shells)
            ActivityTab(shell: model.shell)
                .tabItem { Label("Activity", systemImage: "clock") }
                .tag(RootTab.activity)
        }
        .environmentObject(router)
        .fullScreenCover(item: $router.terminal) { intent in
            TerminalScreen(shell: model.shell, intent: intent)
        }
        .sheet(isPresented: $router.showHistory) {
            ShellHistoryView(shell: model.shell)
        }
        .fullScreenCover(isPresented: $router.showScreen) {
            ScreenView(shell: model.shell).environmentObject(lock)
        }
        .sheet(isPresented: $showPairing, onDismiss: { model.endPairing() }) {
            PairSheet().environmentObject(model)
        }
        .sheet(isPresented: $showSettings) {
            SettingsView().environmentObject(model).environmentObject(lock)
        }
        #if DEBUG
        .task(id: model.shell.reach) { if ScreenModel.demoState != nil, model.shell.reach == .ready { router.showScreen = true } }
        #endif
        .onChange(of: lock.isUnlocked) { _, unlocked in
            // Tear presentations down deterministically when the app locks.
            if !unlocked {
                router.dismissAll()
                showPairing = false
                showSettings = false
                model.endPairing()
            }
        }
        // Links arrive at the app's root (`PassthroughApp`), even before this is
        // built; one waits for the unlock, and a change to the Mac for the Mac.
        .onChange(of: links.pending) { _, _ in runPendingLink() }
        .onChange(of: lock.isUnlocked) { _, _ in runPendingLink() }
        .onChange(of: model.shell.reach) { _, _ in runPendingLink(); refreshSurfaces() }
        .onChange(of: model.shell.macState) { _, _ in runPendingLink(); refreshSurfaces() }
        .onChange(of: model.shell.sessions) { _, _ in refreshSurfaces() }
        .onChange(of: model.shell.watcher.seen) { _, _ in refreshSurfaces() }
        .onChange(of: model.shell.selectedMacID) { _, _ in refreshSurfaces() }
        .onAppear {
            // Keep watching the Mac a running Live Activity belongs to (also after a relaunch).
            MacActivityController.shared.onActivityMacChange = { [shell = model.shell] in shell.pinWatch($0) }
            // A link that came in before the first unlock built this.
            runPendingLink()
            #if DEBUG
            let env = ProcessInfo.processInfo.environment
            if env["PASSTHROUGH_AUTOSTART"] == "1" { model.start() }
            if env["PASSTHROUGH_SHOW_PAIRING"] == "1" { DispatchQueue.main.asyncAfter(deadline: .now() + 1) { showPairing = true } }
            if env["PASSTHROUGH_SHOW_SETTINGS"] == "1" { DispatchQueue.main.asyncAfter(deadline: .now() + 1) { showSettings = true } }
            // "phone": the Mac tab with This iPhone pushed, where the iPhone tab's content now lives.
            if let start = env["PASSTHROUGH_TAB"] {
                tab = ["shells": .shells, "activity": .activity][start] ?? .mac
                if start == "phone" { router.showThisPhone = true }
            }
            if env["PASSTHROUGH_START_ACTIVITY"] == "1" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { MacActivityController.shared.keepAwakeAsked(seen(reachable: true)) }
            }
            #endif
        }
    }
}

extension RootView {
    /// Shells waiting on a question: the Mac tab's badge.
    private var asking: Int { model.shell.visibleSessions.filter(\.isAsking).count }

    private func seen(reachable: Bool) -> MacActivityController.Seen {
        let shell = model.shell
        return .init(macID: shell.selectedMacID, macName: shell.selectedMacName, reachable: reachable,
                     lastHeard: shell.lastHeard, state: shell.macState, sessions: shell.visibleSessions)
    }

    private func runPendingLink() {
        guard lock.isUnlocked, let link = links.pending else { return }
        let shell = model.shell
        switch link {
        case .mac:
            selectLinked(link)
            tab = .mac
            router.showThisPhone = false
            links.done()
        case .session(let id, _):
            // The Mac first: its tabs come back, and the terminal's tab is kept as that Mac's.
            // A Mac no longer paired: nothing to attach on any other; just the Mac tab.
            // Nor on a paired Mac without a usable shell credential (internet only, or its key is gone).
            guard selectLinked(link), shell.selectedMac != nil else {
                tab = .mac
                router.showThisPhone = false
                return links.done()
            }
            router.terminal = .attach(id)
            links.done()
        case .keepAwake, .vpnOn:
            tab = .mac
            guard shell.reach == .ready, let state = shell.macState else { return }   // waits for the Mac
            links.done()
            guard state.control == true else {
                links.note = ShellError.notAllowed.message
                return
            }
            if link == .keepAwake {
                shell.control(.awake(true))
                MacActivityController.shared.keepAwakeAsked(seen(reachable: true))
            } else {
                shell.control(.vpn(true))
            }
        }
    }

    /// A link from a Live Activity or widget names the Mac it shows: switch to it.
    /// Without one (an older link), a session link belongs to the running
    /// activity's Mac (tagged or adopted), else the Mac selected now. False when
    /// it names a Mac that isn't paired: nothing should be opened.
    @discardableResult
    private func selectLinked(_ link: AppLink) -> Bool {
        let target = link.target(activityMac: MacActivityController.shared.activityMacID,
                                 paired: model.pairedClients.map(\.id))
        switch target {
        case .current: return true
        case .mac(let macID):
            // A terminal, screen or history still open is the Mac being left's: close it
            // first, or what's typed into it (a Screen Sharing login) goes to the new one.
            if macID != model.shell.selectedMacID { router.dismissAll() }
            model.shell.select(macID)
            return true
        case .rejected: return false
        }
    }

    /// The Live Activity and the widget show what the app last saw. Locked or
    /// connecting, they keep it (and go stale on their own); unreachable, they
    /// say when they last heard.
    private func refreshSurfaces() {
        let shell = model.shell
        guard !shell.macs.isEmpty || !model.pairedClients.isEmpty else { return MacActivityController.shared.clear() }
        let controller = MacActivityController.shared
        controller.adoptUntagged(selectedMacID: shell.selectedMacID, paired: model.pairedClients.map { client in
            (id: client.id, name: shell.macs.first(where: { $0.macID == client.id })?.macName ?? client.shell?.macName ?? client.name)
        })
        let selected: MacActivityController.Seen?
        switch shell.reach {
        case .ready: selected = seen(reachable: true)
        case .unreachable, .noAccess: selected = seen(reachable: false)
        case .connecting, .locked, .needsPasscode, .keyUnavailable: selected = nil
        }
        // The activity follows the Mac Keep awake was turned on for, not the selection.
        var activity: MacActivityController.Seen?
        if let id = controller.activityMacID {
            if id == shell.selectedMacID {
                activity = selected
            } else if let client = model.pairedClients.first(where: { $0.id == id }) {
                // Still paired: locked, without its credential or not watched yet, it keeps what it last showed.
                if let heard = shell.watcher.seen[id], heard.state != nil {
                    let name = shell.macs.first(where: { $0.macID == id })?.macName ?? client.name
                    activity = .init(macID: id, macName: name, reachable: heard.reachable, lastHeard: heard.lastHeard,
                                     state: heard.state, sessions: heard.sessions ?? [])
                }
            } else {
                controller.clear()   // that Mac was forgotten
            }
        }
        controller.refresh(selected: selected, selection: (shell.selectedMacID, shell.selectedMacName), activity: activity)
    }
}

/// The Shells tab: the Mac's sessions, history and screen. The terminal itself is unchanged.
struct ShellsTab: View {
    @ObservedObject var shell: ShellModel
    @EnvironmentObject private var router: ShellRouter

    var body: some View {
        NavigationStack {
            ScrollView {
                RemoteShellCard(shell: shell)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
            }
            .background(PTColor.background)
            .navigationTitle("Shells")
            .toolbar {
                if shell.reach == .ready {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { router.terminal = .new } label: { Image(systemName: "plus") }
                            .accessibilityLabel("New session")
                    }
                }
            }
        }
    }
}
