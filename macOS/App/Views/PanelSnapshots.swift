import SwiftUI
import AppKit
import IrohTransport
import PassthroughCore
import ShellHost

/// Development aid: renders the menu panel in representative states to PNG.
/// `Passthrough.app/Contents/MacOS/Passthrough --snapshot /tmp/panels`
enum PanelSnapshots {
    @MainActor
    static func render(to directory: String) {
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let states: [(String, (SessionCoordinator) -> Void)] = [
            ("1-no-device", { $0.debugApply(phase: .noDevice) }),
            ("2-ready", { $0.debugApply(phase: .deviceFound, device: true, status: DeviceStatus(deviceName: "My iPhone", radio: "5G", battery: 0.82, hosting: "background")) }),
            ("3-pairing", { $0.debugApply(phase: .pairingRequired, device: true, status: DeviceStatus(deviceName: "My iPhone", radio: "5G", battery: 0.82, hosting: "background")) }),
            ("4-connected", { $0.debugApply(phase: .connected, device: true, status: DeviceStatus(deviceName: "My iPhone", radio: "5G", battery: 0.82, hosting: "background"), traffic: true) }),
            ("5-helper", { $0.debugApply(phase: .helperRequired, device: true) }),
            ("6-vpn", { $0.debugApply(phase: .connected, device: true, status: DeviceStatus(deviceName: "My iPhone", radio: "5G", battery: 0.82, hosting: "background"), traffic: true, vpn: "connected") }),
            ("8-vpn-over-wifi", { $0.debugApply(phase: .deviceFound, device: true, status: DeviceStatus(deviceName: "My iPhone", radio: "5G", battery: 0.82, hosting: "background"), traffic: true, vpn: "connected", underlay: "Wi-Fi") }),
            ("7-vpn-blocked", { $0.debugApply(phase: .connected, device: true, status: DeviceStatus(deviceName: "My iPhone", radio: "5G", battery: 0.82, hosting: "background"), traffic: true, vpn: "blocked") }),
            ("9-shell", { $0.debugApply(phase: .connected, device: true, status: DeviceStatus(deviceName: "My iPhone", radio: "5G", battery: 0.82, hosting: "background"), traffic: true); applyShell($0, .ready) }),
        ]
        for (name, configure) in states {
            let session = SessionCoordinator()
            configure(session)
            for scheme in [ColorScheme.dark, .light] {
                let view = MenuPanelView().environmentObject(session).environmentObject(session.vpnLayer).environmentObject(session.keepAwake).environmentObject(session.shell).environment(\.colorScheme, scheme)
                    .frame(width: 356)
                let renderer = ImageRenderer(content: view)
                renderer.scale = 2
                if let image = renderer.nsImage, let tiff = image.tiffRepresentation,
                   let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                    try? png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name)-\(scheme == .dark ? "dark" : "light").png"))
                }
            }
        }
        renderShellSettings(to: directory)
    }

    enum ShellState { case off, setup, ready }

    /// Remote Shell settings, its Full Disk Access sheet and the history window.
    @MainActor
    private static func renderShellSettings(to directory: String) {
        let dir = URL(fileURLWithPath: directory)
        for (name, state) in [("shell-settings-1-off", ShellState.off), ("shell-settings-2-setup", .setup), ("shell-settings-3-ready", .ready)] {
            let session = SessionCoordinator()
            session.debugApply(phase: .deviceFound, device: true)
            applyShell(session, state)
            for dark in [true, false] {
                let view = RemoteShellSettings()
                    .environmentObject(session).environmentObject(session.keepAwake).environmentObject(session.shell)
                renderHosted(view, size: CGSize(width: 540, height: state == .ready ? 1100 : 760), dark: dark,
                             to: dir.appendingPathComponent("\(name)-\(dark ? "dark" : "light").png"))
            }
        }
        let session = SessionCoordinator()
        applyShell(session, .ready)
        for dark in [true, false] {
            let suffix = dark ? "dark" : "light"
            renderHosted(GeneralSettings().environmentObject(session).environmentObject(session.keepAwake),
                         size: CGSize(width: 540, height: 1250), dark: dark, to: dir.appendingPathComponent("tab-general-\(suffix).png"))
            renderHosted(VPNSettings().environmentObject(session).environmentObject(session.vpnLayer),
                         size: CGSize(width: 540, height: 900), dark: dark, to: dir.appendingPathComponent("tab-vpn-\(suffix).png"))
            renderHosted(NetworkSettings().environmentObject(session),
                         size: CGSize(width: 540, height: 400), dark: dark, to: dir.appendingPathComponent("tab-network-\(suffix).png"))
            renderHosted(FullDiskAccessSheet(), size: CGSize(width: 480, height: 430), dark: dark,
                         to: dir.appendingPathComponent("shell-fda-sheet-\(dark ? "dark" : "light").png"))
            renderHosted(ShellHistoryWindow().environmentObject(session.shell), size: CGSize(width: 900, height: 520), dark: dark,
                         to: dir.appendingPathComponent("shell-history-\(dark ? "dark" : "light").png"))
        }
    }

    @MainActor
    static func applyShell(_ session: SessionCoordinator, _ state: ShellState) {
        session.remoteShellEnabled = state != .off
        let now = Date().timeIntervalSince1970
        let phones = state == .ready ? [
            ShellPhone(phoneID: "p1", label: "My iPhone", pairingSlot: "token", key: Data(count: 32), grantedAt: Date().addingTimeInterval(-86_400 * 3)),
            ShellPhone(phoneID: "p2", label: "Pixel 9", pairingSlot: "token.android.x", key: Data(count: 32), grantedAt: Date().addingTimeInterval(-86_400 * 12)),
        ] : []
        let sessions = state == .ready ? [
            ShellSessionInfo(id: "s1", title: "~/dev/passthrough — npm run build", startedAt: now - 640, lastOutputAt: now - 2, running: true),
        ] : []
        let history = state == .off ? [] : [
            ShellHistoryEntry(id: "s1", title: "~/dev/passthrough — npm run build", phoneLabel: "My iPhone", startedAt: now - 640, bytes: 182_000),
            ShellHistoryEntry(id: "s2", title: "htop", phoneLabel: "My iPhone", startedAt: now - 9_000, endedAt: now - 8_400, exitStatus: 0, bytes: 2_400_000),
            ShellHistoryEntry(id: "s3", title: "~/dev — swift test", phoneLabel: "Pixel 9", startedAt: now - 90_000, endedAt: now - 89_500, exitStatus: 1, bytes: 640_000),
        ]
        var iroh = RemoteShellController.IrohStatus()
        if state == .ready {
            iroh = .init(state: .running, endpointID: "k5x7q2m9a1b3c4d5", homeRelay: "https://use1-1.relay.n0.iroh.iroh.link./", paths: ["p1": .direct])
        }
        session.shell.debugApply(phones: phones, sessions: sessions, history: history, iroh: iroh)
    }

    /// Draws `view` through AppKit (so real controls render, unlike `ImageRenderer`) to a PNG.
    @MainActor
    private static func renderHosted<V: View>(_ view: V, size: CGSize, dark: Bool, to url: URL) {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height)
            .background(Color(nsColor: .windowBackgroundColor)))
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
