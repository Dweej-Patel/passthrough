import SwiftUI
import PassthroughCore
import PassthroughUI

/// The Mac, drawn, with one line on how it's doing and one on how it's reached.
struct MacHeroCard: View {
    @ObservedObject var shell: ShellModel
    let paired: Bool
    let online: Bool
    let lastSeen: Date?
    @Binding var showPairing: Bool

    var body: some View {
        PTSurface(stroke: shell.reach == .unreachable ? PTColor.attention.opacity(0.4) : PTColor.hairline) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 16) {
                    MacFigure(asleep: shell.reach == .unreachable, awake: awake, live: shell.reach == .ready || online)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(title).font(.title3.weight(.bold))
                            .contentTransition(.opacity)
                        if let detail { Text(detail).font(.subheadline).foregroundStyle(.secondary).contentTransition(.opacity) }
                        if online, shell.reach == .ready {
                            Label("Online through this iPhone", systemImage: "cable.connector")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(PTColor.tintText)
                        }
                    }
                    Spacer(minLength: 0)
                }
                extra
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .contain)
    }

    /// Keep awake is on and the Mac says so now.
    private var awake: Bool { shell.reach == .ready && shell.macState?.awake == true }

    private var title: String {
        if !paired { return "Set up your Mac" }
        switch shell.reach {
        case .ready: return awake ? "Staying awake" : "Reachable"
        case .connecting: return shell.isRedialing ? "Reconnecting…" : "Connecting…"
        case .unreachable: return "Can't reach it"
        case .noAccess: return online ? "Online through this iPhone" : "Paired"
        // Not "needs you": that's a shell waiting on a question.
        case .locked: return "Unlock to continue"
        case .needsPasscode: return "Needs a passcode"
        case .keyUnavailable: return "Plug in to renew"
        }
    }

    private var detail: String? {
        if !paired { return "Pair once over USB." }
        switch shell.reach {
        case .ready:
            if awake, let state = shell.macState {
                if state.charging == true { return "Plugged in" }
                if let minutes = state.minutesLeft { return MacFormat.duration(minutes: minutes) + " left" }
                return state.hasLid ? "Even with the lid closed" : "It won't sleep"
            }
            switch shell.path {
            case .direct: return "From anywhere, directly"
            case .relay: return "From anywhere, through a relay"
            case .local: return "On this network"
            case .unknown, nil: return "Connected"
            }
        case .connecting: return nil
        case .unreachable:
            return shell.lastHeard.map { "Last heard \($0.formatted(.relative(presentation: .named)))" }
        case .noAccess:
            if online { return "Plugged in over USB" }
            return lastSeen.map { "Last plugged in \($0.formatted(.relative(presentation: .named)))" }
        case .locked, .needsPasscode, .keyUnavailable: return nil
        }
    }

    @ViewBuilder private var extra: some View {
        if paired, shell.reach == .ready, let state = shell.macState, let battery = state.battery {
            BatteryLine(state: state, battery: battery, awake: awake)
        }
        if !paired {
            Text("Then it's online through this iPhone whenever they're connected, and you can reach its shell from anywhere.")
                .font(.subheadline).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button { showPairing = true } label: { Label("Pair your Mac", systemImage: "laptopcomputer.and.iphone") }
                .buttonStyle(PTProminentButtonStyle())
        } else {
            switch shell.reach {
            case .unreachable:
                VStack(alignment: .leading, spacing: 4) {
                    if shell.macState?.awakeStopped == MacState.stoppedBattery {
                        Text("It most likely went to sleep").font(.subheadline.weight(.semibold)).foregroundStyle(PTColor.attentionText)
                        Text("Its battery reached your \(MacFormat.percent(shell.macState?.batteryFloor ?? 0.2)) limit, so Keep awake let it sleep. Plug it in and it wakes for the next connection.")
                            .font(.subheadline).fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text("It may be asleep, off, or offline").font(.subheadline.weight(.semibold)).foregroundStyle(PTColor.attentionText)
                        if let message = shell.reachMessage {
                            Text(message).font(.subheadline).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(PTColor.attention.opacity(0.1), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                Button { shell.connect() } label: { Label("Try again", systemImage: "arrow.clockwise") }
                    .buttonStyle(PTProminentButtonStyle())
            case .locked, .needsPasscode, .keyUnavailable:
                if let message = shell.reachMessage {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(.subheadline)
                        .foregroundStyle(PTColor.attentionText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            default:
                EmptyView()
            }
        }
    }
}

/// The Mac's battery, with Keep awake's limit marked on it.
private struct BatteryLine: View {
    let state: MacState
    let battery: Double
    let awake: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    Capsule().fill(awake ? PTColor.tint : Color.secondary.opacity(0.5))
                        .frame(width: max(6, geo.size.width * battery))
                    if let floor = state.batteryFloor, state.charging != true {
                        Rectangle().fill(PTColor.surface).frame(width: 2).offset(x: geo.size.width * floor - 1)
                    }
                }
            }
            .frame(height: 6)
            .animation(.easeOut(duration: 0.4), value: battery)
            Text(caption).font(.caption).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Battery \(MacFormat.percent(battery)). \(caption)")
    }

    private var caption: String {
        let level = MacFormat.percent(battery)
        if state.charging == true { return "\(level), charging" }
        guard awake else { return "\(level) on battery" }
        var limits: [String] = []
        if let floor = state.batteryFloor { limits.append("at \(MacFormat.percent(floor))") }
        limits.append("if it gets hot")
        return "\(level) now · sleeps " + limits.joined(separator: " or ")
    }
}

/// The one thing that keeps moving: a shell is waiting on you. Under Reduce
/// Motion it stays still, a plain dot.
struct NeedsYouDot: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    var body: some View {
        Circle()
            .fill(PTColor.attention)
            .frame(width: 10, height: 10)
            .background(Circle().fill(PTColor.attention.opacity(0.35)).scaleEffect(pulse ? 2.2 : 1).opacity(pulse ? 0 : 1))
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeOut(duration: 1.6).repeatForever(autoreverses: false)) { pulse = true }
            }
            .accessibilityHidden(true)
    }
}

