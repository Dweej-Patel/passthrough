import SwiftUI
import ShellHost
import PassthroughCore
import PassthroughUI

/// The panel's two tabs: this Mac's own switches and link, and who else is on
/// this Mac or reachable from it.
enum PanelTab: String {
    case thisMac, remote
    static let storageKey = "menuPanelTab"
}

/// The menu bar panel, read top to bottom: what the Mac is doing, anything
/// that needs you now (a shell asking, someone viewing the screen), then two
/// tabs. This Mac: the three switches (each saying why when it can't turn on,
/// and what fixes it) and the details: the link, speeds, top apps. Remote: who
/// can reach this Mac, what phones and computers have open here, and the
/// computers this Mac can reach.
struct MenuPanelView: View {
    @EnvironmentObject private var session: SessionCoordinator
    @EnvironmentObject private var keepAwake: KeepAwakeController
    @EnvironmentObject private var vpnLayer: VPNLayer
    @EnvironmentObject private var shell: RemoteShellController
    @Environment(\.openSettings) private var openSettings
    /// Kept across openings of the panel. Nothing switches it but a click (and a
    /// pairing code to type): what needs you now sits above the tabs instead.
    @AppStorage(PanelTab.storageKey) private var tab = PanelTab.thisMac

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
            // Someone seeing this screen is never behind a tab.
            ScreenViewerRows()
            PanelTabPicker(tab: $tab, remoteCount: remoteCount,
                           remoteAttention: session.remoteShellEnabled && shell.listenerError != nil)
            ScrollView {
                VStack(spacing: 12) {
                    switch tab {
                    case .thisMac: ThisMacTab()
                    case .remote: RemoteTab()
                    }
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
        // The pairing code is typed on This Mac: a phone waiting on it brings that tab forward.
        .onAppear { if session.phase == .pairingRequired { tab = .thisMac } }
        .onChange(of: session.phase == .pairingRequired) { _, needed in if needed { tab = .thisMac } }
    }

    /// Phones and computers on this Mac now: each one viewing the screen or
    /// with a shell of its own running, counted once by the id it connected
    /// with. A phone attached to one of this Mac's own terminals counts when
    /// nothing else does.
    private var remoteCount: Int {
        var who = Set(shell.screenViewers.map(\.phoneID))
        var attached = false
        for terminal in shell.terminals {
            switch terminal.origin {
            case .phone: who.insert(terminal.openedBy ?? "session \(terminal.id)")
            case .mac: attached = attached || terminal.phoneAttached
            }
        }
        return who.count + (who.isEmpty && attached ? 1 : 0)
    }

    /// The middle of the panel scrolls once it's taller than the screen leaves
    /// room for, under the header and above the footer.
    @State private var bodyHeight: CGFloat = 600
    private var maxBodyHeight: CGFloat { max(240, (NSScreen.screens.first?.visibleFrame.height ?? 800) - 150) }

    // MARK: Header

    private var phoneName: String { session.phoneStatus?.deviceName ?? session.phoneKindName }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: session.device?.kind == .android ? "smartphone" : session.device?.kind == .iPad ? "ipad" : "iphone.gen3")
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
        default:
            // An iPad never carries the Mac's internet; say which iPhone it uses.
            if session.device?.kind == .iPad, let from = session.phoneStatus?.internetFrom {
                return "\(phoneName) gets its internet from \(from)"
            }
            return vpnOn ? "VPN on, over this Mac's own network" : "This Mac is on its own network"
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
            // The whole row is the switch, not just the small capsule. The
            // capsule's own tap wins over this one, so it never fires twice.
            .contentShape(Rectangle())
            .onTapGesture { tap(!isOn) }
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

/// Asks before letting the Mac sleep while phones' shells run: asleep, it pauses them. Also asks
/// before ending a session from the panel.
struct SleepConfirm: View {
    let warning: String
    let action: String
    var cancelTitle = "Keep it awake"
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
                Button(cancelTitle, action: cancel)
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

// MARK: - Needs you now, and the Remote tab

/// Shells waiting on a question, just under the header: the most urgent thing
/// in the panel. The answer is typed on the phone.
struct AskingRows: View {
    @EnvironmentObject private var shell: RemoteShellController

