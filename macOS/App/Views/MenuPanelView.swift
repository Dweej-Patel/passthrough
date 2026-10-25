import SwiftUI
import PassthroughCore
import PassthroughUI

/// The menu bar panel: where the Mac is (Desk, Away, Public), its three
/// switches, the route, what your phone is doing here, and a nudge before
/// you head out. Pairing and the helper take the place of the moments when needed.
struct MenuPanelView: View {
    @EnvironmentObject private var session: SessionCoordinator
    @EnvironmentObject private var keepAwake: KeepAwakeController
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
                    switch session.phase {
                    case .helperRequired: HelperCard()
                    case .pairingRequired: PairingCard()
                    default: EmptyView()
                    }
                    MacMoments()
                    ModuleTiles()
                    FlowCard()
                    if session.phase.isConnected {
                        ThroughputPanel()
                        TopAppsPanel(usage: session.appUsage)
                    }
                    PhoneHereSection()
                    HeadingOutTip()
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
    private var maxBodyHeight: CGFloat { max(240, (NSScreen.screens.first?.visibleFrame.height ?? 800) - 190) }

    // MARK: Header

    private var phoneName: String { session.phoneStatus?.deviceName ?? session.phoneKindName }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
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
            if !session.phase.isConnected, !session.phase.isBusy, session.phase != .helperRequired, session.phase != .pairingRequired {
                Text(hint).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var title: String {
        switch session.phase {
        case .connected: return "Online through \(phoneName)"
        case .connecting: return "Connecting…"
        case .deviceFound: return "\(phoneName) is here"
        case .helperRequired: return "Helper needs approval"
        case .pairingRequired: return "Pair with \(phoneName)"
        case .error: return "Not connected"
        case .noDevice: return session.connectionMode == .wireless ? "Waiting for the phone" : "No phone plugged in"
        }
    }

    /// "USB · 5G · phone 83%" while connected; otherwise what's happening.
    private var subtitle: String {
        guard session.phase.isConnected else { return statusLine }
        var parts = [session.linkName.replacingOccurrences(of: "over ", with: "")]
        if let radio = session.phoneStatus?.radio { parts.append(radio) }
        if let battery = session.phoneStatus?.battery { parts.append("phone \(MacFormat.percent(battery))") }
        return parts.joined(separator: " · ")
    }

    private var statusLine: String {
        switch session.phase {
        case .noDevice: return session.connectionMode == .wireless ? "Looking for a linked phone nearby" : "Plug an iPhone or Android phone into USB"
        case .deviceFound: return "Ready to connect \(session.linkName)"
        case .helperRequired: return "Helper needs approval"
        case .connecting(let step): return step
        case .pairingRequired: return "Enter the code from the \(session.phoneKindName)"
        case .connected:
            let n = session.phoneActiveConnections
            return "Online \(session.linkName) · \(n) open connection\(n == 1 ? "" : "s")"
        case .error(let message): return message
        }
    }

    private var hint: String {
        switch session.phase {
        case .connected:
            if session.phoneStatus?.radio == "Wi-Fi" {
                return "The \(session.phoneKindName) is on Wi-Fi, so this Mac uses its Wi-Fi, not cellular. Turn off Wi-Fi on the phone to use cellular."
            }
            if let iface = session.tunnelInterface, let d = session.sessionDuration {
                return "All traffic routes through \(iface) for \(ByteFormat.duration(d))."
            }
            return "All traffic routes through the \(session.phoneKindName)."
        case .connecting: return "Setting up the link and routing. Open connections will switch over."
        case .error(let message): return message
        case .noDevice:
            if session.connectionMode == .wireless {
                return "Turn on Wireless link in Passthrough on the phone and keep it nearby. A phone links the first time it connects over USB."
            }
            return session.androidHint ?? "Connect the cable and unlock the phone. Trust this Mac if asked; Android phones need USB debugging on."
        default: return session.hasToken ? "Flip the switch to route this Mac through the \(session.phoneKindName)." : "First connection will ask for a pairing code."
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 10) {
            Text(macHealth).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Spacer()
            Toggle("Auto-connect", isOn: $session.autoConnect)
                .toggleStyle(.switch).controlSize(.mini)
                .font(.caption)
                .help("Connect as soon as a phone is plugged in")
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

// MARK: - Moments

/// Desk, Away and Public, as on the phone: read off the switches (so a change
/// from either side shows on both), and set together through the coordinator
/// (`SessionCoordinator.apply(_:)`). At the Mac itself, turning the VPN off
/// needs no Face ID; letting it sleep with shells running asks first.
struct MacMoments: View {
    @EnvironmentObject private var session: SessionCoordinator
    @EnvironmentObject private var vpnLayer: VPNLayer
    @EnvironmentObject private var keepAwake: KeepAwakeController
    @EnvironmentObject private var shell: RemoteShellController
    @Environment(\.openSettings) private var openSettings
    /// A moment that lets the Mac sleep with shells running, waiting on "Switch".
    @State private var asking: Moment?

    var body: some View {
        let current = session.currentMoment
        let shown = session.pendingMoment ?? current
        VStack(alignment: .leading, spacing: 6) {
            Picker("Moment", selection: Binding(get: { shown }, set: { pick($0) })) {
                ForEach(Moment.choices) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            if let moment = asking, let warning = session.sleepWarning {
                SleepConfirm(warning: warning, action: "Switch to \(moment.title)") {
                    asking = nil
                    apply(moment)
                } cancel: { asking = nil }
            } else {
                Text(session.momentNote ?? shown.caption(phone: "the phone", fromAnywhere: shell.reachAnywhere))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .contentTransition(.opacity)
            }
        }
        .onChange(of: current) { _, now in
            if now == session.pendingMoment { session.pendingMoment = nil } else if session.pendingMoment == nil { session.momentNote = nil }
        }
    }

    private func pick(_ moment: Moment) {
        asking = nil
        if session.plan(moment)?.letsSleep == true, session.sleepWarning != nil { return asking = moment }
        apply(moment)
    }

    private func apply(_ moment: Moment) {
        if !session.apply(moment) { SettingsWindow.show(openSettings, tab: .vpn) }
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
                Button("Cancel", action: cancel)
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

// MARK: - The three switches

struct ModuleTiles: View {
    @EnvironmentObject private var session: SessionCoordinator
    @EnvironmentObject private var vpnLayer: VPNLayer
    @EnvironmentObject private var keepAwake: KeepAwakeController
    @Environment(\.openSettings) private var openSettings
    /// Keep awake turning off with shells running, waiting on "Turn off".
    @State private var askingSleep = false

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                ModuleTile(title: "Internet", detail: internetDetail, symbol: "wifi",
                           on: session.phase.isConnected, busy: session.phase.isBusy) { session.toggle() }
                    .disabled(session.device == nil && !session.phase.isConnected && !session.phase.isBusy)
                    .help("Route this Mac through the phone")
                ModuleTile(title: "Keep awake", detail: awakeDetail, symbol: "cup.and.saucer",
                           on: keepAwake.isOn, warning: keepAwake.isOn && keepAwake.hasLid && !keepAwake.lidCloseHeld) { toggleAwake() }
                    .help(keepAwake.hasLid
                          ? "Keeps the Mac awake for long sessions, including with the lid closed. A closed, running Mac in a bag can overheat and drain the battery."
                          : "Keeps the Mac awake for long sessions. The screen still turns off and locks.")
                ModuleTile(title: "VPN", detail: vpnDetail, symbol: "lock.shield",
                           on: vpnLayer.isWanted, busy: vpnLayer.status.isBusy, warning: vpnLayer.isWanted && vpnLayer.status.isDown) {
                    if vpnLayer.activeProfile != nil { vpnLayer.set(!vpnLayer.isWanted) } else { SettingsWindow.show(openSettings, tab: .vpn) }
                }
                .help("Wraps everything the Mac sends in one encrypted VPN flow (WireGuard or OpenVPN), so the network only ever sees a VPN.")
            }
            if askingSleep, let warning = session.sleepWarning {
                SleepConfirm(warning: warning, action: "Turn off") {
                    askingSleep = false
                    keepAwake.set(false)
                } cancel: { askingSleep = false }
            }
            ForEach(notes, id: \.self) { text in
                Label(text, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(PTColor.attentionText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.2), value: notes)
        .onChange(of: keepAwake.isOn) { _, on in if !on { askingSleep = false } }
    }

    private func toggleAwake() {
        if keepAwake.isOn, session.sleepWarning != nil { return askingSleep.toggle() }
        keepAwake.set(!keepAwake.isOn)
    }

    private var internetDetail: String {
        switch session.phase {
        case .connected: session.linkName.replacingOccurrences(of: "over ", with: "via ")
        case .connecting: "Connecting…"
        default: session.device == nil ? "No phone" : "Off"
        }
    }

    private var awakeDetail: String {
        guard keepAwake.isOn else { return "Sleeps as usual" }
        guard keepAwake.hasLid else { return "On" }
        if !keepAwake.lidCloseHeld { return "Idle only" }
        if keepAwake.batteryAutoOff, !keepAwake.battery.isOnAC { return "Off at \(keepAwake.batteryAutoOffThreshold)%" }
        return "Lid closed OK"
    }

    private var vpnDetail: String {
        guard let profile = vpnLayer.activeProfile else { return "Set up" }
        guard vpnLayer.isWanted else { return "Off" }
        switch vpnLayer.status.state {
        case "connected": return vpnLayer.status.name.isEmpty ? profile.name : vpnLayer.status.name
        case "starting": return "Connecting…"
        case "reconnecting", "blocked": return "Reconnecting…"
        case "failed", "held": return "Blocked"
        default: return profile.name
        }
    }

    /// What needs saying under the switches: why Keep awake stopped or isn't
    /// holding the lid, and what's wrong with the VPN.
    private var notes: [String] {
        var list: [String] = []
        if let reason = keepAwake.blockedReason { list.append(reason) }
        if keepAwake.isOn, keepAwake.hasLid, !keepAwake.lidCloseHeld { list.append("Closing the lid will still sleep the Mac until the helper is approved.") }
        if let vpn = vpnLayer.error ?? (vpnLayer.isWanted ? vpnLayer.status.warning : nil) { list.append(vpn) }
        if vpnLayer.isWanted, vpnLayer.status.state == "held" { list.append("Traffic is blocked since Passthrough stopped. Turn the VPN off to release it.") }
        return list
    }
}

/// One of the three switches: icon, name, state; mint when on, amber when on but not working.
struct ModuleTile: View {
    let title: String
    let detail: String
    let symbol: String
    let on: Bool
    var busy = false
    var warning = false
    let action: () -> Void
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                ZStack {
                    if busy {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: warning ? "exclamationmark.triangle.fill" : symbol)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(warning ? PTColor.onAttention : on ? PTColor.onTint : Color.primary)
                    }
                }
                .frame(width: 28, height: 28)
                .background(warning ? PTColor.attention : on ? PTColor.tint : Color.primary.opacity(0.08), in: Circle())
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 12.5, weight: .semibold))
                    Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 78, alignment: .leading)
            .padding(10)
            .background(on ? PTColor.surfaceOn : Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(on ? PTColor.tint.opacity(0.4) : Color.primary.opacity(0.06)))
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .opacity(enabled ? 1 : 0.5)
            .animation(.easeOut(duration: 0.2), value: on)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title), \(detail)")
        .accessibilityAddTraits(on ? .isSelected : [])
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
                    row(symbol: "apple.terminal", attention: shellNeedsSetup) {
                        Text(shellStatus(open: running.count)).font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(shellNeedsSetup ? PTColor.attentionText : .primary)
                    } trailing: {
                        Image(systemName: "chevron.right").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
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

    private func row<Content: View, Trailing: View>(symbol: String, attention: Bool, @ViewBuilder content: () -> Content,
                                                    @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
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

// MARK: - Heading out

/// At the desk, online through the phone, with Remote shell on: a nudge to
/// pick Away before taking the phone. "Not now" quiets it for the day.
struct HeadingOutTip: View {
    @EnvironmentObject private var session: SessionCoordinator
    @EnvironmentObject private var vpnLayer: VPNLayer
    @EnvironmentObject private var keepAwake: KeepAwakeController
    @AppStorage("headingOutTipQuietUntil") private var quietUntil: Double = 0

    var body: some View {
        if session.currentMoment == .desk, session.phase.isConnected, session.remoteShellEnabled, Date.now.timeIntervalSince1970 > quietUntil {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "figure.walk").font(.system(size: 13, weight: .semibold)).foregroundStyle(PTColor.tintText)
                VStack(alignment: .leading, spacing: 8) {
                    Text(keepAwake.hasLid
                         ? "Heading out? Pick **Away** before you go. The Mac stays awake with the lid shut and moves to its own Wi-Fi when you take the phone."
                         : "Heading out? Pick **Away** before you go. The Mac stays awake and moves to its own network when you take the phone.")
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        Button("Away") { session.apply(.away) }
                            .buttonStyle(PTPillButtonStyle())
                        Button("Not now") {
                            quietUntil = Calendar.current.startOfDay(for: .now.addingTimeInterval(86_400)).timeIntervalSince1970
                        }
                        .controlSize(.small)
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(PTColor.tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(PTColor.tint.opacity(0.25)))
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

/// Shown until the privileged helper is approved in System Settings.
struct HelperCard: View {
    @EnvironmentObject private var session: SessionCoordinator

    var body: some View {
        PTSurface(padding: 16) {
            VStack(spacing: 10) {
                Image(systemName: "lock.shield").font(.system(size: 28, weight: .medium)).foregroundStyle(PTColor.attentionText)
                Text("Allow the tunnel helper").font(.headline)
                Text("Routing the Mac needs a small helper that runs in the background. Approve “Passthrough” under Login Items & Extensions ▸ Allow in the Background.")
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                if case .failed(let why) = session.helperAvailability {
                    Text(why).font(.caption2).foregroundStyle(PTColor.problem).multilineTextAlignment(.center)
                }
                HStack {
                    Button("Open System Settings") { session.openLoginItems() }.buttonStyle(PTPillButtonStyle())
                    Button("Try again") { session.retryHelper() }.buttonStyle(.bordered)
                }
            }
        }
    }
}
