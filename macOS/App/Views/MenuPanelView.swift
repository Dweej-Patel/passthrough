import SwiftUI
import PassthroughCore
import PassthroughUI

/// The menu bar panel: everything you need at a glance, one click to connect.
struct MenuPanelView: View {
    @EnvironmentObject private var session: SessionCoordinator
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Group {
            if session.panelVisible {
                panel
            } else {
                // Closed: MenuBarExtra keeps this view alive; don't lay out or
                // rasterise the chart and blur for a panel nobody can see.
                Color.clear.frame(width: 356, height: 120)
            }
        }
        .background(WindowVisibilityObserver { visible in
            if session.panelVisible != visible { session.panelVisible = visible }
        })
    }

    private var panel: some View {
        ZStack {
            PTBackground(glow: session.phase.isConnected ? 1 : 0.5)
            VStack(spacing: 14) {
                header
                switch session.phase {
                case .helperRequired: HelperCard()
                case .pairingRequired: PairingCard()
                default: hero
                }
                FlowCard()
                VPNRow()
                KeepAwakeRow()
                ThroughputPanel()
                footer
            }
            .padding(16)
        }
        .frame(width: 356)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous).fill(PTTheme.accent).frame(width: 36, height: 36)
                Image(systemName: session.device?.kind == .android ? "smartphone" : "iphone.gen3").font(.system(size: 18, weight: .semibold)).foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(session.phoneStatus?.deviceName ?? (session.device == nil ? "No phone" : session.phoneKindName))
                    .font(.headline)
                Text(statusLine).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    .contentTransition(.opacity)
            }
            Spacer()
            HStack(spacing: 6) {
                if let radio = session.phoneStatus?.radio { PTPill(radio, tint: PTTheme.down) }
                if let battery = session.phoneStatus?.battery {
                    PTPill("\(Int(battery * 100))%", icon: batterySymbol(battery), tint: battery < 0.2 ? PTTheme.warning : .secondary)
                }
            }
        }
    }

    private func batterySymbol(_ level: Double) -> String {
        switch level {
        case ..<0.15: return "battery.0percent"
        case ..<0.4: return "battery.25percent"
        case ..<0.65: return "battery.50percent"
        case ..<0.9: return "battery.75percent"
        default: return "battery.100percent"
        }
    }

    private var statusLine: String {
        switch session.phase {
        case .noDevice: return "Plug an iPhone or Android phone into USB"
        case .deviceFound: return "Ready to connect over USB"
        case .helperRequired: return "Helper needs approval"
        case .connecting(let step): return step
        case .pairingRequired: return "Enter the code from the \(session.phoneKindName)"
        case .connected:
            let n = session.phoneActiveConnections
            return "Online via USB · \(n) open connection\(n == 1 ? "" : "s")"
        case .error(let message): return message
        }
    }

    // MARK: Hero

    private var hero: some View {
        PTCard(padding: 14) {
            HStack(spacing: 14) {
                ZStack {
                    StatusRing(mode: ringMode, size: 64, lineWidth: 5)
                    Image(systemName: session.phase.isConnected ? "checkmark" : (session.device == nil ? "cable.connector.slash" : "cable.connector"))
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(session.phase.isConnected ? AnyShapeStyle(PTTheme.accent) : AnyShapeStyle(Color.secondary))
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(heroTitle).font(.subheadline.weight(.semibold))
                    Text(heroDetail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                ConnectToggle(isOn: session.phase.isConnected || session.phase.isBusy, busy: session.phase.isBusy, enabled: session.device != nil) {
                    session.toggle()
                }
            }
        }
    }

    private var ringMode: StatusRing.Mode {
        switch session.phase {
        case .connected: return .live
        case .connecting: return .busy
        case .error: return .error
        default: return .idle
        }
    }

    private var heroTitle: String {
        switch session.phase {
        case .connected: return "Passthrough is on"
        case .connecting: return "Connecting…"
        case .error: return "Not connected"
        case .noDevice: return "Waiting for USB"
        default: return "Passthrough is off"
        }
    }

    private var heroDetail: String {
        switch session.phase {
        case .connected:
            if session.phoneStatus?.radio == "Wi-Fi" {
                return "The \(session.phoneKindName) is on Wi-Fi, so this Mac uses its Wi-Fi, not cellular. Turn off Wi-Fi on the phone to use cellular."
            }
            if let iface = session.tunnelInterface, let d = session.sessionDuration {
                return "All traffic routes through \(iface) for \(ByteFormat.duration(d))."
            }
            return "All traffic routes through the \(session.phoneKindName)."
        case .connecting: return "Setting up the USB link and routing. Open connections will switch over."
        case .error(let message): return message
        case .noDevice: return session.androidHint ?? "Connect the cable and unlock the phone. Trust this Mac if asked; Android phones need USB debugging on."
        default: return session.hasToken ? "Flip the switch to route this Mac through the \(session.phoneKindName)." : "First connection will ask for a pairing code."
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            Button { session.autoConnect.toggle() } label: {
                HStack(spacing: 7) {
                    MiniSwitch(isOn: session.autoConnect)
                    Text("Auto-connect").font(.caption)
                }
            }
            .buttonStyle(.plain)
            .help("Connect as soon as a phone is plugged in")
            Spacer()
            Button { SettingsWindow.show(openSettings) } label: { Image(systemName: "gearshape").font(.system(size: 13, weight: .semibold)) }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .help("Settings")
            Button { NSApp.terminate(nil) } label: { Image(systemName: "power").font(.system(size: 13, weight: .semibold)) }
                .buttonStyle(.plain).foregroundStyle(.secondary).padding(.leading, 10)
                .help("Quit Passthrough")
        }
        .padding(.top, 2)
    }
}

/// Tiny SwiftUI switch used in the footer.
struct MiniSwitch: View {
    let isOn: Bool
    var body: some View {
        ZStack(alignment: isOn ? .trailing : .leading) {
            Capsule().fill(isOn ? AnyShapeStyle(PTTheme.accent) : AnyShapeStyle(Color.primary.opacity(0.15))).frame(width: 30, height: 17)
            Circle().fill(.white).frame(width: 13, height: 13).padding(2).shadow(color: .black.opacity(0.2), radius: 1, y: 0.5)
        }
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: isOn)
    }
}