    var body: some View {
        let asking = shell.phonesAsking
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

/// Who is seeing this screen right now, each with Stop. Above the tabs: a
/// phone or computer that can see and control this Mac is never out of sight.
struct ScreenViewerRows: View {
    @EnvironmentObject private var shell: RemoteShellController

    var body: some View {
        let viewers = shell.screenViewers
        if !viewers.isEmpty {
            VStack(spacing: 4) {
                ForEach(viewers) { viewer in
                    PanelRow(symbol: Self.symbol(viewer.phoneID), symbolColor: PTColor.tintText, fill: PTColor.surfaceOn) {
                        Text(Self.viewing(viewer))
                            .font(.system(size: 12.5, weight: .medium)).lineLimit(1).truncationMode(.middle)
                    } trailing: {
                        Button("Stop") { shell.endScreen(for: viewer.phoneID) }
                            .controlSize(.small)
                            .help("Disconnect \(viewer.label) from the screen. Its shells stay open.")
                            .accessibilityLabel("Stop \(viewer.label) viewing this screen")
                    }
                    .accessibilityElement(children: .contain)
                }
            }
        }
    }

    /// By the id it connected with, which only this Mac mints for a computer or a pass: a name
    /// alone could pass for a phone's.
    private static func symbol(_ id: String) -> String {
        if Computers.isComputerID(id) { return "desktopcomputer" }
        if ScreenPass.isViewerID(id) { return "display" }
        return "eye"
    }

    /// "Office PC (a computer) is viewing this screen".
    private static func viewing(_ viewer: RemoteShellController.ScreenViewer) -> String {
        if Computers.isComputerID(viewer.phoneID) { return "\(viewer.label) (a computer) is viewing this screen" }
        if ScreenPass.isViewerID(viewer.phoneID) { return "\(viewer.label) (a Mac with a pass) is viewing this screen" }
        return "\(viewer.label) is viewing this screen"
    }
}

/// "This Mac" and "Remote". Drawn here rather than a native segmented control,
/// which greys out in a window that isn't key, as the switches are.
struct PanelTabPicker: View {
    @Binding var tab: PanelTab
    /// Phones and computers on this Mac now; shown on Remote when there are any.
    let remoteCount: Int
    /// Remote shell is on but not running: an amber dot on Remote, whichever tab is showing.
    var remoteAttention = false

    var body: some View {
        HStack(spacing: 2) {
            segment(.thisMac, title: "This Mac", spoken: "This Mac")
            segment(.remote, title: remoteCount > 0 ? "Remote · \(remoteCount)" : "Remote",
                    spoken: (remoteCount > 0 ? "Remote, \(remoteCount) on this Mac now" : "Remote")
                        + (remoteAttention ? ", remote shell isn't running" : ""),
                    dot: remoteAttention)
        }
        .padding(2)
        .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .accessibilityElement(children: .contain)
    }

    private func segment(_ value: PanelTab, title: String, spoken: String, dot: Bool = false) -> some View {
        let selected = tab == value
        return Button { tab = value } label: {
            HStack(spacing: 5) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                if dot { Circle().fill(PTColor.attention).frame(width: 6, height: 6) }
            }
            .foregroundStyle(selected ? Color.primary : Color.secondary)
            .frame(maxWidth: .infinity, minHeight: 24)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(PTColor.surface)
                        .shadow(color: .black.opacity(0.12), radius: 1, y: 0.5)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(spoken)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// This Mac's own: pairing a phone or an iPad, the three switches, and the details.
struct ThisMacTab: View {
    @EnvironmentObject private var session: SessionCoordinator

    var body: some View {
        if session.phase == .pairingRequired { PairingCard() }
        if session.pairingIPadID == nil, let iPad = session.unpairedIPad, session.device?.id != iPad.id || session.phase != .pairingRequired {
            UnpairedIPadRow()
        }
        Switches()
        Details()
    }
}

/// Who can reach this Mac, what phones and computers have open on it now, and
/// the computers this Mac can reach in turn.
struct RemoteTab: View {
    var body: some View {
        ReachSection()
        OnThisMacSection()
        YourComputersSection()
    }
}

/// A small grey heading over a group of rows.
private struct PanelSectionTitle: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
    }
}

/// One row of the panel's lists: a glyph, what it is, and what to do about it.
private struct PanelRow<Content: View, Trailing: View>: View {
    let symbol: String
    var symbolColor: Color = .secondary
    var fill: Color = .clear
    @ViewBuilder var content: Content
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 12, weight: .semibold)).foregroundStyle(symbolColor)
                .frame(width: 18)
                .accessibilityHidden(true)
            content
            Spacer(minLength: 6)
            trailing
        }
        .padding(.horizontal, 10)
        .frame(minHeight: 36)
        .background(fill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// A row's two lines: what it is, and its state, as text (amber when it needs someone).
private struct RowText: View {
    let title: String
    let detail: String
    var attention = false

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.system(size: 12.5, weight: .medium)).lineLimit(1).truncationMode(.middle)
            Text(detail).font(.system(size: 10.5))
                .foregroundStyle(attention ? PTColor.attentionText : .secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: Who can reach this Mac

/// One row saying whether Remote shell is on, how many phones and computers
/// have access, and from where; it opens the Remote Shell settings, where
/// each is listed. With Remote shell off it is the way to turn it on.
private struct ReachSection: View {
    @EnvironmentObject private var session: SessionCoordinator
    @EnvironmentObject private var shell: RemoteShellController
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        let attention = session.remoteShellEnabled && shell.listenerError != nil
        VStack(alignment: .leading, spacing: 4) {
            PanelSectionTitle("Who can reach this Mac")
            Button { SettingsWindow.show(openSettings, tab: .remoteShell) } label: {
                PanelRow(symbol: symbol, symbolColor: attention ? PTColor.attentionText : session.remoteShellEnabled ? PTColor.tintText : .secondary) {
                    RowText(title: title, detail: detail, attention: attention)
                } trailing: {
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                        .foregroundStyle(attention ? PTColor.attentionText : .secondary)
                        .accessibilityHidden(true)
                }
                .padding(.vertical, 3)
                .contentShape(Rectangle())
            }
            .buttonStyle(PanelRowButtonStyle(attention: attention))
            .help("Open Remote Shell settings: each phone and computer with access, and what it may do")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(title). \(detail)")
            .accessibilityHint("Opens Remote Shell settings")
            .accessibilityAddTraits(.isButton)
        }
    }

    private var symbol: String { session.remoteShellEnabled ? "network" : "network.slash" }

    private var title: String {
        guard session.remoteShellEnabled else { return "Remote shell is off" }
        return shell.listenerError != nil ? "Remote shell isn't running" : "Remote shell is on"
    }

    private var detail: String {
        guard session.remoteShellEnabled else { return "Turn it on in Settings to reach this Mac from your phones." }
        if shell.listenerError != nil { return "Open Settings to see why." }
        let phones = shell.phones.count, computers = shell.computerGuests.count
        guard phones + computers > 0 else { return "No phones yet · plug in a paired phone to give it access" }
        var who = [phones == 1 ? "1 phone" : "\(phones) phones"]
        if computers > 0 { who.append(computers == 1 ? "1 computer" : "\(computers) computers") }
        return who.joined(separator: ", ") + " · " + reach
    }

    /// From where, as it is now: the iroh endpoint only counts once it runs.
    private var reach: String {
        guard shell.reachAnywhere else { return "same Wi-Fi or Tailscale only" }
        switch shell.irohStatus.state {
        case .running: return "reachable from anywhere"
        case .starting: return "starting reach from anywhere"
        case .failed: return "same Wi-Fi or Tailscale · reach from anywhere failed"
        case .off: return "same Wi-Fi or Tailscale"
        }
    }
}

// MARK: On this Mac now

/// What phones and computers have running on this Mac: each session, by who
/// opened it, with the way to it from here, and a line for what Remote shell
/// still needs. Who is viewing the screen is above the tabs.
private struct OnThisMacSection: View {
    @EnvironmentObject private var session: SessionCoordinator
    @EnvironmentObject private var shell: RemoteShellController
    @Environment(\.openSettings) private var openSettings
    @State private var fullDiskAccess = true

    var body: some View {
        let running = shell.sessions.filter(\.running)
        if session.remoteShellEnabled || !running.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                PanelSectionTitle("On this Mac now").padding(.bottom, 2)
                // Each running session, with the way to it from here: a phone's
                // shell opens in a terminal window, beside the phone.
                ForEach(shell.terminals.prefix(Self.sessionRows)) { terminal in
                    SessionRow(terminal: terminal)
                }
                statusLine(open: running.count)
            }
            .task { fullDiskAccess = FullDiskAccess.isGranted }
        }
    }

