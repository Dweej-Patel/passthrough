import SwiftUI
import PassthroughCore
import PassthroughUI

/// The Mac tab: the Mac itself, how this phone reaches it, and what to do with it.
struct MacHomeView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var router: ShellRouter
    @ObservedObject var shell: ShellModel
    @Binding var tab: RootTab
    @Binding var showPairing: Bool
    @Binding var showSettings: Bool
    @State private var confirmSleep = false
    @State private var confirmVPNOff = false
    /// A moment just picked, shown until the switches catch up with it.
    @State private var picked: Moment?
    /// A picked moment that turns the VPN off, waiting for Face ID.
    @State private var momentNeedingFaceID: Moment?
    @State private var momentNote: String?
    @ObservedObject private var links = PendingLinks.shared

    /// The Mac on screen: the shell's selection, else the first paired Mac.
    private var macID: String? { shell.selectedMacID ?? model.pairedClients.first?.id }
    private var macName: String {
        shell.macs.first { $0.macID == shell.selectedMacID }?.macName ?? model.pairedClients.first?.name ?? "Your Mac"
    }
    private var onlineThroughPhone: Bool { macID.map(model.connectedMacIDs.contains) ?? false }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    MacHeroCard(shell: shell, paired: !model.pairedClients.isEmpty || !shell.macs.isEmpty, online: onlineThroughPhone,
                                lastSeen: model.pairedClients.first { $0.id == macID }?.lastSeen, showPairing: $showPairing)
                    if shell.reach == .ready { needsYou }
                    if let state, canControl { moments(state) }
                    tiles
                    if shell.reach == .noAccess, !model.pairedClients.isEmpty { setupCard }
                    if shell.reach == .ready { shells }
                }
                .padding(.horizontal, 16)
                .padding(.top, 4)
                .padding(.bottom, 24)
                .animation(.easeOut(duration: 0.3), value: shell.reach)
            }
            .background(PTColor.background)
            .navigationTitle(macName)
            .navigationBarTitleDisplayMode(shell.macs.count > 1 ? .inline : .large)
            .toolbarTitleMenu {
                if shell.macs.count > 1 {
                    Picker("Mac", selection: $shell.selectedMacID) {
                        ForEach(shell.macs, id: \.macID) { Text($0.macName).tag(Optional($0.macID)) }
                    }
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                        .accessibilityLabel("Settings")
                }
            }
        }
        .sheet(item: $momentNeedingFaceID) { moment in
            VPNOffSheet(macName: macName, killSwitch: state?.killSwitch == true, reason: "Switching to \(moment.title) turns it off") {
                apply(moment)
            }
        }
        .sheet(isPresented: $router.showStepAway) {
            StepAwaySheet(shell: shell, macName: macName, online: onlineThroughPhone) {
                apply(.away)
                UserDefaults.standard.set(Date.now.timeIntervalSince1970, forKey: ActivityTab.steppedAwayKey)
                MacActivityController.shared.stepAway(macName: macName, state: shell.macState, sessions: shell.sessions)
            }
        }
        #if DEBUG
        .onAppear {
            let env = ProcessInfo.processInfo.environment
            if env["PASSTHROUGH_SHOW_VPN_OFF"] == "1" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { confirmVPNOff = true }
            }
            if env["PASSTHROUGH_SHOW_STEP_AWAY"] == "1" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { router.showStepAway = true }
            }
        }
        #endif
    }

    // MARK: Needs you

    /// Shells that went quiet on a question; the answer is typed in the terminal, as always.
    @ViewBuilder private var needsYou: some View {
        let waiting = shell.sessions.filter { $0.running && $0.waiting != nil }
        ForEach(waiting, id: \.id) { session in
            Button { router.terminal = .attach(session.id) } label: {
                HStack(spacing: 12) {
                    NeedsYouDot()
                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(session.title) is asking").font(.subheadline.weight(.semibold)).lineLimit(1)
                        Text(session.waiting ?? "")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    Spacer(minLength: 8)
                    Text("Answer").font(.subheadline.weight(.semibold)).foregroundStyle(PTColor.attentionText)
                }
                .padding(14)
                .frame(minHeight: 60)
                .background(PTColor.attention.opacity(0.1), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(PTColor.attention.opacity(0.35)))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens the terminal at that session")
            .transition(.move(edge: .top).combined(with: .opacity))
        }
        .sensoryFeedback(.warning, trigger: waiting.count) { old, new in new > old }
    }

    // MARK: Moments

    private var currentMoment: Moment? {
        guard let state else { return nil }
        return Moment.current(internet: model.state.isActive, awake: state.awake == true, vpn: state.vpnUp)
    }

    private func moments(_ state: MacState) -> some View {
        let shown = picked ?? currentMoment ?? .custom
        return VStack(alignment: .leading, spacing: 10) {
            Picker("Moment", selection: Binding(get: { shown }, set: { pick($0, state) })) {
                ForEach(Moment.choices) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .controlSize(.large)
            .accessibilityHint("Sets Internet, Keep awake and the VPN together")
            Text(momentNote ?? shown.caption)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .contentTransition(.opacity)
                .padding(.horizontal, 4)
            Button { router.showStepAway = true } label: {
                HStack(spacing: 12) {
                    Image(systemName: "figure.walk")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(PTColor.tintText)
                        .frame(width: 32, height: 32)
                        .background(PTColor.tint.opacity(0.16), in: Circle())
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Step away").font(.subheadline.weight(.semibold))
                        Text("Check what would stop it working while you're gone").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                }
                .padding(12)
                .frame(minHeight: 56)
                .background(PTColor.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(PTColor.hairline))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .animation(.easeOut(duration: 0.25), value: shown)
        .onChange(of: currentMoment) { _, now in if now == picked { picked = nil } }
    }

    private func pick(_ moment: Moment, _ state: MacState) {
        momentNote = nil
        guard let target = moment.switches else { return }
        if target.vpn == true, state.vpn == nil {
            momentNote = "\(moment.title) needs a VPN set up on \(macName). Add one in Passthrough's VPN settings on the Mac."
            return
        }
        // Lowering protection asks first; raising it never does.
        if target.vpn == false, state.vpnUp { return momentNeedingFaceID = moment }
        apply(moment)
    }

    /// Sets Internet, Keep awake and the VPN to the moment's, changing only what differs.
    private func apply(_ moment: Moment) {
        guard let target = moment.switches, let state else { return }
        picked = moment
        if target.internet != model.state.isActive { target.internet ? model.start() : model.stop() }
        if target.awake != (state.awake == true) { shell.control(.awake(target.awake)) }
        if let vpn = target.vpn, vpn != state.vpnUp { shell.control(.vpn(vpn)) }
        // If the Mac refuses or something lags, stop showing the pick after a while.
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(8))
            if picked == moment { picked = nil }
        }
    }

    // MARK: Tiles

    /// Keep awake and the VPN appear once the Mac says how they are; they only work while it's reachable.
    private var state: MacState? { shell.macState }
    private var canControl: Bool { shell.reach == .ready && state?.control == true }

    private var tiles: some View {
        VStack(spacing: 10) {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                Button { model.toggle() } label: {
                    MacTile(title: "Internet", detail: internetDetail, symbol: "wifi", on: model.state.isActive)
                }
                .disabled(model.state == .starting || model.state == .stopping)
                .accessibilityHint(model.state.isActive ? "Stops sharing this iPhone's connection" : "Shares this iPhone's connection with the Mac")

                if let state {
                    Button { tapAwake(state) } label: {
                        MacTile(title: "Keep awake", detail: awakeDetail(state), symbol: "cup.and.saucer",
                                on: state.awake == true, pending: shell.pendingControl.map { if case .awake = $0 { true } else { false } } ?? false)
                    }
                    .disabled(!canControl)

                    Button { tapVPN(state) } label: {
                        MacTile(title: "VPN", detail: vpnDetail(state), symbol: "lock.shield",
                                on: state.vpn == MacState.vpnOn || state.vpn == MacState.vpnConnecting,
                                pending: shell.pendingControl.map { if case .vpn = $0 { true } else { false } } ?? false,
                                warning: state.vpn == MacState.vpnFailed)
                    }
                    .disabled(!canControl || state.vpn == nil)
                }

                Button { router.showScreen = true } label: {
                    MacTile(title: "Screen", detail: shell.reach == .ready ? "See and control" : "When it's reachable", symbol: "display", on: false)
                }
                .disabled(shell.reach != .ready)
            }
            .buttonStyle(MacTileButtonStyle())
            .sensoryFeedback(.selection, trigger: model.state.isActive)
            .sensoryFeedback(.selection, trigger: state?.awake)
            .sensoryFeedback(.selection, trigger: state?.vpn)

            if let message = shell.controlError?.message ?? links.note ?? controlNote {
                Label(message, systemImage: "info.circle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .confirmationDialog("Let \(macName) sleep?", isPresented: $confirmSleep, titleVisibility: .visible) {
            Button("Let it sleep") { shell.control(.awake(false)) }
        } message: {
            Text(runningShells == 1 ? "1 running shell pauses until it wakes." : "\(runningShells) running shells pause until it wakes.")
        }
        .sheet(isPresented: $confirmVPNOff) {
            VPNOffSheet(macName: macName, killSwitch: state?.killSwitch == true) { shell.control(.vpn(false)) }
        }
    }

    private var runningShells: Int { shell.sessions.filter(\.running).count }

    /// Why Keep awake and the VPN can't be changed right now, if the Mac said so.
    private var controlNote: String? {
        guard shell.reach == .ready, let state, state.control != true else { return nil }
        return "Keep awake and the VPN can be changed from \(macName) only. To change them from here, turn on Awake & VPN for this iPhone in Passthrough's Remote Shell settings on the Mac."
    }

    private func tapAwake(_ state: MacState) {
        if state.awake == true {
            if runningShells > 0 { confirmSleep = true } else { shell.control(.awake(false)) }
        } else {
            shell.control(.awake(true))
        }
    }

    private func tapVPN(_ state: MacState) {
        // Turning protection on never asks; turning it off asks for Face ID, in the app only.
        if state.vpn == MacState.vpnOff { shell.control(.vpn(true)) } else { confirmVPNOff = true }
    }

    private func awakeDetail(_ state: MacState) -> String {
        if state.awake == true {
            if state.charging == true { return "On, plugged in" }
            if let minutes = state.minutesLeft { return Self.duration(minutes) + " left" }
            return "On, even lid closed"
        }
        switch state.awakeStopped {
        case "battery": return "Stopped at battery limit"
        case "heat": return "Stopped: running hot"
        default: return "Sleeps as usual"
        }
    }

    private func vpnDetail(_ state: MacState) -> String {
        switch state.vpn {
        case MacState.vpnOn: state.vpnName ?? "On"
        case MacState.vpnConnecting: "Connecting…"
        case MacState.vpnFailed: state.killSwitch == true ? "Failed, traffic blocked" : "Failed"
        case MacState.vpnOff: "Off"
        default: "Not set up on the Mac"
        }
    }

    /// "3 h 10 m", "45 m".
    static func duration(_ minutes: Int) -> String {
        minutes >= 60 ? "\(minutes / 60) h \(minutes % 60) m" : "\(minutes) m"
    }

    private var internetDetail: String {
        switch model.state {
        case .running: onlineThroughPhone ? "Mac online via this iPhone" : "On, waiting for the Mac"
        case .starting: "Starting…"
        case .stopping: "Stopping…"
        case .failed: "Couldn't start"
        case .stopped: "Off"
        }
    }

    // MARK: Shells

    private var shells: some View {
        PTSurface(padding: 14) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Shells").font(.headline)
                    Spacer()
                    if !shell.sessions.isEmpty {
                        Button("See all") { tab = .shells }
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(PTColor.tintText)
                            .frame(minHeight: 44)
                    }
                }
                if shell.sessions.isEmpty {
                    Text("Nothing running. Start a shell to run commands on \(macName).")
                        .font(.subheadline).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.bottom, 6)
                    Button { router.terminal = .new } label: { Label("New shell", systemImage: "plus") }
                        .buttonStyle(PTProminentButtonStyle())
                } else {
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        VStack(spacing: 0) {
                            ForEach(Self.recent(shell.sessions), id: \.id) { session in
                                sessionRow(session, now: context.date)
                            }
                        }
                    }
                    Button { router.terminal = .new } label: {
                        Label("New shell", systemImage: "plus")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(PTColor.tintText)
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    /// Running sessions first, most recent output first; at most three.
    static func recent(_ sessions: [ShellSessionInfo]) -> [ShellSessionInfo] {
        Array(sessions.sorted { ($0.running ? 1 : 0, $0.lastOutputAt) > ($1.running ? 1 : 0, $1.lastOutputAt) }.prefix(3))
    }

    private func sessionRow(_ session: ShellSessionInfo, now: Date) -> some View {
        Button { router.terminal = .attach(session.id) } label: {
            HStack(spacing: 12) {
                Circle().fill(session.running ? PTColor.tint : Color.secondary.opacity(0.4)).frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Text(RemoteShellCard.status(session, now: now)).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .frame(minHeight: 50)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens the terminal")
    }

    // MARK: Setup

    private var setupCard: some View {
        PTSurface {
            VStack(alignment: .leading, spacing: 14) {
                Text("Reach it from anywhere").font(.headline)
                Text("Open its shell and see its screen from this iPhone, even away from home.")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ShellSetupSteps(paired: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Hero

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
        case .locked, .needsPasscode, .keyUnavailable: return "Needs you"
        }
    }

    private var detail: String? {
        if !paired { return "Pair once over USB." }
        switch shell.reach {
        case .ready:
            if awake, let state = shell.macState {
                if state.charging == true { return "Plugged in" }
                if let minutes = state.minutesLeft { return MacHomeView.duration(minutes) + " left" }
                return "Even with the lid closed"
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
                    if shell.macState?.awakeStopped == "battery" {
                        Text("It most likely went to sleep").font(.subheadline.weight(.semibold)).foregroundStyle(PTColor.attentionText)
                        Text("Its battery reached your \(Self.percent(shell.macState?.batteryFloor ?? 0.2)) limit, so Keep awake let it sleep. Plug it in and it wakes for the next connection.")
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

    static func percent(_ fraction: Double) -> String { "\(Int((fraction * 100).rounded()))%" }
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
        .accessibilityLabel("Battery \(MacHeroCard.percent(battery)). \(caption)")
    }

    private var caption: String {
        let level = MacHeroCard.percent(battery)
        if state.charging == true { return "\(level), charging" }
        guard awake else { return "\(level) on battery" }
        var limits: [String] = []
        if let floor = state.batteryFloor { limits.append("at \(MacHeroCard.percent(floor))") }
        limits.append("if it gets hot")
        return "\(level) now · sleeps " + limits.joined(separator: " or ")
    }
}

/// The one thing that keeps moving: a shell is waiting on you. Still under Reduce Motion.
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

// MARK: - Tiles

struct MacTile: View {
    let title: String
    let detail: String
    let symbol: String
    let on: Bool
    /// Sent to the Mac and not yet answered.
    var pending = false
    /// On, but not working (a failed VPN).
    var warning = false
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        VStack(alignment: .leading) {
            ZStack {
                if pending {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: warning ? "exclamationmark.triangle.fill" : symbol)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(warning ? PTColor.onAttention : on ? PTColor.onTint : Color.primary)
                }
            }
            .frame(width: 36, height: 36)
            .background(warning ? PTColor.attention : on ? PTColor.tint : Color.primary.opacity(0.08), in: Circle())
            Spacer(minLength: 10)
            Text(title).font(.subheadline.weight(.semibold))
            Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, minHeight: 104, alignment: .leading)
        .padding(14)
        .background(on ? PTColor.surfaceOn : PTColor.surface, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous)
            .strokeBorder(on ? PTColor.tint.opacity(0.45) : PTColor.hairline, lineWidth: 1))
        .opacity(enabled ? 1 : 0.5)
        .animation(.easeOut(duration: 0.25), value: on)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

struct MacTileButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
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
