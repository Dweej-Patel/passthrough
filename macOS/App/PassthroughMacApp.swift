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
        } label: {
            MenuBarLabel(session: session, vpnLayer: session.vpnLayer, keepAwake: session.keepAwake)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObject(session)
                .environmentObject(session.vpnLayer)
                .environmentObject(session.keepAwake)
        }
    }
}

/// The menu-bar icon: the phone shows passthrough on/off, with badges for the
/// VPN layer and keep-awake. Observes all three so any of them redraws it.
private struct MenuBarLabel: View {
    @ObservedObject var session: SessionCoordinator
    @ObservedObject var vpnLayer: VPNLayer
    @ObservedObject var keepAwake: KeepAwakeController

    var body: some View {
        Image(nsImage: MenuBarIcon.image(passthroughOn: session.phase.isConnected, vpnOn: vpnLayer.status.isConnected, keepAwake: keepAwake.isOn))
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
                NSApp.terminate(nil)
            }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Give the coordinator a moment to tear the tunnel down cleanly.
        NotificationCenter.default.post(name: .passthroughWillTerminate, object: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { NSApp.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
}

extension AppDelegate {
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
    static let passthroughWillTerminate = Notification.Name("dev.dpatel.passthrough.willTerminate")
}
