import SwiftUI
import PassthroughUI

/// Opens the terminal, the screen and session history from anywhere in the app,
/// so every "needs you" surface lands in the same unchanged terminal.
@MainActor
final class ShellRouter: ObservableObject {
    @Published var terminal: TerminalIntent?
    @Published var showHistory = false
    @Published var showScreen = false

    func dismissAll() {
        terminal = nil
        showHistory = false
        showScreen = false
    }
}

enum RootTab: Hashable { case mac, shells, phone }

/// The app's sections: the Mac first, its shells, then this iPhone's own sharing.
struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var lock: AppLock
    @StateObject private var router = ShellRouter()
    @State private var tab: RootTab = .mac
    @State private var showPairing = false
    @State private var showSettings = false

    var body: some View {
        TabView(selection: $tab) {
            MacHomeView(shell: model.shell, tab: $tab, showPairing: $showPairing, showSettings: $showSettings)
                .tabItem { Label("Mac", systemImage: "laptopcomputer") }
                .tag(RootTab.mac)
            ShellsTab(shell: model.shell)
                .tabItem { Label("Shells", systemImage: "terminal") }
                .tag(RootTab.shells)
            HomeView(showPairing: $showPairing, showSettings: $showSettings)
                .tabItem { Label("iPhone", systemImage: "iphone") }
                .tag(RootTab.phone)
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
        .onAppear {
            let env = ProcessInfo.processInfo.environment
            if env["PASSTHROUGH_AUTOSTART"] == "1" { model.start() }
            if env["PASSTHROUGH_SHOW_PAIRING"] == "1" { DispatchQueue.main.asyncAfter(deadline: .now() + 1) { showPairing = true } }
            if env["PASSTHROUGH_SHOW_SETTINGS"] == "1" { DispatchQueue.main.asyncAfter(deadline: .now() + 1) { showSettings = true } }
            if let start = env["PASSTHROUGH_TAB"] { tab = start == "shells" ? .shells : start == "phone" ? .phone : .mac }
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
