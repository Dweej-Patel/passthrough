import SwiftUI
import PassthroughCore
import PassthroughUI

/// The menu bar panel, read top to bottom: what the Mac is doing, the three
/// switches (each saying why when it can't turn on, and what fixes it), what
/// your phone is doing here, then the details: the link, speeds, top apps.
struct MenuPanelView: View {
    @EnvironmentObject private var session: SessionCoordinator
    @EnvironmentObject private var keepAwake: KeepAwakeController
    @EnvironmentObject private var vpnLayer: VPNLayer
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Group {
            if session.panelVisible || SessionCoordinator.isSnapshotRun {
                panel
            } else {
                // Closed: MenuBarExtra keeps this view alive; don't lay out or
                // rasterise the chart for a panel nobody can see.
                Color.clear.frame(width: 356, height: 120)
            }
        }
        .background(WindowVisibilityObserver { visible in
            if session.panelVisible != visible { session.panelVisible = visible }
        })
    }

    private var panel: some View {
        VStack(spacing: 12) {
            header
            AskingRows()
            ScrollView {
                VStack(spacing: 12) {
                    if session.phase == .pairingRequired { PairingCard() }
                    Switches()
                    PhoneHereSection()
                    Details()
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { bodyHeight = $0 }
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(height: min(bodyHeight, maxBodyHeight))
            Divider().opacity(0.6)
            footer
        }
        .padding(14)
        .frame(width: 356)
    }

    /// The middle of the panel scrolls once it's taller than the screen leaves
    /// room for, under the header and above the footer.
    @State private var bodyHeight: CGFloat = 600
    private var maxBodyHeight: CGFloat { max(240, (NSScreen.screens.first?.visibleFrame.height ?? 800) - 150) }

    // MARK: Header

    private var phoneName: String { session.phoneStatus?.deviceName ?? session.phoneKindName }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: session.device?.kind == .android ? "smartphone" : "iphone.gen3")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(session.phase.isConnected ? PTColor.onTint : Color.secondary)
                .frame(width: 34, height: 34)
                .background(session.phase.isConnected ? PTColor.tint : Color.primary.opacity(0.08), in: Circle())
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.headline).lineLimit(1).contentTransition(.opacity)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1).contentTransition(.opacity)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    private var title: String {
        switch session.phase {
        case .connected: "Online through \(phoneName)"
        case .connecting: "Connecting to \(phoneName)…"
        case .pairingRequired: "Pair with \(phoneName)"
        default: "Not using your \(session.phoneKindName)"
        }
    }

    /// "VPN on · USB · 5G · iPhone 82%" while online; else which network the Mac is on.
    private var subtitle: String {
        let vpnOn = vpnLayer.isWanted && vpnLayer.status.isConnected
        switch session.phase {
        case .connected:
            var parts = vpnOn ? ["VPN on"] : []
            parts.append(session.device?.medium == .wireless ? (session.wirelessCarrier ?? "Wireless") : "USB")
            if let radio = session.phoneStatus?.radio { parts.append(radio) }
            if let battery = session.phoneStatus?.battery { parts.append("\(session.phoneKindName) \(MacFormat.percent(battery))") }
            return parts.joined(separator: " · ")
        case .connecting(let step): return step
        case .pairingRequired: return "Type the code shown on the \(session.phoneKindName)"
        default: return vpnOn ? "VPN on, over this Mac's own network" : "This Mac is on its own network"
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 10) {
            Text(macHealth).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Spacer()
            Toggle(isOn: $session.autoConnect) { Text("Connect on plug-in").lineLimit(1).fixedSize() }
                .toggleStyle(MintSwitchStyle(small: true))
                .font(.caption)
                .help("Go online through the phone as soon as it's plugged in. Turning Internet off keeps it off until you plug the phone in again.")
            Button { SettingsWindow.show(openSettings) } label: { Image(systemName: "gearshape").font(.system(size: 13, weight: .semibold)) }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .help("Settings (⌘,)")
                .keyboardShortcut(",", modifiers: .command)
            Button { NSApp.terminate(nil) } label: { Image(systemName: "power").font(.system(size: 13, weight: .semibold)) }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .help("Quit Passthrough (⌘Q)")
                .keyboardShortcut("q", modifiers: .command)
        }
    }

    /// "Mac 64% · charging", "Mac 30% · running hot"; "heat normal" on a desktop Mac.
    private var macHealth: String {
        let battery = keepAwake.battery
        var parts: [String] = []
        if battery.hasBattery, battery.percent >= 0 { parts.append("Mac \(battery.percent)%\(battery.isOnAC ? " · charging" : "")") }
        if KeepAwakeController.isHot(keepAwake.thermal) {
            parts.append("running \(KeepAwakeController.describe(keepAwake.thermal))")
        } else if parts.isEmpty {
            parts.append("heat normal")
        }
        return parts.joined(separator: " · ")
    }
}