    /// Most sessions listed one by one; the row under them counts them all.
    private static let sessionRows = 5

    private func statusLine(open: Int) -> some View {
        Button { SettingsWindow.show(openSettings, tab: .remoteShell) } label: {
            PanelRow(symbol: "apple.terminal", symbolColor: needsSetup ? .secondary : PTColor.tintText,
                     fill: needsSetup ? PTColor.attention.opacity(0.1) : .clear) {
                Text(shellStatus(open: open)).font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(needsSetup ? PTColor.attentionText : .primary)
            } trailing: {
                Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                    .foregroundStyle(needsSetup ? PTColor.attentionText : .secondary)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PanelRowButtonStyle(attention: needsSetup))
        .help("Open Remote Shell settings")
        .accessibilityHint("Opens Remote Shell settings")
    }

    /// Full Disk Access is the one thing left to set up that this line says;
    /// a listener that failed, or no phones yet, is in the row above.
    private var needsSetup: Bool {
        !shell.sessions.contains { $0.running && shell.isPhones($0) } && session.remoteShellEnabled && !fullDiskAccess
    }

    private func shellStatus(open: Int) -> String {
        if open > 0 { return open == 1 ? "1 shell running" : "\(open) shells running" }
        if session.remoteShellEnabled, !fullDiskAccess { return "No shells running · Full Disk Access recommended" }
        return "No shells running"
    }
}

/// One running session: its title, who opened it (a phone or a computer, by
/// name once its recording says), Open here or Stop Showing Here, and End
/// (asked first, under the row).
private struct SessionRow: View {
    @EnvironmentObject private var shell: RemoteShellController
    let terminal: ShellSessionDetail
    @State private var ending = false