/// Custom capsule switch with the accent gradient.
struct ConnectToggle: View {
    let isOn: Bool
    let busy: Bool
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule()
                    .fill(isOn ? AnyShapeStyle(PTTheme.accent) : AnyShapeStyle(Color.primary.opacity(0.12)))
                    .frame(width: 52, height: 30)
                    .shadow(color: isOn ? PTTheme.accentStart.opacity(0.5) : .clear, radius: 10)
                Circle()
                    .fill(.white)
                    .frame(width: 24, height: 24)
                    .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                    .padding(3)
                    .overlay {
                        if busy { ProgressView().controlSize(.mini) }
                    }
            }
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isOn)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
        .accessibilityLabel(isOn ? "Disconnect" : "Connect")
    }
}

/// A quick toggle to keep the Mac awake for long sessions.
struct KeepAwakeRow: View {
    @EnvironmentObject private var keepAwake: KeepAwakeController
    private var keepAwakeSubtitle: String {
        guard keepAwake.isOn else { return "Sleeps normally" }
        if !keepAwake.lidCloseHeld { return "Idle sleep held (approve helper for lid-close)" }
        if keepAwake.batteryAutoOff, keepAwake.battery.hasBattery, !keepAwake.battery.isOnAC {
            return "Awake with lid closed · off at \(keepAwake.batteryAutoOffThreshold)%"
        }
        return "Stays awake even with the lid closed"
    }
    var body: some View {
        VStack(spacing: 0) {
        Button { keepAwake.set(!keepAwake.isOn) } label: {
            HStack(spacing: 10) {
                Image(systemName: keepAwake.isOn ? "cup.and.saucer.fill" : "cup.and.saucer")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(keepAwake.isOn ? AnyShapeStyle(PTTheme.accent) : AnyShapeStyle(Color.secondary))
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Keep Mac awake").font(.subheadline.weight(.medium))
                    Text(keepAwakeSubtitle)
                        .font(.caption2).foregroundStyle(keepAwake.isOn && !keepAwake.lidCloseHeld ? PTTheme.warning : .secondary)
                }
                Spacer()
                MiniSwitch(isOn: keepAwake.isOn)
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .help("Keeps the Mac awake for long sessions, including with the lid closed. Warning: a closed, running Mac in a bag can overheat and drain the battery.")
        if let reason = keepAwake.blockedReason {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill").font(.caption2)
                Text(reason).font(.caption2)
                Spacer(minLength: 0)
            }
            .foregroundStyle(PTTheme.warning)
            .padding(.horizontal, 12).padding(.top, 6)
            .transition(.opacity)
        }
        }
        .animation(.easeInOut(duration: 0.2), value: keepAwake.blockedReason)
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
                                   connected: v.isConnected, blocked: v.state == "blocked")
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
                            activeConnections: session.phoneActiveConnections, viaWiFi: viaWiFi, localNetworkName: localName)
    }

    var body: some View {
        PTCard(padding: 8) {
            FlowMap(state: flowState, height: 84, active: session.panelVisible)
        }
    }
}