// MARK: - The three switches

/// Internet through the phone, Keep awake and the VPN. Each shows what is so,
/// never what was asked for: a switch that can't turn on flips back off and
/// says why under it, with what fixes it.
struct Switches: View {
    @EnvironmentObject private var session: SessionCoordinator
    @EnvironmentObject private var vpnLayer: VPNLayer
    @EnvironmentObject private var keepAwake: KeepAwakeController
    @Environment(\.openSettings) private var openSettings
    /// Keep awake turning off with shells running, waiting on "Let it sleep".
    @State private var askingSleep = false

    var body: some View {
        PTSurface(padding: 4) {
            VStack(spacing: 0) {
                internet
                Divider().padding(.leading, 50)
                awake
                Divider().padding(.leading, 50)
                vpn
            }
        }
        .onChange(of: keepAwake.isOn) { _, on in if !on { askingSleep = false } }
    }

    // MARK: Internet

    private var kind: String { session.phoneKindName }

    private var internet: some View {
        let phase = session.phase
        return SwitchRow(title: "Internet through \(session.phoneStatus?.deviceName ?? kind)", symbol: "antenna.radiowaves.left.and.right",
                         status: internetStatus, isOn: phase.isConnected || phase.isBusy, busy: phase.isBusy,
                         reason: internetReason, set: setInternet) {
            if phase == .helperRequired {
                Button("Open System Settings") { session.openLoginItems() }.buttonStyle(PTPillButtonStyle())
                Button("Try again") { session.retryHelper() }.buttonStyle(.link)
            } else if case .error = phase {
                Button("Try again") { session.connect() }.buttonStyle(PTPillButtonStyle())
                if session.retrying { Button("Stop trying") { session.disconnect() }.buttonStyle(.link) }
            }
        }
        .help("Send all of this Mac's traffic through the \(kind)'s connection")
    }

    private var internetStatus: String {
        switch session.phase {
        case .connected:
            if session.phoneStatus?.radio == "Wi-Fi" { return "On · the \(kind) is on Wi-Fi, so that's what the Mac uses" }
            return "On · \(session.linkName)\(session.phoneStatus?.radio.map { " · \($0)" } ?? "")"
        case .connecting: return "Connecting…"
        case .pairingRequired: return "Waiting for the pairing code"
        case .error where session.retrying: return "Off · trying again by itself"
        default:
            if session.device != nil, session.heldOff { return "Off until you turn it on or plug the \(kind) in again" }
            return "Off · the Mac uses its own Wi-Fi or Ethernet"
        }
    }

    /// Why Internet can't be on right now, in the user's terms.
    private var internetReason: String? {
        switch session.phase {
        case .noDevice:
            if session.connectionMode == .wireless {
                return "Bring your phone near, with Passthrough open and Wireless link on."
            }
            return "Plug in your iPhone or Android phone with a cable. " + (session.androidHint ?? "Unlock it, and tap Trust if it asks.")
        case .helperRequired:
            if case .failed(let why) = session.helperAvailability { return "Passthrough's helper couldn't start: \(why)" }
            return "Allow Passthrough's helper in System Settings ▸ Login Items ▸ Allow in the Background."
        case .error(let message):
            if session.phoneAppClosed { return "Open Passthrough on your \(kind) and tap its power button." }
            return message
        default: return nil
        }
    }

    private func setInternet(_ on: Bool) -> Bool {
        guard on else { session.disconnect(); return true }
        guard session.device != nil, session.phase != .helperRequired else { return false }
        session.connect()
        return true
    }