    var body: some View {
        VStack(spacing: 4) {
            row
            if ending {
                SleepConfirm(warning: "End \(terminal.info.title)? The shell and anything running in it close, as when you close a Terminal window. Its recording is kept.",
                             action: "End Session", cancelTitle: "Keep it running") {
                    ending = false
                    shell.close(terminal.id)
                } cancel: { ending = false }
            }
        }
    }

    private var row: some View {
        let opener = shell.opener(of: terminal)
        return PanelRow(symbol: symbol(opener)) {
            RowText(title: terminal.info.title, detail: place(opener))
        } trailing: {
            HStack(spacing: 6) {
                if terminal.macViewers == 0 {
                    Button("Open here") { shell.openInTerminal(terminal.id) }
                        .controlSize(.small)
                        .help("Show this session in a terminal window on this Mac. Whoever is attached to it keeps it too.")
                        .accessibilityLabel("Open \(terminal.info.title) in a terminal here")
                } else {
                    if terminal.phoneAttached {
                        Image(systemName: "dot.radiowaves.left.and.right").font(.caption.weight(.semibold)).foregroundStyle(PTColor.tintText)
                            .help("\(someone.capitalizedFirst) is looking at this terminal")
                            .accessibilityLabel("\(someone.capitalizedFirst) is attached")
                    }
                    // A phone's or computer's session shown here: take it off this Mac's windows at any time.
                    if terminal.origin == .phone {
                        Button("Stop Showing Here") { shell.stopShowingHere(terminal.id) }
                            .controlSize(.small)
                            .help("Stop showing this session in terminal windows here. It keeps running for whoever opened it.")
                            .accessibilityLabel("Stop showing \(terminal.info.title) here")
                    }
                }
                endMenu
            }
        }
        .accessibilityElement(children: .contain)
    }