/// The VPN layer toggle: one encrypted flow on top of the passthrough.
struct VPNRow: View {
    @EnvironmentObject private var session: SessionCoordinator
    @EnvironmentObject private var vpnLayer: VPNLayer
    @Environment(\.openSettings) private var openSettings

    private var hasProfile: Bool { vpnLayer.activeProfile != nil }
    private var isOn: Bool { vpnLayer.isWanted }

    private var subtitle: String {
        let v = vpnLayer.status
        guard isOn else {
            if let p = vpnLayer.activeProfile { return "Off · \(p.name)" }
            return "No profile yet · set one up in Settings"
        }
        switch v.state {
        case "starting": return "Connecting to \(v.name)…"
        case "connected":
            var parts = [v.name]
            if let u = v.underlay { parts.append("over \(u == "iPhone" ? session.phoneKindName : u)") }
            if let d = v.duration { parts.append(ByteFormat.duration(d)) }
            return parts.joined(separator: " · ")
        case "reconnecting": return "Session dropped · reconnecting…"
        case "blocked": return "Down · traffic blocked · reconnecting…"
        case "failed": return vpnLayer.killSwitch ? "Failed · traffic blocked · turn off to release" : "Failed"
        default: return v.name
        }
    }

    private var tint: Color {
        guard isOn else { return .secondary }
        switch vpnLayer.status.state {
        case "connected": return PTTheme.success
        case "blocked", "reconnecting": return PTTheme.warning
        case "failed": return PTTheme.danger
        default: return .secondary
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Button {
                if hasProfile { vpnLayer.set(!isOn) } else { SettingsWindow.show(openSettings) }
            } label: {
                HStack(spacing: 10) {
                    Group {
                        if vpnLayer.status.isBusy {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: vpnLayer.status.isConnected ? "lock.shield.fill" : "lock.shield")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(vpnLayer.status.isConnected ? AnyShapeStyle(PTTheme.accent) : AnyShapeStyle(Color.secondary))
                        }
                    }
                    .frame(width: 20)
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 6) {
                            Text("VPN layer").font(.subheadline.weight(.medium))
                            if vpnLayer.status.isConnected {
                                PTPill(vpnLayer.status.engineLabel, tint: PTTheme.success)
                            } else if vpnLayer.killSwitch, isOn {
                                PTPill("Kill switch", tint: .secondary)
                            }
                        }
                        Text(subtitle).font(.caption2).foregroundStyle(tint).lineLimit(1)
                    }
                    Spacer()
                    MiniSwitch(isOn: isOn)
                }
                .padding(.horizontal, 12).padding(.vertical, 9)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)
            .help("Wraps everything the Mac sends in one encrypted VPN flow (WireGuard or OpenVPN) on top of the passthrough, so the carrier only ever sees a VPN.")
            if let error = vpnLayer.error {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.caption2)
                    Text(error).font(.caption2)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(PTTheme.warning)
                .padding(.horizontal, 12).padding(.top, 6)
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: vpnLayer.error)
        .animation(.easeInOut(duration: 0.2), value: vpnLayer.status.state)
    }
}

/// Throughput readouts and chart.
struct ThroughputPanel: View {
    @EnvironmentObject private var session: SessionCoordinator

    var body: some View {
        PTCard(padding: 14) {
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

/// Six-box code entry for the first connection.
struct PairingCard: View {
    @EnvironmentObject private var session: SessionCoordinator
    @State private var code = ""
    @FocusState private var focused: Bool

    var body: some View {
        PTCard(padding: 16) {
            VStack(spacing: 12) {
                Image(systemName: "laptopcomputer.and.iphone").font(.system(size: 28, weight: .medium)).foregroundStyle(PTTheme.accent)
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
                    Text(error).font(.caption).foregroundStyle(PTTheme.danger).multilineTextAlignment(.center)
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
        PTCard(padding: 16) {
            VStack(spacing: 10) {
                Image(systemName: "lock.shield").font(.system(size: 28, weight: .medium)).foregroundStyle(PTTheme.warning)
                Text("Allow the tunnel helper").font(.headline)
                Text("Routing the Mac needs a small helper that runs in the background. Approve “Passthrough” under Login Items & Extensions ▸ Allow in the Background.")
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                if case .failed(let why) = session.helperAvailability {
                    Text(why).font(.caption2).foregroundStyle(PTTheme.danger).multilineTextAlignment(.center)
                }
                HStack {
                    Button("Open System Settings") { session.openLoginItems() }.buttonStyle(.borderedProminent).tint(PTTheme.accentEnd)
                    Button("Try again") { session.retryHelper() }.buttonStyle(.bordered)
                }
            }
        }
    }
}