    // MARK: Keep awake

    private var awake: some View {
        SwitchRow(title: "Keep Mac awake", symbol: "cup.and.saucer", status: awakeStatus, isOn: keepAwake.isOn,
                  reason: awakeReason, set: setAwake) {
            if keepAwake.blockedReason != nil {
                Button(keepAwake.blockedByBattery ? "Change the limit" : "Settings") { SettingsWindow.show(openSettings, tab: .general) }
                    .buttonStyle(PTPillButtonStyle())
            } else if lidNotHeld {
                Button("Open System Settings") { session.openLoginItems() }.buttonStyle(PTPillButtonStyle())
            }
        } below: {
            if askingSleep, let warning = session.sleepWarning {
                SleepConfirm(warning: warning, action: "Let it sleep") {
                    askingSleep = false
                    keepAwake.set(false)
                } cancel: { askingSleep = false }
            }
        }
        .help(keepAwake.hasLid
              ? "Keeps the Mac awake for long sessions, even with the lid closed. A closed, running Mac in a bag can overheat and drain the battery."
              : "Keeps the Mac awake for long sessions. The screen still turns off and locks.")
    }

    private var lidNotHeld: Bool { keepAwake.isOn && keepAwake.hasLid && !keepAwake.lidCloseHeld }

    private var awakeStatus: String {
        guard keepAwake.isOn else { return "Off · the Mac sleeps as usual" }
        guard keepAwake.hasLid else { return "On · the screen still turns off" }
        if !keepAwake.lidCloseHeld { return "On while the lid is open" }
        if keepAwake.batteryAutoOff, !keepAwake.battery.isOnAC { return "On, lid closed too · turns off at \(keepAwake.batteryAutoOffThreshold)%" }
        return "On, even with the lid closed"
    }

    private var awakeReason: String? {
        if keepAwake.blockedReason != nil {
            if keepAwake.blockedByBattery {
                return "Battery at \(keepAwake.battery.percent)%: plug in, or lower the \(keepAwake.batteryAutoOffThreshold)% limit."
            }
            return "The Mac is running \(KeepAwakeController.describe(keepAwake.thermal)): let it cool down, or turn off the heat limit."
        }
        if lidNotHeld { return "Closing the lid still sleeps the Mac until you allow Passthrough's helper." }
        return nil
    }

    private func setAwake(_ on: Bool) -> Bool {
        if !on, session.sleepWarning != nil {
            askingSleep = true
            return false
        }
        askingSleep = false
        keepAwake.set(on)
        return keepAwake.isOn == on
    }

    // MARK: VPN

    private var vpn: some View {
        let v = vpnLayer.status
        return SwitchRow(title: "VPN", symbol: "lock.shield", status: vpnStatus, isOn: vpnLayer.isWanted,
                         busy: vpnLayer.isWanted && v.isBusy, attention: vpnLayer.isWanted && v.isFailing,
                         reason: vpnReason, set: setVPN) {
            if vpnLayer.activeProfile == nil {
                Button("Set up a VPN") { SettingsWindow.show(openSettings, tab: .vpn) }.buttonStyle(PTPillButtonStyle())
            } else if vpnLayer.error != nil {
                Button("Try again") { vpnLayer.set(true) }.buttonStyle(PTPillButtonStyle())
                Button("VPN settings") { SettingsWindow.show(openSettings, tab: .vpn) }.buttonStyle(.link)
            }
        }
        .help("Wraps everything the Mac sends in one encrypted VPN connection (WireGuard or OpenVPN), so the network only ever sees the VPN.")
    }

    private var vpnStatus: String {
        guard let profile = vpnLayer.activeProfile else { return "Off · not set up" }
        guard vpnLayer.isWanted else { return "Off · \(profile.name)" }
        let name = vpnLayer.status.name.isEmpty ? profile.name : vpnLayer.status.name
        switch vpnLayer.status.state {
        case "connected": return "On · \(name)"
        case "starting": return "Connecting to \(name)…"
        case "reconnecting", "blocked": return "Reconnecting · traffic waits until it's back"
        case "failed", "held": return "Not connected · traffic is blocked"
        default: return name
        }
    }

