import SwiftUI
import PassthroughCore
import PassthroughUI

struct HomeView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showPairing = false
    @State private var showSettings = false

    var body: some View {
        ZStack {
            PTBackground(glow: model.state == .running ? 1 : 0.45)
            ScrollView {
                VStack(spacing: 18) {
                    header
                    HeroCard(showPairing: $showPairing)
                    FlowCard()
                    ThroughputCard()
                    UsageCard()
                    MacsCard(showPairing: $showPairing)
                    footer
                }
                .padding(.horizontal, 18)
                .padding(.top, 8)
                .padding(.bottom, 32)
            }
        }
        .sheet(isPresented: $showPairing, onDismiss: { model.endPairing() }) {
            PairSheet().environmentObject(model)
        }
        .sheet(isPresented: $showSettings) {
            SettingsView().environmentObject(model)
        }
        .onAppear {
            let env = ProcessInfo.processInfo.environment
            if env["PASSTHROUGH_AUTOSTART"] == "1" { model.start() }
            if env["PASSTHROUGH_SHOW_PAIRING"] == "1" { DispatchQueue.main.asyncAfter(deadline: .now() + 1) { showPairing = true } }
            if env["PASSTHROUGH_SHOW_SETTINGS"] == "1" { DispatchQueue.main.asyncAfter(deadline: .now() + 1) { showSettings = true } }
        }
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Passthrough").font(PTTheme.display(30))
                Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
                    .contentTransition(.opacity)
            }
            Spacer()
            Button { showSettings = true } label: {
                Image(systemName: "gearshape.fill")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 42, height: 42)
                    .background(.regularMaterial, in: Circle())
            }
            .accessibilityLabel("Settings")
        }
        .padding(.top, 6)
    }

    private var subtitle: String {
        switch model.state {
        case .running:
            let n = model.stats.macs.count
            let how = model.servingWirelessly ? "over \(model.stats.wirelessCarrier ?? "Wi-Fi")" : "over USB"
            return n == 0 ? (model.wireless ? "Waiting for a Mac" : "Waiting for a Mac on USB") : "Serving \(n == 1 ? "1 Mac" : "\(n) Macs") \(how)"
        case .starting: return "Starting…"
        case .stopping: return "Stopping…"
        case .failed: return "Something went wrong"
        case .stopped: return "USB internet for your Mac"
        }
    }

    private var footer: some View {
        VStack(spacing: 6) {
            Text("Traffic between the Mac and this iPhone travels only over the USB cable. The Mac's connections are opened by this phone's own network stack.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 12)
    }
}

// MARK: - Flow map

/// Live picture of how a Mac's traffic moves through this phone.
struct FlowCard: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase

    private var flowState: FlowMapState {
        let macs = model.stats.macs
        let macName = macs.count > 1 ? "\(macs.count) Macs" : (macs.first?.name ?? "Mac")
        return FlowMapState(perspective: .iphone, macName: macName, phoneName: model.deviceName,
                            linkUp: model.state == .running && !macs.isEmpty,
                            busy: model.state == .starting || (model.state == .running && macs.isEmpty),
                            radio: model.radio, downRate: model.meter.downRate, upRate: model.meter.upRate,
                            activeConnections: model.stats.active, wireless: model.servingWirelessly, wirelessCarrier: model.stats.wirelessCarrier)
    }

    var body: some View {
        PTCard(padding: 10) {
            VStack(alignment: .leading, spacing: 4) {
                PTSectionTitle("How it flows", icon: "point.3.connected.trianglepath.dotted").padding(.leading, 6)
                FlowMap(state: flowState, height: 90, active: scenePhase == .active)
            }
        }
    }
}

// MARK: - Hero

struct HeroCard: View {
    @EnvironmentObject private var model: AppModel
    @Binding var showPairing: Bool

    private var ringMode: StatusRing.Mode {
        switch model.state {
        case .running: return .live
        case .starting, .stopping: return .busy
        case .failed: return .error
        case .stopped: return .idle
        }
    }