// MARK: - Figure

/// A laptop: lid open while it's reachable or online, shut and dozing when it
/// can't be reached, shut and glowing while Keep awake holds it awake. The lid
/// shutting is the app's one authored moment; Reduce Motion skips it.
struct MacFigure: View {
    let asleep: Bool
    var awake = false
    let live: Bool
    @State private var lidDown = false
    @State private var glow = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .bottom) {
            if asleep || awake {
                closed.transition(.opacity)
            } else {
                open.transition(.opacity)
            }
        }
        .frame(width: 104, height: 76)
        .animation(.easeOut(duration: 0.35), value: asleep || awake)
        .onChange(of: awake, initial: true) { _, now in shut(now) }
        .accessibilityElement()
        .accessibilityLabel(asleep ? "Mac, not answering" : awake ? "Mac, staying awake" : "Mac")
    }

    private func shut(_ now: Bool) {
        guard now else { lidDown = false; glow = false; return }
        guard !reduceMotion else { lidDown = true; glow = true; return }
        lidDown = false
        glow = false
        withAnimation(.easeOut(duration: 0.55)) { lidDown = true }
        withAnimation(.easeOut(duration: 0.6).delay(0.35)) { glow = true }
    }

    private var base: some View {
        UnevenRoundedRectangle(bottomLeadingRadius: 4, bottomTrailingRadius: 4)
            .fill(Color.primary.opacity(0.22))
            .frame(width: 104, height: 6)
    }

    private var open: some View {
        VStack(spacing: 0) {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Color.primary.opacity(0.12))
                .frame(width: 80, height: 54)
                .overlay {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(live ? PTColor.surfaceOn : Color.primary.opacity(0.06))
                        .padding(4)
                        .overlay(alignment: .topLeading) {
                            VStack(alignment: .leading, spacing: 5) {
                                ForEach([26.0, 40, 18], id: \.self) { w in
                                    Capsule().fill(live ? PTColor.tint : Color.secondary.opacity(0.4)).frame(width: w, height: 3)
                                }
                            }
                            .padding(10)
                        }
                }
            base
        }
    }

    private var closed: some View {
        ZStack(alignment: .topTrailing) {
            if awake {
                Ellipse()
                    .fill(PTColor.tint.opacity(glow ? 0.35 : 0))
                    .frame(width: 104, height: 26)
                    .blur(radius: 10)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .offset(y: 8)
            }
            VStack(spacing: 0) {
                Spacer()
                LidShape()
                    .fill(Color.primary.opacity(0.14))
                    .frame(width: 104, height: 12)
                    // Shutting: tall (open, seen edge-on) to flat.
                    .scaleEffect(x: 1, y: awake && !lidDown ? 4.2 : 1, anchor: .bottom)
                base
            }
            if asleep {
                Text("z").font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .offset(x: -6, y: 22)
            }
        }
    }
}

/// A shut lid seen from the front: a shallow trapezoid.
private struct LidShape: Shape {
    func path(in rect: CGRect) -> Path {
        Path { p in
            p.move(to: CGPoint(x: rect.minX, y: rect.maxY))
            p.addLine(to: CGPoint(x: rect.minX + rect.width * 0.12, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.maxX - rect.width * 0.12, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            p.closeSubpath()
        }
    }
}