    private var vpnReason: String? {
        if vpnLayer.activeProfile == nil { return "Add a VPN (WireGuard, OpenVPN or NordVPN) first." }
        if let error = vpnLayer.error { return error }
        if vpnLayer.isWanted, vpnLayer.status.state == "held" { return "Passthrough stopped while the VPN was on. Turn the VPN off to let traffic through." }
        if vpnLayer.isWanted, let warning = vpnLayer.status.warning { return warning }
        return nil
    }

    private func setVPN(_ on: Bool) -> Bool {
        guard vpnLayer.activeProfile != nil else {
            SettingsWindow.show(openSettings, tab: .vpn)
            return false
        }
        vpnLayer.set(on)
        return vpnLayer.isWanted == on
    }
}

/// One switch: icon, name, a one-line status and a real on/off switch. When
/// a tap can't take, the switch snaps back and the reason under it flashes,
/// so no tap goes unanswered.
struct SwitchRow<Fix: View, Below: View>: View {
    let title: String
    let symbol: String
    let status: String
    let isOn: Bool
    var busy = false
    /// On but not working (a VPN blocking traffic): amber.
    var attention = false
    /// Why it's off (or not working), and what fixes it.
    var reason: String?
    /// Asks for `on`; false when that couldn't happen.
    let set: (Bool) -> Bool
    @ViewBuilder var fix: () -> Fix
    @ViewBuilder var below: () -> Below
    /// A tap that didn't take: the reason flashes.
    @State private var flash = false

    init(title: String, symbol: String, status: String, isOn: Bool, busy: Bool = false, attention: Bool = false, reason: String?,
         set: @escaping (Bool) -> Bool, @ViewBuilder fix: @escaping () -> Fix, @ViewBuilder below: @escaping () -> Below = { EmptyView() }) {
        self.title = title; self.symbol = symbol; self.status = status; self.isOn = isOn
        self.busy = busy; self.attention = attention; self.reason = reason; self.set = set; self.fix = fix; self.below = below
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: attention ? "exclamationmark.triangle.fill" : symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(attention ? PTColor.onAttention : isOn ? PTColor.onTint : Color.secondary)
                    .frame(width: 30, height: 30)
                    .background(attention ? PTColor.attention : isOn ? PTColor.tint : Color.primary.opacity(0.07), in: Circle())
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Text(status).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .contentTransition(.opacity)
                }
                Spacer(minLength: 6)
                if busy { ProgressView().controlSize(.small) }
                Toggle(isOn: Binding(get: { isOn }, set: tap)) { EmptyView() }
                    .toggleStyle(MintSwitchStyle(fill: attention ? PTColor.attention : PTColor.tint))
                    .accessibilityLabel(title)
            }
            if let reason {
                VStack(alignment: .leading, spacing: 7) {
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(PTColor.attentionText)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 10) { fix() }.font(.caption)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(PTColor.attention.opacity(flash ? 0.32 : 0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .transition(.opacity)
            }
            below()
        }
        .padding(10)
        .animation(.easeOut(duration: 0.2), value: reason)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(title), \(status)")
    }

    private func tap(_ on: Bool) {
        guard !set(on) else { return }
        withAnimation(.easeOut(duration: 0.15)) { flash = true }
        withAnimation(.easeOut(duration: 0.6).delay(0.3)) { flash = false }
    }
}

/// An on/off switch drawn in the app's mint: unmistakable at a glance, and
/// the same in a window that isn't key (a native switch greys out there).
/// It only ever shows the bound value, so a refused tap leaves it where it was.
struct MintSwitchStyle: ToggleStyle {
    var small = false
    /// Amber for on but not working.
    var fill = PTColor.tint

    func makeBody(configuration: Configuration) -> some View {
        let size = small ? CGSize(width: 26, height: 15) : CGSize(width: 36, height: 21)
        HStack(spacing: 6) {
            configuration.label
            Capsule()
                .fill(configuration.isOn ? fill : Color.primary.opacity(0.16))
                .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                    Circle().fill(.white).shadow(color: .black.opacity(0.25), radius: 1, y: 0.5).padding(2)
                }
                .frame(width: size.width, height: size.height)
                .animation(.easeOut(duration: 0.15), value: configuration.isOn)
        }
        .contentShape(Rectangle())
        .onTapGesture { configuration.isOn.toggle() }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isToggle)
        .accessibilityValue(configuration.isOn ? "On" : "Off")
        .accessibilityAction { configuration.isOn.toggle() }
    }
}

