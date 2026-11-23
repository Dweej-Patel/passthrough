import SwiftUI
import PassthroughUI
import PassthroughCore

@main
struct PassthroughMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var session = SessionCoordinator()

    var body: some Scene {
        MenuBarExtra {
            MenuPanelView()
                .environmentObject(session)
                .environmentObject(session.vpnLayer)
                .environmentObject(session.keepAwake)
                .environmentObject(session.shell)
        } label: {
            MenuBarLabel(session: session, vpnLayer: session.vpnLayer, keepAwake: session.keepAwake, shell: session.shell)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObject(session)
                .environmentObject(session.vpnLayer)
                .environmentObject(session.keepAwake)
                .environmentObject(session.shell)
        }

        Window("Shell History", id: ShellHistoryWindow.id) {
            ShellHistoryWindow()
                .environmentObject(session.shell)
        }

        WindowGroup("Screen", id: RemoteScreenWindow.id, for: String.self) { $macID in
            if let macID {
                RemoteScreenWindow(macID: macID)
                    .environmentObject(session.shell)
            }
        }
        .defaultSize(width: 1280, height: 820)

        // A PC's screen, through its Remote Desktop: its own window kind, so another Mac's is untouched.
        WindowGroup("PC Screen", id: PCScreenWindow.id, for: String.self) { $hostID in
            if let hostID {
                PCScreenWindow(hostID: hostID)
                    .environmentObject(session.shell)
            }
        }
        .defaultSize(width: 1280, height: 820)
        .commands { PCScreenCommands() }

        Window("Welcome to Passthrough", id: WelcomeView.id) {
            WelcomeView()
                .environmentObject(session)
        }
        .windowResizability(.contentSize)
    }
}

/// The menu-bar icon (`MenuBarIcon`). Observes everything it shows so any change redraws it.
private struct MenuBarLabel: View {
    @ObservedObject var session: SessionCoordinator
    @ObservedObject var vpnLayer: VPNLayer
    @ObservedObject var keepAwake: KeepAwakeController
    @ObservedObject var shell: RemoteShellController
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        icon.task {
            // First run on a Mac never set up: what should the phone do for it?
            guard !SessionCoordinator.isSnapshotRun, WelcomeView.shouldShow(session) else { return }
            openWindow(id: WelcomeView.id)
            NSApp.activate()
        }
    }

    private var icon: some View {
        Image(nsImage: MenuBarIcon.image(MenuBarIcon.State(
            online: session.phase.isConnected,
            phone: session.device != nil,
            awake: keepAwake.isOn,
            vpn: vpnLayer.status.isConnected,
            screen: !shell.screenViewers.isEmpty,
            needsYou: !shell.phonesAsking.isEmpty,
            problem: vpnLayer.isWanted && vpnLayer.status.isFailing)))
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        Self.raiseFileDescriptorLimit()
        if let index = CommandLine.arguments.firstIndex(of: "--snapshot"), CommandLine.arguments.count > index + 1 {
            let dir = CommandLine.arguments[index + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                PanelSnapshots.render(to: dir)
                // Nothing to tear down in a snapshot run; `terminate` from this
                // main-queue block would wait on a reply queued behind it.
                exit(0)
            }
        }
    }

    private var quitObserver: NSObjectProtocol?
    /// What quitting would end for phones and computers (`RemoteShellController.quitWarning`); set by the coordinator.
    static var quitWarning: (() -> String?)?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Asked only for a quit from Passthrough itself (⌘Q, the panel's power button). One that comes
        // as an Apple event (logging out, shutting down, the install script) goes ahead: nobody may be
        // there to answer, and the script checks for shells itself.
        if !SessionCoordinator.isSnapshotRun, NSAppleEventManager.shared().currentAppleEvent == nil,
           let warning = Self.quitWarning?(), !Self.confirmQuit(warning) {
            return .terminateCancel
        }
        // Let the coordinator tear the tunnel down and turn the VPN off (else
        // the helper keeps its kill switch blocking, as after a crash): quit
        // once it says it is done, or after 4 s regardless.
        var replied = false
        let reply = { [weak self] in
            guard !replied else { return }
            replied = true
            if let observer = self?.quitObserver { NotificationCenter.default.removeObserver(observer) }
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        quitObserver = NotificationCenter.default.addObserver(forName: .passthroughReadyToQuit, object: nil, queue: .main) { _ in reply() }
        NotificationCenter.default.post(name: .passthroughWillTerminate, object: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { reply() }
        return .terminateLater
    }
}

extension AppDelegate {
    /// "Quit Passthrough? 2 shells from your phones end." True to quit.
    static func confirmQuit(_ warning: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Quit Passthrough?"
        alert.informativeText = warning
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        // A menu bar app isn't in front: the question would open behind whatever is.
        NSApp.activate()
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Every proxied flow costs two descriptors (loopback + usbmuxd); the GUI
    /// default of 256 is exhausted by a single busy browser tab.
    static func raiseFileDescriptorLimit() {
        var limit = rlimit()
        guard getrlimit(RLIMIT_NOFILE, &limit) == 0 else { return }
        let wanted = rlim_t(OPEN_MAX)
        limit.rlim_cur = min(wanted, limit.rlim_max)
        if setrlimit(RLIMIT_NOFILE, &limit) != 0 {
            limit.rlim_cur = 4096
            _ = setrlimit(RLIMIT_NOFILE, &limit)
        }
        getrlimit(RLIMIT_NOFILE, &limit)
        PassthroughLog.shared.log(.info, "File descriptor limit: \(limit.rlim_cur)")
    }
}

extension Notification.Name {
    static let passthroughWillTerminate = Notification.Name("\(PassthroughProtocol.identifier).willTerminate")
    /// The coordinator finished tearing down for a quit.
    static let passthroughReadyToQuit = Notification.Name("\(PassthroughProtocol.identifier).readyToQuit")
}