    /// Ending the session is apart from the buttons beside it: those only change where it shows.
    private var endMenu: some View {
        Menu {
            Button("End Session…") { ending = true }
        } label: {
            Image(systemName: "ellipsis.circle").font(.system(size: 12, weight: .semibold))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .foregroundStyle(.secondary)
        .help("End this session")
        .accessibilityLabel("More for \(terminal.info.title)")
    }

    /// Whoever an attachment may be: a computer may attach too, once one has access.
    private var someone: String { shell.computerGuests.isEmpty ? "a phone" : "a phone or computer" }

    private func symbol(_ opener: RemoteShellController.SessionOpener?) -> String {
        guard terminal.origin == .phone else { return "macwindow" }
        switch opener?.isComputer {
        case true?: return "desktopcomputer"
        case false?: return "iphone"
        case nil: return "apple.terminal"
        }
    }

    /// "From Dweej's iPhone", "From Office PC · open here too", "In a terminal here · a phone is attached".
    private func place(_ opener: RemoteShellController.SessionOpener?) -> String {
        let place: String
        switch terminal.origin {
        case .mac: place = "In a terminal here"
        case .phone:
            let from = opener.map { "From \($0.name)" } ?? "From \(someone)"
            place = terminal.macViewers > 0 ? from + " · open here too" : from
        }
        return terminal.phoneAttached ? place + " · \(someone) is attached" : place
    }
}

private extension String {
    /// "A phone", for the start of a sentence.
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

// MARK: Your computers

/// The computers this Mac can reach, one click from their screen: other Macs
/// (passes a phone handed over) and PCs (access a phone handed over, with the
/// screen). Each says what it is and whether its screen is ready.
private struct YourComputersSection: View {
    @EnvironmentObject private var shell: RemoteShellController

    /// One row: a pass to a Mac's screen, or access to a PC.
    enum Item: Identifiable {
        case mac(ReceivedScreenPass)
        case pc(ReachableComputer)

        var id: String {
            switch self {
            case .mac(let pass): "mac \(pass.id)"
            case .pc(let computer): "pc \(computer.id)"
            }
        }

        var receivedAt: Date {
            switch self {
            case .mac(let pass): pass.receivedAt
            case .pc(let computer): computer.receivedAt
            }
        }
    }

    /// Newest first, as each list is.
    private var items: [Item] {
        let macs = shell.screenPasses.map(Item.mac)
        let pcs = shell.reachableComputers.filter(\.mayAskForScreen).map(Item.pc)
        return (macs + pcs).sorted { $0.receivedAt > $1.receivedAt }
    }

    var body: some View {
        let items = self.items
        VStack(alignment: .leading, spacing: 4) {
            PanelSectionTitle("Your computers")
            if items.isEmpty {
                // Where the list comes from, so the heading doesn't vanish without a word.
                Text("None yet. Share one from your phone: Share with another computer…")
                    .font(.system(size: 10.5)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
            }
            ForEach(items) { ComputerRow(item: $0) }
        }
    }
}

/// "View Office PC's screen" over "PC · ready · from Dweej's iPhone"; opens that screen's window.
private struct ComputerRow: View {
    @Environment(\.openWindow) private var openWindow
    let item: YourComputersSection.Item