/// Asks before letting the Mac sleep while phones' shells run: asleep, it pauses them.
struct SleepConfirm: View {
    let warning: String
    let action: String
    let confirm: () -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(warning, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(PTColor.attentionText)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button(action, action: confirm).buttonStyle(PTPillButtonStyle())
                Button("Keep it awake", action: cancel)
                    .controlSize(.small)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PTColor.attention.opacity(0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

// MARK: - Details

/// The secondary part: the link from Mac to phone to internet, and while
/// online, speeds and the busiest apps.
struct Details: View {
    @EnvironmentObject private var session: SessionCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Details")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
            FlowCard()
            if session.phase.isConnected {
                ThroughputPanel()
                TopAppsPanel(usage: session.appUsage)
            }
        }
    }
}

// MARK: - Your phone is here

/// Shells waiting on a question, just under the header: the most urgent thing
/// in the panel. The answer is typed on the phone.
struct AskingRows: View {
    @EnvironmentObject private var shell: RemoteShellController

    var body: some View {
        let asking = shell.sessions.filter(\.isAsking)
        if !asking.isEmpty {
            VStack(spacing: 4) {
                ForEach(asking, id: \.id) { s in
                    HStack(spacing: 10) {
                        Circle().fill(PTColor.attention).frame(width: 8, height: 8).frame(width: 18)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("\(s.title) is asking").font(.system(size: 12.5, weight: .medium)).lineLimit(1).truncationMode(.middle)
                            Text(s.waiting ?? "").font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 6)
                    }
                    .padding(.horizontal, 10)
                    .frame(minHeight: 36)
                    .background(PTColor.attention.opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .help("Answer it from your phone: Passthrough shows it there.")
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }
}

/// What phones are doing on this Mac right now: someone viewing the screen
/// (with Stop), shells running, or what Remote shell still needs.
struct PhoneHereSection: View {
    @EnvironmentObject private var session: SessionCoordinator
    @EnvironmentObject private var shell: RemoteShellController
    @Environment(\.openSettings) private var openSettings
    @State private var fullDiskAccess = true

    var body: some View {
        let running = shell.sessions.filter(\.running)
        if session.remoteShellEnabled || !running.isEmpty || !shell.screenViewers.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("From your phone")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("What phones may change") { SettingsWindow.show(openSettings, tab: .remoteShell) }
                        .buttonStyle(.link)
                        .font(.system(size: 11))
                        .help("Keep awake, the VPN and the screen, for each phone: Settings ▸ Remote Shell")
                }
                .padding(.horizontal, 4)
                .padding(.bottom, 2)
                ForEach(shell.screenViewers) { viewer in
                    row(symbol: "eye", attention: false) {
                        Text("\(viewer.label) is viewing this screen").font(.system(size: 12.5, weight: .medium))
                    } trailing: {
                        Button("Stop") { shell.endScreen(for: viewer.phoneID) }
                            .controlSize(.small)
                            .help("Disconnect \(viewer.label) from the screen. Its shells stay open.")
                    }
                }
                Button { SettingsWindow.show(openSettings, tab: .remoteShell) } label: {
                    row(symbol: "apple.terminal", symbolColor: shellNeedsSetup ? .secondary : PTColor.tintText, attention: shellNeedsSetup) {
                        Text(shellStatus(open: running.count)).font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(shellNeedsSetup ? PTColor.attentionText : .primary)
                    } trailing: {
                        Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                            .foregroundStyle(shellNeedsSetup ? PTColor.attentionText : .secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(PanelRowButtonStyle(attention: shellNeedsSetup))
                .help("Open Remote Shell settings")
            }
            .task { fullDiskAccess = FullDiskAccess.isGranted }
        }
    }

    private var shellNeedsSetup: Bool {
        shell.sessions.allSatisfy { !$0.running } && (shell.listenerError != nil || shell.phones.isEmpty || !fullDiskAccess)
    }

    private func shellStatus(open: Int) -> String {
        if open > 0 { return open == 1 ? "1 shell running" : "\(open) shells running" }
        if shell.listenerError != nil { return "Remote shell isn't running. Open settings to see why." }
        if shell.phones.isEmpty { return "Plug in a paired phone to give it shell access" }
        if !fullDiskAccess { return "Remote shell ready · Full Disk Access recommended" }
        return "Remote shell ready for \(shell.phones.count) phone\(shell.phones.count == 1 ? "" : "s")"
    }

    private func row<Content: View, Trailing: View>(symbol: String, symbolColor: Color = .secondary, attention: Bool,
                                                    @ViewBuilder content: () -> Content,
                                                    @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 12, weight: .semibold)).foregroundStyle(symbolColor)
                .frame(width: 18)
            content()
            Spacer(minLength: 6)
            trailing()
        }
        .padding(.horizontal, 10)
        .frame(minHeight: 36)
        .background(attention ? PTColor.attention.opacity(0.1) : Color.clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// A panel row that opens something. On the bare panel it would read as a label, so it gets
/// a card like the switches above it, and lights up mint under the pointer and when pressed.
/// A row that needs setup keeps its amber fill instead.
private struct PanelRowButtonStyle: ButtonStyle {
    var attention: Bool

    func makeBody(configuration: Configuration) -> some View {
        RowBody(configuration: configuration, attention: attention)
    }

    private struct RowBody: View {
        let configuration: ButtonStyleConfiguration
        let attention: Bool
        @State private var hovering = false

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
            configuration.label
                .background(fill, in: shape)
                .overlay(shape.strokeBorder(attention ? Color.clear : PTColor.hairline, lineWidth: 1))
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.12), value: hovering)
        }

        private var fill: Color {
            if attention { return configuration.isPressed ? PTColor.attention.opacity(0.12) : .clear }
            if configuration.isPressed { return PTColor.surfaceOn.opacity(0.7) }
            return hovering ? PTColor.surfaceOn : PTColor.surface
        }
    }
}

/// Live picture of the route traffic takes right now.
struct FlowCard: View {
    @EnvironmentObject private var session: SessionCoordinator
    @EnvironmentObject private var vpnLayer: VPNLayer
    @EnvironmentObject private var keepAwake: KeepAwakeController