    var body: some View {
        PTCard(padding: 22) {
            VStack(spacing: 18) {
                ZStack {
                    StatusRing(mode: ringMode, size: 196, lineWidth: 11)
                    PowerButton(isOn: model.state.isActive, busy: model.state == .starting || model.state == .stopping) {
                        model.toggle()
                    }
                }
                .padding(.top, 4)

                VStack(spacing: 8) {
                    Text(statusLine)
                        .font(.headline)
                        .multilineTextAlignment(.center)
                        .contentTransition(.opacity)
                    if case .failed(let message) = model.state {
                        Text(message).font(.caption).foregroundStyle(PTTheme.danger).multilineTextAlignment(.center)
                    }
                    if model.sharingWiFiInsteadOfCellular {
                        Label("This iPhone is on Wi-Fi, so your Mac uses its Wi-Fi, not cellular. Turn off Wi-Fi to share cellular.", systemImage: "wifi")
                            .font(.caption).foregroundStyle(PTTheme.warning).multilineTextAlignment(.center)
                    }
                    HStack(spacing: 8) {
                        if let radio = model.radio { PTPill(radio, icon: "antenna.radiowaves.left.and.right", tint: PTTheme.down) }
                        PTPill(model.servingWirelessly ? (model.stats.wirelessCarrier ?? "Wireless") : "USB",
                               icon: model.servingWirelessly ? Self.carrierIcon(model.stats.wirelessCarrier) : "cable.connector", tint: .secondary)
                        PTPill(model.hosting == .background ? "Background" : "Foreground", icon: model.hosting == .background ? "moon.zzz.fill" : "sun.max.fill", tint: .secondary)
                        if model.state == .running {
                            PTPill("\(model.stats.active) open", icon: "arrow.left.arrow.right", tint: PTTheme.up)
                        }
                    }
                }

                if model.pairedClients.isEmpty && model.state == .running {
                    Button { showPairing = true } label: {
                        Label("Pair your Mac", systemImage: "laptopcomputer.and.iphone")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(PTTheme.accentEnd)
                }
            }
        }
    }

    private var statusLine: String {
        switch model.state {
        case .stopped: return "Tap to start sharing this iPhone's connection"
        case .starting: return "Bringing the proxy up"
        case .stopping: return "Shutting down"
        case .failed: return "Could not start"
        case .running:
            if let mac = model.stats.macs.first { return "\(mac.name) is online through this iPhone" }
            return "Ready. Plug in your Mac and connect from the menu bar."
        }
    }

    static func carrierIcon(_ carrier: String?) -> String {
        switch carrier {
        case "Hotspot": return "personalhotspot"
        case "USB": return "cable.connector"
        default: return "wifi"
        }
    }
}

struct PowerButton: View {
    let isOn: Bool
    let busy: Bool
    let action: () -> Void
    @State private var pressed = false

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(isOn ? AnyShapeStyle(PTTheme.accent) : AnyShapeStyle(Color.primary.opacity(0.08)))
                    .frame(width: 128, height: 128)
                    .shadow(color: isOn ? PTTheme.accentStart.opacity(0.45) : .clear, radius: 24)
                Image(systemName: "power")
                    .font(.system(size: 44, weight: .bold))
                    .foregroundStyle(isOn ? Color.white : Color.primary.opacity(0.6))
                    .opacity(busy ? 0.4 : 1)
            }
            .scaleEffect(pressed ? 0.94 : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.6), value: pressed)
            .animation(.easeInOut(duration: 0.4), value: isOn)
        }
        .buttonStyle(.plain)
        .disabled(busy)
        .simultaneousGesture(DragGesture(minimumDistance: 0).onChanged { _ in pressed = true }.onEnded { _ in pressed = false })
        .accessibilityLabel(isOn ? "Stop passthrough" : "Start passthrough")
        .sensoryFeedback(.impact(weight: .medium), trigger: isOn)
    }
}

// MARK: - Throughput

