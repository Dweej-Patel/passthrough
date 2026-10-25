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
        .onAppear {
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
    private var asking: Int { model.shell.sessions.filter(\.isAsking).count }

    private func seen(reachable: Bool) -> MacActivityController.Seen {
        let shell = model.shell
        return .init(macID: shell.selectedMacID, macName: shell.selectedMacName, reachable: reachable,
                     lastHeard: shell.lastHeard, state: shell.macState, sessions: shell.sessions)
    }

    private func runPendingLink() {
        guard lock.isUnlocked, let link = links.pending else { return }
        let shell = model.shell
        switch link {
        case .mac:
            tab = .mac
            router.showThisPhone = false
            links.done()
        case .session(let id):
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

    /// The Live Activity and the widget show what the app last saw. Locked or
    /// connecting, they keep it (and go stale on their own); unreachable, they
    /// say when they last heard.
    private func refreshSurfaces() {
        let shell = model.shell
        guard !shell.macs.isEmpty || !model.pairedClients.isEmpty else { return MacActivityController.shared.clear() }
        switch shell.reach {
        case .ready: MacActivityController.shared.refresh(seen(reachable: true))
        case .unreachable, .noAccess: MacActivityController.shared.refresh(seen(reachable: false))
        case .connecting, .locked, .needsPasscode, .keyUnavailable: break
        }
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