    private var flowState: FlowMapState {
        var vpn: FlowMapState.VPN?
        if vpnLayer.isWanted {
            let v = vpnLayer.status
            vpn = FlowMapState.VPN(name: v.name.isEmpty ? (vpnLayer.activeProfile?.name ?? "VPN") : v.name,
                                   engine: v.engineLabel.isEmpty ? (vpnLayer.activeProfile?.engine.label ?? "VPN") : v.engineLabel,
                                   connected: v.isConnected, blocked: v.isBlocking)
        }
        // VPN with passthrough off: it rides the Mac's own network.
        let viaWiFi = vpnLayer.isWanted && !session.phase.isConnected && !session.phase.isBusy
        let localName = vpnLayer.status.underlay.map { $0 == "iPhone" ? "Wi-Fi" : $0 } ?? "Wi-Fi"
        return FlowMapState(perspective: .mac, macName: session.macName, phoneName: session.phoneStatus?.deviceName ?? session.phoneKindName,
                            phoneIcon: session.device?.kind == .android ? "smartphone" : "iphone.gen3",
                            linkUp: session.phase.isConnected || (viaWiFi && vpnLayer.status.isConnected),
                            busy: session.phase.isBusy || (viaWiFi && vpnLayer.status.isBusy),
                            radio: viaWiFi ? nil : session.phoneStatus?.radio,
                            vpn: vpn, keepAwake: keepAwake.isOn, downRate: session.meter.downRate, upRate: session.meter.upRate,
                            activeConnections: session.phoneActiveConnections, viaWiFi: viaWiFi, localNetworkName: localName,
                            wireless: session.device.map { $0.medium == .wireless } ?? (session.connectionMode == .wireless),
                            wirelessCarrier: session.wirelessCarrier)
    }

    var body: some View {
        PTSurface(padding: 8) {
            FlowMap(state: flowState, height: 84, active: session.panelVisible)
        }
    }
}

/// Throughput readouts and chart.
struct ThroughputPanel: View {
    @EnvironmentObject private var session: SessionCoordinator

