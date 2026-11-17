import Combine
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

    /// True when something was showing (its dismissal is then still under way).
    @discardableResult
    func dismissAll() -> Bool {
        let shown = terminal != nil || showHistory || showScreen
        terminal = nil
        showHistory = false
        showScreen = false
        return shown
    }
}

enum RootTab: Hashable { case mac, shells, activity, device }

/// A full-screen cover presented through UIKit, not SwiftUI's own: measured, every
/// publish of the app's model (at least one a second: device facts, the log, traffic
/// while serving) reached a SwiftUI cover as a trait change, and UIKit redrew every
/// icon and label in it. Open menus flickered like a heartbeat and lost their scroll
/// place. A controller presented here has no such path in. Shows `content` while `id()`
/// isn't nil; another id is another presentation. `onDismiss` runs once it's gone.
///
/// It follows `changes` itself (the router's), not this view's updates: once the cover
/// is up, the view under it is out of the window and SwiftUI stops updating this one,
/// so a request to close would never be heard.
private struct UIKitCover<ID: Hashable, Content: View>: UIViewControllerRepresentable {
    let changes: AnyPublisher<Void, Never>
    let id: () -> ID?
    let onDismiss: () -> Void
    @ViewBuilder let content: () -> Content

    final class Coordinator {
        var presented: UIViewController?
        var presentedID: ID?
        var wanted: (id: ID, make: () -> UIViewController)?
        var onDismiss: () -> Void = {}
        weak var anchor: UIViewController?
        var busy = false
        var id: () -> ID? = { nil }
        var make: () -> UIViewController = { UIViewController() }
        var watching: AnyCancellable?

        /// What's wanted now, then `sync`. On the next turn: a publisher fires before its value changes.
        func refresh() {
            DispatchQueue.main.async { [self] in
                wanted = id().map { ($0, make) }
                sync()
            }
        }

        /// Brings what's presented in line with what's wanted, one transition at a time.
        func sync() {
            guard !busy, wanted?.id != presentedID else { return }
            if let shown = presented {
                // Gone first (straight to the next one if there is one, without the slide).
                busy = true
                presented = nil
                presentedID = nil
                let finish = { [self] in
                    busy = false
                    onDismiss()
                    sync()
                }
                if shown.presentingViewController != nil { shown.dismiss(animated: wanted == nil, completion: finish) } else { finish() }
            } else if let wanted, var top = anchor?.view.window?.rootViewController {
                while let next = top.presentedViewController, !next.isBeingDismissed { top = next }
                let host = wanted.make()
                // Over the root, not instead of it: a plain full-screen presentation takes the
                // root out of the window, which SwiftUI reads as it disappearing (its tasks
                // cancelled, then started again on return). This way it stays as it was.
                host.modalPresentationStyle = .overFullScreen
                // Presented over the root, it would otherwise leave the status bar to the root
                // (shown, in the root's style) whatever the content asks for.
                host.modalPresentationCapturesStatusBarAppearance = true
                host.view.backgroundColor = .black
                presented = host
                presentedID = wanted.id
                busy = true
                top.present(host, animated: true) { [self] in
                    busy = false
                    sync()
                }
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIViewController(context: Context) -> UIViewController { UIViewController() }

    func updateUIViewController(_ anchor: UIViewController, context: Context) {
        let coordinator = context.coordinator
        coordinator.anchor = anchor
        coordinator.onDismiss = onDismiss
        coordinator.id = id
        let content = self.content
        // Opaque under whatever the content paints: presented over the root, anything it
        // leaves clear would show the app behind it.
        coordinator.make = { UIHostingController(rootView: ZStack { Color.black.ignoresSafeArea(); content() }) }
        if coordinator.watching == nil {
            coordinator.watching = changes.sink { [weak coordinator] in coordinator?.refresh() }
        }
        coordinator.refresh()
    }
}

/// The app's sections: the Mac, its shells, what happened, and this device
/// (an iPhone's sharing and paired devices; an iPad's iPhone and Macs).
struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var lock: AppLock
    @StateObject private var router = ShellRouter()
    @ObservedObject private var links = PendingLinks.shared
    @State private var tab: RootTab = .mac
    @State private var showPairing = false
    @State private var showSettings = false
    /// A link closed what was showing for the Mac being left: its terminal waits for
    /// that to be gone, since presenting while another cover is still dismissing can fail.
    @State private var linkAwaitsDismiss = false

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
            NavigationStack {
                ThisPhoneView(showPairing: $showPairing, showSettings: $showSettings)
            }
            .tabItem { Label(ThisDevice.name, systemImage: ThisDevice.symbol) }
            .tag(RootTab.device)
        }
        .environmentObject(router)
        .sheet(isPresented: $router.showHistory, onDismiss: presentationDismissed) {
            ShellHistoryView(shell: model.shell)
        }
        // The terminal and the Mac's screen, presented through UIKit (`UIKitCover` says why).
        .background { terminalCover }
        .background { screenCover }
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
                linkAwaitsDismiss = false   // the unlock runs a waiting link again anyway
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
            if let start = env["PASSTHROUGH_TAB"] {
                tab = ["shells": .shells, "activity": .activity, "phone": .device][start] ?? .mac
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
    private var terminalCover: some View {
        UIKitCover(changes: router.objectWillChange.eraseToAnyPublisher(), id: { [router] in router.terminal?.id },
                   onDismiss: presentationDismissed) {
            if let intent = router.terminal {
                TerminalScreen(shell: model.shell, intent: intent, onClose: { [weak router] in router?.terminal = nil })
                    .environmentObject(model).environmentObject(lock).environmentObject(router)
                    .tint(PTColor.tintText)
            }
        }
    }

    private var screenCover: some View {
        UIKitCover(changes: router.objectWillChange.eraseToAnyPublisher(), id: { [router] in router.showScreen ? true : nil },
                   onDismiss: presentationDismissed) {
            ScreenView(shell: model.shell, onClose: { [weak router] in router?.showScreen = false })
                .environmentObject(model).environmentObject(lock).environmentObject(router)
                .tint(PTColor.tintText)
        }
    }

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
            links.done()
        case .session(let id, _):
            // Just unlocked, the shell may not have rebuilt its Macs yet (the app's own unlock
            // handler can run after this one): wait for the reach change that follows.
            if shell.reach == .locked { return }
            // The Mac first: its tabs come back, and the terminal's tab is kept as that Mac's.
            // A Mac no longer paired: nothing to attach on any other; just the Mac tab.
            // Nor on a paired Mac without a usable shell credential (internet only, or its key is gone).
            guard selectLinked(link), shell.selectedMac != nil else {
                tab = .mac
                return links.done()
            }
            // Presented once what was showing for the Mac left is gone (`presentationDismissed`).
            guard !linkAwaitsDismiss else { return }
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

    /// The terminal, history or screen finished closing: a link waiting on that runs now.
    private func presentationDismissed() {
        guard linkAwaitsDismiss else { return }
        linkAwaitsDismiss = false
        runPendingLink()
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
            if macID != model.shell.selectedMacID, router.dismissAll() {
                linkAwaitsDismiss = true
                // In case nothing was really on screen (a terminal still queued behind a sheet):
                // then no `onDismiss` comes, and the link would wait until it expires.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { presentationDismissed() }
            }
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
