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
    /// A picked moment that lets the Mac sleep while shells run, waiting on "Let it sleep".
    @State private var momentLettingSleep: Moment?
    @State private var confirmVPNOff = false
    /// A moment just picked, shown until the switches catch up with it.
    @State private var picked: Moment?
    /// A picked moment that turns the VPN off, waiting for Face ID.
    @State private var momentNeedingFaceID: Moment?
    @State private var momentNote: String?
    @ObservedObject private var links = PendingLinks.shared
    @Environment(\.dynamicTypeSize) private var typeSize

    /// The Mac on screen: the shell's selection, else the first paired Mac.
    private var macID: String? { shell.selectedMacID ?? model.pairedClients.first?.id }
    private var macName: String { shell.selectedMacName }
    private var onlineThroughPhone: Bool { macID.map(model.connectedMacIDs.contains) ?? false }
    private var paired: Bool { !model.pairedClients.isEmpty || !shell.macs.isEmpty }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    MacHeroCard(shell: shell, paired: paired, online: onlineThroughPhone,
                                lastSeen: model.pairedClients.first { $0.id == macID }?.lastSeen, showPairing: $showPairing)
                    if shell.reach == .ready { needsYou }
                    if state != nil, canControl { moments }
                    if paired { stepAwayEntry }
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
            StepAwaySheet(shell: shell, online: onlineThroughPhone) {
                // Only once Away is actually asked for: Step away is disabled otherwise.
                guard apply(.away) else { return }
                StepAwayStore.record()
                MacActivityController.shared.stepAway(.init(macID: shell.selectedMacID, macName: macName, reachable: true,
                                                            lastHeard: nil, state: shell.macState, sessions: shell.sessions))
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
        let waiting = shell.sessions.filter(\.isAsking)
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

    private var currentMoment: Moment? { state?.moment(phoneSharing: model.state.isActive) }

    private var moments: some View {
        let shown = picked ?? currentMoment ?? .custom
        return VStack(alignment: .leading, spacing: 10) {
            Picker("Moment", selection: Binding(get: { shown }, set: { pick($0) })) {
                ForEach(Moment.choices) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .controlSize(.large)
            .accessibilityHint("Sets Internet, Keep awake and the VPN together")
            Text(momentNote ?? shown.caption(phone: "this iPhone", fromAnywhere: shell.selectedReachesFromAnywhere))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .contentTransition(.opacity)
                .padding(.horizontal, 4)
        }
        .animation(.easeOut(duration: 0.25), value: shown)
        .onChange(of: currentMoment) { _, now in if now == picked { picked = nil } }
    }

    /// Before leaving: shown whenever there's a Mac; the sheet says when it can't switch to Away.
    private var stepAwayEntry: some View {
        Button { router.showStepAway = true } label: {
            HStack(spacing: 12) {
                Image(systemName: "figure.walk")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(PTColor.tintText)
                    .frame(width: 32, height: 32)
                    .background(PTColor.tint.opacity(0.16), in: Circle())
                    .accessibilityHidden(true)
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

    /// The moment's changes from the switches as they are now; nil for `custom` or without the Mac's state.
    private func plan(_ moment: Moment) -> MomentPlan? {
        guard let state else { return nil }
        return moment.plan(internet: state.internet ?? model.state.isActive, awake: state.awake == true, vpn: state.vpnUp)
    }

    /// Picking a moment: letting the Mac sleep while shells run asks first,
    /// then lowering the VPN asks for Face ID; raising protection never asks.
    private func pick(_ moment: Moment) {
        momentNote = nil
        guard let plan = plan(moment), let state else { return }
        if plan.needsVPN, state.vpn == nil {
            momentNote = "\(moment.title) needs a VPN set up on \(macName). Add one in Passthrough's VPN settings on the Mac."
            return
        }
        if plan.letsSleep, runningShells > 0 {
            momentLettingSleep = moment
            confirmSleep = true
            return
        }
        afterSleepCheck(moment)
    }

    private func afterSleepCheck(_ moment: Moment) {
        if plan(moment)?.lowersVPN == true { momentNeedingFaceID = moment } else { apply(moment) }
    }

    /// Sets Internet, Keep awake and the VPN to the moment's, changing only
    /// what differs. False when nothing could be sent (the Mac isn't connected).
    @discardableResult
    private func apply(_ moment: Moment) -> Bool {
        guard let plan = plan(moment) else { return false }
        guard plan.awake == nil && plan.vpn == nil || canControl else {
            momentNote = shell.reach == .ready ? ShellError.notAllowed.message
                : "\(macName) isn't connected right now, so nothing changed. Try again once it shows as reachable."
            return false
        }
        picked = moment
        if let on = plan.internet, on != model.state.isActive { on ? model.start() : model.stop() }
        if let awake = plan.awake { shell.control(.awake(awake)) }
        if let vpn = plan.vpn { shell.control(.vpn(vpn)) }
        // If the Mac refuses or something lags, stop showing the pick after a while.
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(ShellModel.controlTimeout))
            if picked == moment { picked = nil }
        }
        return true
    }

    // MARK: Tiles

    /// Keep awake and the VPN appear once the Mac says how they are; they only work while it's reachable.
    private var state: MacState? { shell.macState }
    private var canControl: Bool { shell.reach == .ready && state?.control == true }

    private var tiles: some View {
        VStack(spacing: 10) {
            // One column at accessibility sizes, so titles and details have room.
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: typeSize.isAccessibilitySize ? 1 : 2), spacing: 10) {
                Button { model.toggle() } label: {
                    MacTile(title: "Internet", detail: internetDetail, symbol: "wifi", on: model.state.isActive)
                }
                .disabled(model.state == .starting || model.state == .stopping)
                .accessibilityHint(model.state.isActive ? "Stops sharing this iPhone's connection" : "Shares this iPhone's connection with the Mac")

                if let state {
                    Button { tapAwake(state) } label: {
                        MacTile(title: "Keep awake", detail: awakeDetail(state), symbol: "cup.and.saucer",
                                on: state.awake == true, pending: shell.isPending(.awake))
                    }
                    .disabled(!canControl)

                    Button { tapVPN(state) } label: {
                        // A failed VPN still holds its block: on, so a tap turns it off.
                        MacTile(title: "VPN", detail: vpnDetail(state), symbol: "lock.shield",
                                on: state.vpnUp, pending: shell.isPending(.vpn),
                                warning: state.vpn == MacState.vpnFailed)
                    }
                    .disabled(!canControl || state.vpn == nil)
                }

                Button { router.showScreen = true } label: {
                    MacTile(title: "Screen", detail: shell.reach == .ready ? "See and control" : "When it's reachable", symbol: "display",
                            on: false, toggle: false)
                }
                .disabled(shell.reach != .ready)
            }
            .buttonStyle(MacTileButtonStyle())
            .sensoryFeedback(.selection, trigger: model.state.isActive)
            .sensoryFeedback(.selection, trigger: state?.awake)
            .sensoryFeedback(.selection, trigger: state?.vpn)

            if let message = shell.controlMessage ?? links.note ?? controlNote {
                Label(message, systemImage: "info.circle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .confirmationDialog("Let \(macName) sleep?", isPresented: $confirmSleep, titleVisibility: .visible) {
            Button("Let it sleep") {
                guard let moment = momentLettingSleep else { return shell.control(.awake(false)) }
                momentLettingSleep = nil
                // Then Face ID, if the moment also turns the VPN off, once the dialog is gone.
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(350))
                    afterSleepCheck(moment)
                }
            }
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
            if runningShells > 0 {
                momentLettingSleep = nil
                confirmSleep = true
            } else {
                shell.control(.awake(false))
            }
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
            if let minutes = state.minutesLeft { return MacFormat.duration(minutes: minutes) + " left" }
            return state.hasLid ? "On, lid closed OK" : "On"
        }
        switch state.awakeStopped {
        case MacState.stoppedBattery: return "Stopped at battery limit"
        case MacState.stoppedHeat: return "Stopped: running hot"
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
    /// A switch (read as on or off), not a button that opens something.
    var toggle = true
    @Environment(\.isEnabled) private var enabled
    @Environment(\.dynamicTypeSize) private var typeSize

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
            .accessibilityHidden(true)
            .frame(width: 36, height: 36)
            .background(warning ? PTColor.attention : on ? PTColor.tint : Color.primary.opacity(0.08), in: Circle())
            Spacer(minLength: 10)
            Text(title).font(.subheadline.weight(.semibold))
            Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(typeSize.isAccessibilitySize ? 2 : 1)
        }
        .frame(maxWidth: .infinity, minHeight: 104, alignment: .leading)
        .padding(14)
        .background(on ? PTColor.surfaceOn : PTColor.surface, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous)
            .strokeBorder(on ? PTColor.tint.opacity(0.45) : PTColor.hairline, lineWidth: 1))
        .opacity(enabled ? 1 : 0.5)
        .animation(.easeOut(duration: 0.25), value: on)
        .accessibilityElement(children: .combine)
        .accessibilityValue(toggle ? (pending ? "Waiting for Mac" : on ? "On" : "Off") : "")
        .accessibilityAddTraits(toggle ? .isToggle : [])
    }
}

struct MacTileButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}