struct ThroughputCard: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        PTCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    PTSectionTitle("Live throughput", icon: "waveform.path.ecg")
                    Spacer()
                    if let d = model.sessionDuration {
                        Text(ByteFormat.duration(d)).font(PTTheme.mono(12)).foregroundStyle(.secondary)
                    }
                }
                HStack(alignment: .firstTextBaseline) {
                    RateReadout(model.meter.downRate, direction: .down, size: 30)
                    Spacer()
                    RateReadout(model.meter.upRate, direction: .up, size: 30)
                }
                ThroughputChart(samples: model.meter.history, height: 110)
                HStack {
                    StatCell("Session down", value: ByteFormat.bytes(model.stats.rx), tint: PTTheme.down)
                    StatCell("Session up", value: ByteFormat.bytes(model.stats.tx), tint: PTTheme.up)
                    StatCell("Connections", value: "\(model.stats.totalConnections)")
                }
            }
        }
    }
}

// MARK: - Usage

struct UsageCard: View {
    @EnvironmentObject private var model: AppModel
    @State private var confirmReset = false

    var body: some View {
        PTCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    PTSectionTitle("Data used", icon: "chart.bar.fill")
                    Spacer()
                    Button("Reset month") { confirmReset = true }
                        .font(.caption.weight(.semibold))
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                }
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(ByteFormat.bytes(model.usage.monthTotal))
                            .font(PTTheme.mono(28, weight: .bold))
                            .contentTransition(.numericText())
                        Text("since \(model.usage.monthStart, format: .dateTime.month(.wide).day())")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(ByteFormat.bytes(model.usage.allTotal)).font(PTTheme.mono(17, weight: .semibold))
                        Text("all time").font(.caption).foregroundStyle(.secondary)
                    }
                }
                UsageBar(down: Double(model.usage.monthRx), up: Double(model.usage.monthTx))
            }
        }
        .confirmationDialog("Reset this month's counter?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Reset", role: .destructive) { model.usage.resetMonth() }
        }
    }
}

struct UsageBar: View {
    let down: Double
    let up: Double
    var body: some View {
        let total = max(down + up, 1)
        GeometryReader { geo in
            HStack(spacing: 2) {
                Capsule().fill(PTTheme.down).frame(width: max(4, geo.size.width * down / total))
                Capsule().fill(PTTheme.up).frame(width: max(4, geo.size.width * up / total))
            }
        }
        .frame(height: 6)
        .accessibilityLabel("Download \(ByteFormat.bytes(Int64(down))), upload \(ByteFormat.bytes(Int64(up)))")
    }
}

// MARK: - Macs

struct MacsCard: View {
    @EnvironmentObject private var model: AppModel
    @Binding var showPairing: Bool

    var body: some View {
        PTCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    PTSectionTitle("Paired Macs", icon: "laptopcomputer")
                    Spacer()
                    Button { showPairing = true } label: {
                        Label("Pair", systemImage: "plus").font(.caption.weight(.bold))
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .tint(PTTheme.accentEnd)
                    .controlSize(.small)
                }
                if model.pairedClients.isEmpty {
                    Text("No Mac paired yet. Start the proxy, then tap Pair and enter the code in Passthrough on your Mac.")
                        .font(.subheadline).foregroundStyle(.secondary)
                } else {
                    ForEach(model.pairedClients) { client in
                        let live = model.connectedMacIDs.contains(client.id)
                        HStack(spacing: 12) {
                            PTStatusDot(color: live ? PTTheme.success : .secondary.opacity(0.5), live: live)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(client.name).font(.subheadline.weight(.semibold))
                                Text(live ? "Connected now" : lastSeen(client)).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Menu {
                                Button(role: .destructive) { model.revoke(client) } label: { Label("Forget this Mac", systemImage: "trash") }
                            } label: {
                                Image(systemName: "ellipsis.circle").foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
        }
    }

    private func lastSeen(_ client: PairedClient) -> String {
        guard let seen = client.lastSeen else { return "Paired \(client.pairedAt.formatted(.relative(presentation: .named)))" }
        return "Last seen \(seen.formatted(.relative(presentation: .named)))"
    }
}
