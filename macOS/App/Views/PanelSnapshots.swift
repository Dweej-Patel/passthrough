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
                let view = MenuPanelView().environmentObject(session).environmentObject(session.vpnLayer).environmentObject(session.keepAwake).environmentObject(session.shell)
                    .background(Color(nsColor: .windowBackgroundColor))
                capture(view, width: 356, scheme: scheme, to: directory, name: "\(name)-\(scheme == .dark ? "dark" : "light")")
            }
        }
        renderShellSettings(to: directory)
        renderNotices(to: directory)
        renderWelcome(to: directory)
        renderMenuBarIcons(to: directory)
    }

    @MainActor
    private static func renderWelcome(to directory: String) {
        let session = SessionCoordinator()
        for scheme in [ColorScheme.dark, .light] {
            let view = WelcomeView().environmentObject(session).background(Color(nsColor: .windowBackgroundColor))
            capture(view, width: 900, scheme: scheme, to: directory, name: "welcome-\(scheme == .dark ? "dark" : "light")")
        }
    }

    /// Every icon state on a light and a dark menu bar, at 4x.
    @MainActor
    private static func renderMenuBarIcons(to directory: String) {
        let states: [MenuBarIcon.State] = [
            .init(), .init(online: true), .init(online: true, awake: true), .init(online: true, vpn: true),
            .init(online: true, needsYou: true), .init(awake: true, needsYou: true), .init(problem: true),
        ]
        for (name, appearance) in [("dark", NSAppearance.Name.darkAqua), ("light", .aqua)] {
            let cell = MenuBarIcon.size, gap: CGFloat = 14, scale: CGFloat = 4
            let width = CGFloat(states.count) * (cell.width + gap) + gap
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width * scale), pixelsHigh: Int((cell.height + 12) * scale),
                                       bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            rep.size = NSSize(width: width, height: cell.height + 12)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            NSAppearance(named: appearance)!.performAsCurrentDrawingAppearance {
                (appearance == .darkAqua ? NSColor(white: 0.16, alpha: 1) : NSColor(white: 0.93, alpha: 1)).setFill()
                NSRect(origin: .zero, size: rep.size).fill()
                for (i, state) in states.enumerated() {
                    let rect = NSRect(x: gap + CGFloat(i) * (cell.width + gap), y: 6, width: cell.width, height: cell.height)
                    NSGraphicsContext.saveGraphicsState()
                    let shift = NSAffineTransform(); shift.translateX(by: rect.minX, yBy: rect.minY); shift.concat()
                    MenuBarIcon.draw(state, in: NSRect(origin: .zero, size: cell), ink: .labelColor)
                    NSGraphicsContext.restoreGraphicsState()
                }
            }
            NSGraphicsContext.restoreGraphicsState()
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: directory).appendingPathComponent("menubar-\(name).png"))
        }
    }

    /// Through a real (offscreen) window, so native controls (segmented
    /// pickers, switches) draw as they do on screen; `ImageRenderer` can't.
    @MainActor
    private static func capture<V: View>(_ view: V, width: CGFloat, scheme: ColorScheme, to directory: String, name: String) {
        let appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        let host = NSHostingView(rootView: view.frame(width: width))
        host.appearance = appearance
        let height = host.fittingSize.height
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = appearance
        window.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: width, height: height)
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
    }

    /// The notice from the notch, and the capsule on a screen without one.
    @MainActor
    private static func renderNotices(to directory: String) {
        let kinds: [(String, NotchNotice.Kind)] = [
            ("quiet", .quiet(title: "iPhone turned Keep awake on", detail: nil, symbol: "cup.and.saucer")),
            ("lowered", .lowered(title: "iPhone turned the VPN off", detail: "Kill switch off too", action: "Turn back on") {}),
        ]
        for (name, kind) in kinds {
            for notch in [CGFloat(32), 0] {
                for scheme in [ColorScheme.dark, .light] {
                    let view = NotchNoticeView(kind: kind, notchHeight: notch, snapshot: true) {}
                        .environment(\.colorScheme, scheme)
                        .background(Color(red: 0.35, green: 0.42, blue: 0.55))
                    let renderer = ImageRenderer(content: view)
                    renderer.scale = 2
                    if let image = renderer.nsImage, let tiff = image.tiffRepresentation,
                       let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                        let shape = notch > 0 ? "notch" : "capsule"
                        try? png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("notice-\(name)-\(shape)-\(scheme == .dark ? "dark" : "light").png"))
                    }
                }
            }
        }
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
            ShellPhone(phoneID: "p1", label: "My iPhone", pairingSlot: "token", key: Data(count: 32), grantedAt: Date().addingTimeInterval(-86_400 * 3), screen: true),
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
        let viewers = state == .ready ? [RemoteShellController.ScreenViewer(phoneID: "p1", label: "My iPhone", connections: 1)] : []
        session.shell.debugApply(phones: phones, sessions: sessions, history: history, iroh: iroh,
                                 screenViewers: viewers, screenSharingOn: state == .off ? nil : state == .ready)
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