    var body: some View {
        PTSurface(padding: 14) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    RateReadout(session.meter.downRate, direction: .down, size: 24)
                    Spacer()
                    RateReadout(session.meter.upRate, direction: .up, size: 24)
                }
                ThroughputChart(samples: session.meter.history, height: 72)
                HStack {
                    StatCell("Down", value: ByteFormat.bytes(session.sessionRx), tint: PTTheme.down)
                    StatCell("Up", value: ByteFormat.bytes(session.sessionTx), tint: PTTheme.up)
                    StatCell("Peak", value: ByteFormat.rate(session.meter.peakRate).value + " " + ByteFormat.rate(session.meter.peakRate).unit)
                }
            }
        }
    }
}

/// The apps moving the most data through the tunnel this session.
struct TopAppsPanel: View {
    @EnvironmentObject private var session: SessionCoordinator
    @EnvironmentObject private var vpnLayer: VPNLayer
    @ObservedObject var usage: NettopSampler

    var body: some View {
        if session.phase.isConnected, usage.unavailable || !usage.top.isEmpty {
            PTSurface(padding: 14) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Top apps this session").font(.caption).foregroundStyle(.secondary)
                    if usage.unavailable {
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill").font(.caption2)
                            Text("Per-app usage unavailable: nettop isn't running").font(.caption2)
                            Spacer(minLength: 0)
                        }
                        .foregroundStyle(PTColor.attentionText)
                    } else {
                        let shown = usage.breakdown(sessionTotal: session.sessionRx + session.sessionTx)
                        ForEach(shown.top, id: \.app.key) { entry in
                            row(Image(nsImage: AppIcon.image(forKey: entry.app.key)), entry.app.name, entry.total)
                        }
                        if shown.other > 0 {
                            row(Image(systemName: "ellipsis.circle"),
                                vpnLayer.status.isConnected ? "Other (short connections, VPN overhead)" : "Other (short connections)", shown.other, lines: 2)
                        }
                    }
                }
            }
        }
    }

    private func row(_ icon: Image, _ name: String, _ bytes: Int64, lines: Int = 1) -> some View {
        HStack(spacing: 8) {
            icon.resizable().aspectRatio(contentMode: .fit).frame(width: 16, height: 16)
            Text(name).lineLimit(lines).truncationMode(.middle)
            Spacer(minLength: 8)
            Text(ByteFormat.bytes(bytes)).font(PTTheme.mono(12)).foregroundStyle(.secondary)
        }
        .font(.callout)
    }
}

/// Six-box code entry for the first connection.
struct PairingCard: View {
    @EnvironmentObject private var session: SessionCoordinator
    @State private var code = ""
    @FocusState private var focused: Bool

    var body: some View {
        PTSurface(padding: 16) {
            VStack(spacing: 12) {
                Image(systemName: "laptopcomputer.and.iphone").font(.system(size: 28, weight: .medium)).foregroundStyle(PTColor.tintText)
                Text("Pair with \(session.phoneStatus?.deviceName ?? session.phoneKindName)").font(.headline)
                Text("On the \(session.phoneKindName), tap Pair in Passthrough and type the six digits here.")
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                ZStack {
                    PairingCodeTiles(code: code.padding(toLength: 6, withPad: " ", startingAt: 0), size: 36)
                    TextField("", text: $code)
                        .textFieldStyle(.plain)
                        .focused($focused)
                        .opacity(0.02)
                        .onChange(of: code) { _, new in
                            let digits = new.filter(\.isNumber).prefix(6)
                            if String(digits) != new { code = String(digits) }
                            if digits.count == 6 { session.submitPairingCode(String(digits)) }
                        }
                }
                .onTapGesture { focused = true }
                if session.pairingInFlight {
                    ProgressView().controlSize(.small)
                } else if let error = session.pairingError {
                    Text(error).font(.caption).foregroundStyle(PTColor.problem).multilineTextAlignment(.center)
                }
                Button("Cancel") { session.disconnect() }.buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
            }
        }
        .onAppear { focused = true; code = "" }
        .onChange(of: session.pairingError) { _, new in if new != nil { code = "" } }
    }
}