    var body: some View {
        Button(action: open) {
            PanelRow(symbol: symbol) {
                RowText(title: "View \(name)'s screen", detail: state, attention: waiting)
            } trailing: {
                Image(systemName: "arrow.up.forward.app").font(.system(size: 11)).foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(PanelRowButtonStyle(attention: false))
        .help(help)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("View \(name)'s screen. \(state)")
        .accessibilityAddTraits(.isButton)
    }

    private func open() {
        switch item {
        case .mac(let pass): openWindow(id: RemoteScreenWindow.id, value: pass.id)
        case .pc(let computer): openWindow(id: PCScreenWindow.id, value: computer.id)
        }
        NSApp.activate()
    }

    private var name: String {
        switch item {
        case .mac(let pass): pass.macName
        case .pc(let computer): computer.credential.macName
        }
    }

    private var symbol: String {
        switch item {
        case .mac: "display"
        case .pc: "pc"
        }
    }

    /// The hand-over said the PC's owner still had to allow the screen; only the PC knows whether they have since.
    private var waiting: Bool {
        if case .pc(let computer) = item { return computer.screenWaitsForOwner }
        return false
    }

    private var state: String {
        switch item {
        case .mac(let pass):
            return "Mac · screen pass · from \(pass.from)"
        case .pc(let computer):
            let kind = computer.kindName
            if computer.screenWaitsForOwner { return "\(kind) · waiting for its owner to allow the screen" }
            return "\(kind) · ready" + (computer.from.map { " · from \($0)" } ?? "")
        }
    }

    private var help: String {
        switch item {
        case .mac(let pass):
            return "Open \(pass.macName)'s screen in a window. Handed over by \(pass.from)."
        case .pc(let computer):
            return "Open \(computer.credential.macName)'s screen in a window." + (computer.from.map { " Handed over by \($0)." } ?? "")
                + (computer.screenWaitsForOwner ? " Its owner has to allow the screen at the PC first." : "")
        }
    }
}

/// A panel row that opens something. On the bare panel it would read as a label, so it gets
/// a card like the switches above it, and lights up mint under the pointer and when pressed.
/// A row that needs setup keeps its amber fill, a shade deeper under the pointer.
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
            if attention { return PTColor.attention.opacity(configuration.isPressed ? 0.14 : hovering ? 0.08 : 0) }
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
                            phoneIcon: session.device?.kind == .android ? "smartphone" : session.device?.kind == .iPad ? "ipad" : "iphone.gen3",
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
/// An iPad on the cable that isn't paired: the Mac is busy with the phone (it
/// holds one control channel), so pairing the iPad is something to ask for.
struct UnpairedIPadRow: View {
    @EnvironmentObject private var session: SessionCoordinator

    var body: some View {
        PTSurface(padding: 12) {
            HStack(spacing: 10) {
                Image(systemName: "ipad").font(.system(size: 18, weight: .medium)).foregroundStyle(PTColor.tintText)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text("An iPad is plugged in").font(.subheadline.weight(.semibold))
                    Text(session.remoteShellEnabled
                         ? "Pair it to use it as this Mac's remote. \(session.phase.isConnected ? "Internet through the phone pauses for a moment." : "")"
                         : "Turn on Remote shell in Settings to pair it as this Mac's remote.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 6)
                if session.remoteShellEnabled {
                    Button("Pair iPad") { session.pairIPad() }.buttonStyle(PTPillButtonStyle())
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

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
                Button("Cancel") { session.pairingIPadID != nil ? session.cancelPairingIPad() : session.disconnect() }
                    .buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
            }
        }
        .onAppear { focused = true; code = "" }
        .onChange(of: session.pairingError) { _, new in if new != nil { code = "" } }
    }
}
