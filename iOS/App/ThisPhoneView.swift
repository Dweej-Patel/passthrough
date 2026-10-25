import SwiftUI
import PassthroughCore
import PassthroughUI

/// This phone's own side, one tap in from the Mac tab: its sharing, its
/// traffic and data use, and the Macs it's paired with.
struct ThisPhoneView: View {
    @EnvironmentObject private var model: AppModel
    @Binding var showPairing: Bool
    @Binding var showSettings: Bool

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                HeroCard(showPairing: $showPairing)
                MacsCard(showPairing: $showPairing)
                FlowCard()
                ThroughputCard()
                UsageCard()
                footer
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)
            .padding(.bottom, 24)
        }
        .background(PTColor.background)
        .navigationTitle("This iPhone")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showSettings = true } label: { Image(systemName: "gearshape") }
                    .accessibilityLabel("Settings")
            }
        }
    }

    private var footer: some View {
        Text("Traffic between the Mac and this iPhone travels only over the USB cable. The Mac's connections are opened by this phone's own network stack.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
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
        PTSurface(padding: 10) {
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
        PTSurface(padding: 22) {
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
                        Text(message).font(.caption).foregroundStyle(PTColor.problem).multilineTextAlignment(.center)
                    }
                    if model.sharingWiFiInsteadOfCellular {
                        Label("This iPhone is on Wi-Fi, so your Mac uses its Wi-Fi, not cellular. Turn off Wi-Fi to share cellular.", systemImage: "wifi")
                            .font(.caption).foregroundStyle(PTColor.attentionText).multilineTextAlignment(.center)
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
                    }
                    .buttonStyle(PTProminentButtonStyle())
                }
            }
        }
    }

    private var statusLine: String {
        switch model.state {
        case .stopped: return "Off. Tap to share this iPhone's internet with your Mac"
        case .starting: return "Turning on…"
        case .stopping: return "Turning off…"
        case .failed: return "Couldn't turn on"
        case .running:
            if let mac = model.stats.macs.first { return "\(mac.name) is online through this iPhone" }
            return "Sharing. Plug in your Mac and connect from its menu bar."
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
                    .fill(isOn ? PTColor.tint : Color.primary.opacity(0.08))
                    .frame(width: 128, height: 128)
                    .shadow(color: isOn ? PTColor.tint.opacity(0.35) : .clear, radius: 20, y: 6)
                Image(systemName: "power")
                    .font(.system(size: 44, weight: .bold))
                    .foregroundStyle(isOn ? PTColor.onTint : Color.primary.opacity(0.6))
                    .opacity(busy ? 0.4 : 1)
            }
            .scaleEffect(pressed ? 0.94 : 1)
            .animation(.easeOut(duration: 0.15), value: pressed)
            .animation(.easeInOut(duration: 0.4), value: isOn)
        }
        .buttonStyle(.plain)
        .disabled(busy)
        .simultaneousGesture(DragGesture(minimumDistance: 0).onChanged { _ in pressed = true }.onEnded { _ in pressed = false })
        .accessibilityLabel(isOn ? "Stop sharing this iPhone's internet" : "Share this iPhone's internet")
        .sensoryFeedback(.impact(weight: .medium), trigger: isOn)
    }
}

// MARK: - Throughput

struct ThroughputCard: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        PTSurface {
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
        PTSurface {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    PTSectionTitle("Data used", icon: "chart.bar.fill")
                    Spacer()
                    Button("Reset month") { confirmReset = true }
                        .font(.caption.weight(.semibold))
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                        .padding(.vertical, -15)
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
        PTSurface {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    PTSectionTitle("Paired Macs", icon: "laptopcomputer")
                    Spacer()
                    Button { showPairing = true } label: {
                        Label("Pair", systemImage: "plus").font(.caption.weight(.bold))
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .tint(PTColor.tintText)
                    .controlSize(.small)
                }
                if model.pairedClients.isEmpty {
                    Text("No Mac paired yet. Tap Pair and enter the code in Passthrough on your Mac, with the cable plugged in.")
                        .font(.subheadline).foregroundStyle(.secondary)
                } else {
                    ForEach(model.pairedClients) { client in
                        let live = model.connectedMacIDs.contains(client.id)
                        HStack(spacing: 12) {
                            PTStatusDot(color: live ? PTColor.tint : .secondary.opacity(0.5), live: live)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(client.name).font(.subheadline.weight(.semibold))
                                Text(live ? "Connected now" : lastSeen(client)).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Menu {
                                Button(role: .destructive) { model.revoke(client) } label: { Label("Forget this Mac", systemImage: "trash") }
                            } label: {
                                Image(systemName: "ellipsis.circle")
                                    .foregroundStyle(.secondary)
                                    .frame(width: 44, height: 44)
                                    .contentShape(Rectangle())
                            }
                            .accessibilityLabel("More for \(client.name)")
                        }
                        .frame(minHeight: 44)
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
