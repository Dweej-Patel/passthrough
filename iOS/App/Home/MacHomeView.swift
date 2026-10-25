import SwiftUI
import PassthroughCore
import PassthroughUI

/// The Mac tab: the Mac itself, its switches (each says why when it can't
/// change), this iPhone one tap in, and its shells.
struct MacHomeView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var router: ShellRouter
    @ObservedObject var shell: ShellModel
    @Binding var tab: RootTab
    @Binding var showPairing: Bool
    @Binding var showSettings: Bool
    @State private var confirmSleep = false
    @State private var confirmVPNOff = false
    /// The switch last changed here, so a refusal without a switch named lands under it.
    @State private var lastTouched: MacSwitch?
    @ObservedObject private var links = PendingLinks.shared

    /// The Mac on screen: the shell's selection, else the first paired Mac.
    private var macID: String? { shell.selectedMacID ?? model.pairedClients.first?.id }
    private var macName: String { shell.selectedMacName }
    private var onlineThroughPhone: Bool { macID.map(model.connectedMacIDs.contains) ?? false }
    private var paired: Bool { !model.pairedClients.isEmpty || !shell.macs.isEmpty }

    var body: some View {
        NavigationStack {
            ScrollViewReader { scroller in
                ScrollView {
                    VStack(spacing: 14) {
                        MacHeroCard(shell: shell, paired: paired, online: onlineThroughPhone,
                                    lastSeen: model.pairedClients.first { $0.id == macID }?.lastSeen, showPairing: $showPairing)
                        if shell.reach == .ready { needsYou }
                        switches
                        thisPhoneRow
                        if shell.reach == .noAccess, !model.pairedClients.isEmpty { setupCard }
                        if shell.reach == .ready { shells }
                        Color.clear.frame(height: 0).id("end")
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 4)
                    .padding(.bottom, 24)
                    .animation(.easeOut(duration: 0.3), value: shell.reach)
                }
                #if DEBUG
                .onAppear {
                    // Screenshots of the lower half.
                    guard ProcessInfo.processInfo.environment["PASSTHROUGH_SCROLL"] == "end" else { return }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { scroller.scrollTo("end", anchor: .bottom) }
                }
                #endif
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
            .navigationDestination(isPresented: $router.showThisPhone) {
                ThisPhoneView(showPairing: $showPairing, showSettings: $showSettings)
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
        #if DEBUG
        .onAppear {
            if ProcessInfo.processInfo.environment["PASSTHROUGH_SHOW_VPN_OFF"] == "1" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { confirmVPNOff = true }
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

    // MARK: Switches

    /// Keep awake and the VPN show as the Mac last said; they only change while it's reachable.
    private var state: MacState? { shell.macState }
    private var runningShells: Int { shell.sessions.filter(\.running).count }

    /// Internet first (this phone's own, always there), then what's on the
    /// Mac. A reason shared by several switches shows once, right under them.
    private var switches: some View {
        PTSurface(padding: 6) {
            VStack(alignment: .leading, spacing: 0) {
                internetRow
                if paired {
                    Divider().padding(.leading, 58)
                    awakeRow
                    Divider().padding(.leading, 58)
                    vpnRow
                    if let reason = controlBlock { SwitchNote(problem: reason).padding(.horizontal, 10).padding(.bottom, 10) }
                    Divider().padding(.leading, 58)
                    screenRow
                    if let reason = reachBlock { SwitchNote(problem: reason).padding(.horizontal, 10).padding(.bottom, 10) }
                }
                if let note = links.note {
                    SwitchNote(problem: .init(note, warning: true, fix: ("OK", { links.note = nil })))
                        .padding(.horizontal, 10).padding(.bottom, 10)
                }
            }
        }
        .sensoryFeedback(.selection, trigger: model.state.isActive)
        .sensoryFeedback(.selection, trigger: state?.awake)
        .sensoryFeedback(.selection, trigger: state?.vpn)
        .animation(.easeOut(duration: 0.25), value: shell.controlMisses)
    }

    // MARK: Internet

    /// The Mac is online through this phone: this phone sees it, or the Mac says so.
    private var macOnline: Bool {
        onlineThroughPhone || (model.state == .running && shell.reach == .ready && state?.internet == true)
    }

    private var internetRow: some View {
        SwitchRow(title: "Internet through this iPhone", symbol: "wifi",
                  status: internetStatus, isOn: model.state.isActive,
                  pending: model.state == .starting || model.state == .stopping,
                  problem: internetProblem) { on in on ? model.start() : model.stop() }
            .accessibilityHint(model.state.isActive ? "Stops sharing this iPhone's internet with the Mac" : "Shares this iPhone's internet with the Mac")
    }

    private var internetStatus: String {
        switch model.state {
        case .running: macOnline ? "Mac online through this iPhone" : "Sharing \u{2014} waiting for the Mac"
        case .starting: "Turning on\u{2026}"
        case .stopping: "Turning off\u{2026}"
        case .failed: "Off \u{2014} couldn't turn on"
        case .stopped: "Off"
        }
    }

    private var internetProblem: SwitchProblem? {
        switch model.state {
        case .failed(let message):
            return .init(message, warning: true, fix: ("Try again", { model.start() }))
        case .stopped where !paired:
            return .init("Turn this on, then pair your Mac. Its traffic goes through this iPhone over the cable.")
        case .running:
            if model.pairedClients.isEmpty {
                return .init("Now pair your Mac: plug in the cable and enter a code in Passthrough on the Mac.", fix: ("Pair", { showPairing = true }))
            }
            if model.sharingWiFiInsteadOfCellular {
                return .init("This iPhone is on Wi-Fi, so the Mac gets Wi-Fi, not cellular. Turn off Wi-Fi to share cellular.")
            }
            if !macOnline {
                return .init("Plug the Mac into this iPhone, then connect from Passthrough in the Mac's menu bar.")
            }
            return nil
        default:
            return nil
        }
    }

    // MARK: Keep awake

    private var awakeRow: some View {
        let pending = shell.pendingControls[.awake]
        let block = awakeBlock
        return SwitchRow(title: "Keep Mac awake", symbol: "cup.and.saucer.fill",
                         status: awakeStatus, isOn: pending?.on ?? (state?.awake == true),
                         pending: pending != nil, enabled: !sharedBlock && block == nil,
                         problem: sharedBlock ? nil : block ?? awakeProblem) { on in
            lastTouched = .awake
            if on {
                shell.control(.awake(true))
                MacActivityController.shared.keepAwakeAsked(.init(macID: shell.selectedMacID, macName: macName, reachable: true,
                                                                  lastHeard: nil, state: state, sessions: shell.sessions))
            } else if runningShells > 0 {
                confirmSleep = true
            } else {
                shell.control(.awake(false))
            }
        }
    }

    private var awakeStatus: String {
        guard let state else { return "Not known yet" }
        guard state.awake == true else { return "Off \u{2014} sleeps as usual" }
        if state.charging == true { return state.hasLid ? "On \u{2014} plugged in, fine with the lid closed" : "On \u{2014} plugged in" }
        if let minutes = state.minutesLeft {
            let until = state.batteryFloor.map { " until \(MacFormat.percent($0)) battery" } ?? " of battery"
            return "On \u{2014} about \(MacFormat.duration(minutes: minutes))" + until
        }
        return state.hasLid ? "On \u{2014} fine with the lid closed" : "On"
    }

    /// Why Keep awake can't turn on now, on the Mac's own terms: the switch is off and stays disabled.
    private var awakeBlock: SwitchProblem? {
        guard let state, state.awake != true else { return nil }
        if let floor = state.batteryFloor, let battery = state.battery, state.charging != true, battery <= floor + 0.001 {
            return .init("The Mac's battery is at its \(MacFormat.percent(floor)) limit, so it won't stay awake. Plug it in to turn this on.")
        }
        if state.awakeStopped == MacState.stoppedHeat, state.hot == true {
            return .init("The Mac is running hot, so it won't stay awake. This turns on again once it cools down.")
        }
        return nil
    }

    /// What happened to the last change, or why the Mac last turned it off itself.
    private var awakeProblem: SwitchProblem? {
        if let miss = shell.controlMisses[.awake] {
            let retry: (String, () -> Void) = ("Try again", { shell.control(.awake(miss.on)) })
            guard miss.answered else {
                return .init("\(macName) didn't answer, so Keep awake may not have changed.", warning: true, fix: retry)
            }
            guard miss.on else { return .init("\(macName) kept itself awake.", warning: true, fix: retry) }
            switch state?.awakeStopped {
            case MacState.stoppedBattery: return .init("\(macName) said no: its battery is at the limit. Plug it in, then try again.", warning: true, fix: retry)
            case MacState.stoppedHeat: return .init("\(macName) said no: it's running hot. Try again once it cools down.", warning: true, fix: retry)
            default: return .init("\(macName) didn't turn Keep awake on.", warning: true, fix: retry)
            }
        }
        if lastTouched == .awake, let message = shell.controlMessage { return .init(message, warning: true) }
        guard let state, state.awake != true else { return nil }
        switch state.awakeStopped {
        case MacState.stoppedBattery:
            return .init("It turned itself off at the \(MacFormat.percent(state.batteryFloor ?? 0.2)) battery limit.")
        case MacState.stoppedHeat:
            return .init("It turned itself off because the Mac got hot.")
        default:
            return nil
        }
    }

    // MARK: VPN

    private var vpnRow: some View {
        let pending = shell.pendingControls[.vpn]
        let failed = state?.vpn == MacState.vpnFailed
        let block = vpnBlock
        // A failed VPN still holds its block: on, so turning it off is the way out.
        return SwitchRow(title: "VPN", symbol: "lock.shield.fill",
                         status: vpnStatus, warning: failed, isOn: pending?.on ?? (state?.vpnUp == true),
                         pending: pending != nil, enabled: !sharedBlock && block == nil,
                         problem: sharedBlock ? nil : block ?? vpnProblem) { on in
            lastTouched = .vpn
            // Turning protection on never asks; turning it off asks for Face ID, in the app only.
            if on { shell.control(.vpn(true)) } else { confirmVPNOff = true }
        }
    }

    private var vpnStatus: String {
        guard let state else { return "Not known yet" }
        switch state.vpn {
        case MacState.vpnOn: return "On" + (state.vpnName.map { " \u{2014} \($0)" } ?? "")
        case MacState.vpnConnecting: return "Connecting\u{2026}"
        case MacState.vpnFailed: return state.killSwitch == true ? "Not connected \u{2014} the kill switch is blocking traffic" : "On, but not connected"
        case MacState.vpnOff: return "Off" + (state.vpnName.map { " \u{2014} \($0)" } ?? "")
        default: return "Not set up"
        }
    }

    private var vpnBlock: SwitchProblem? {
        guard let state, state.vpn == nil else { return nil }
        return .init("No VPN is set up on \(macName). Add one in Passthrough's VPN settings on the Mac.")
    }

    private var vpnProblem: SwitchProblem? {
        if let miss = shell.controlMisses[.vpn] {
            let retry: (String, () -> Void) = ("Try again", { miss.on ? shell.control(.vpn(true)) : (confirmVPNOff = true) })
            guard miss.answered else {
                return .init("\(macName) didn't answer, so the VPN may not have changed.", warning: true, fix: retry)
            }
            return .init(miss.on ? "\(macName) didn't turn the VPN on." : "\(macName) kept the VPN on.", warning: true, fix: retry)
        }
        if lastTouched == .vpn, let message = shell.controlMessage { return .init(message, warning: true) }
        if state?.vpn == MacState.vpnFailed {
            return .init("It keeps trying to reconnect. Turn it off if you need the Mac online without it.", warning: true)
        }
        return nil
    }

    // MARK: Screen

    private var screenRow: some View {
        Button { router.showScreen = true } label: {
            HStack(spacing: 12) {
                SwitchIcon(symbol: "display", on: false, warning: false)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Screen").font(.body.weight(.semibold))
                    Text("See and control the Mac's screen").font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right").font(.subheadline.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .padding(10)
            .frame(minHeight: 60)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(shell.reach != .ready)
        .opacity(shell.reach == .ready ? 1 : 0.55)
        .accessibilityHint("Opens the Mac's screen")
    }

    // MARK: Shared reasons

    /// Keep awake and the VPN can't change for a reason shown once under them; their own reasons wait.
    private var sharedBlock: Bool { reachBlock != nil || controlBlock != nil }

    /// Why nothing on the Mac can change from here (Keep awake, VPN, Screen): it isn't reachable.
    private var reachBlock: SwitchProblem? {
        switch shell.reach {
        case .ready: return nil
        case .connecting: return .init("Connecting to \(macName)\u{2026} These switches work once it's reachable.")
        case .unreachable:
            return .init("Can't reach \(macName) right now, so these can't change. They show how it was when it was last heard from.", warning: true)
        case .noAccess:
            return .init("To change these from this iPhone, set up Remote shell on the Mac. The steps are below.")
        case .locked, .needsPasscode, .keyUnavailable:
            return .init(shell.reachMessage ?? "Unlock Passthrough to change these.", warning: true)
        }
    }

    /// Why Keep awake and the VPN can't change from here though the Mac is reachable.
    private var controlBlock: SwitchProblem? {
        guard shell.reach == .ready else { return nil }
        guard let state else {
            return .init("Update Passthrough on \(macName) to change Keep awake and the VPN from here.")
        }
        guard state.control == true else {
            return .init("This iPhone isn't allowed to change Keep awake and the VPN. To allow it, on the Mac open Passthrough's Settings, go to Remote Shell and turn on Awake & VPN for this iPhone.")
        }
        return nil
    }

    // MARK: This iPhone

    private var thisPhoneRow: some View {
        Button { router.showThisPhone = true } label: {
            HStack(spacing: 12) {
                SwitchIcon(symbol: "iphone", on: false, warning: false)
                VStack(alignment: .leading, spacing: 2) {
                    Text("This iPhone").font(.body.weight(.semibold))
                    Text(!paired ? "Pair a Mac, data used, connection details" : "Paired Macs, data used, connection details")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right").font(.subheadline.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .padding(16)
            .frame(minHeight: 60)
            .background(PTColor.surface, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(PTColor.hairline))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens this iPhone's sharing, pairing and data use")
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

// MARK: - Switch rows

/// Why a switch can't change, or what went wrong, with a fix where this phone has one.
struct SwitchProblem {
    let text: String
    /// Something went wrong (amber), rather than how things are (grey).
    var warning = false
    var fix: (title: String, action: () -> Void)?

    init(_ text: String, warning: Bool = false, fix: (String, () -> Void)? = nil) {
        self.text = text
        self.warning = warning
        self.fix = fix.map { (title: $0.0, action: $0.1) }
    }
}

/// A plain on/off switch for the Mac: the system switch on the right, what
/// it's doing under the title, and why it can't change right under that.
struct SwitchRow: View {
    let title: String
    let symbol: String
    let status: String
    /// On, but not working (a failed VPN).
    var warning = false
    let isOn: Bool
    /// Sent and not yet answered: the switch shows where it's going.
    var pending = false
    var enabled = true
    var problem: SwitchProblem?
    let set: (Bool) -> Void
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Toggle(isOn: Binding(get: { isOn }, set: set)) {
                HStack(spacing: 12) {
                    // At accessibility sizes the words need the room.
                    if !typeSize.isAccessibilitySize {
                        SwitchIcon(symbol: symbol, on: isOn, warning: warning).opacity(enabled ? 1 : 0.5)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).font(.body.weight(.semibold))
                            .foregroundStyle(enabled ? .primary : .secondary)
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            if pending { ProgressView().controlSize(.mini) }
                            Text(status)
                                .font(.subheadline)
                                .foregroundStyle(warning ? PTColor.attentionText : .secondary)
                                .contentTransition(.opacity)
                        }
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .toggleStyle(.switch)
            .tint(PTColor.tint)
            .disabled(!enabled)
            .padding(10)
            .frame(minHeight: 60)
            .accessibilityValue(pending ? "Waiting for Mac" : isOn ? "On" : "Off")
            if let problem {
                SwitchNote(problem: problem)
                    .padding(.leading, typeSize.isAccessibilitySize ? 10 : 58)
                    .padding(.trailing, 10)
                    .padding(.bottom, 10)
            }
        }
        .animation(.easeOut(duration: 0.25), value: isOn)
        .animation(.easeOut(duration: 0.25), value: problem?.text)
    }
}

/// A reason under a switch (or a group of them), with its fix.
struct SwitchNote: View {
    let problem: SwitchProblem

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text(problem.text).fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: problem.warning ? "exclamationmark.triangle.fill" : "info.circle")
            }
            .font(.footnote)
            .foregroundStyle(problem.warning ? PTColor.attentionText : .secondary)
            if let fix = problem.fix {
                Button(fix.title, action: fix.action)
                    .font(.subheadline.weight(.semibold))
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .tint(problem.warning ? PTColor.attentionText : PTColor.tintText)
                    .frame(minHeight: 44)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(problem.warning ? 10 : 0)
        .background(problem.warning ? PTColor.attention.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

struct SwitchIcon: View {
    let symbol: String
    let on: Bool
    let warning: Bool

    var body: some View {
        Image(systemName: warning ? "exclamationmark.triangle.fill" : symbol)
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(warning ? PTColor.onAttention : on ? PTColor.onTint : Color.primary)
            .frame(width: 36, height: 36)
            .background(warning ? PTColor.attention : on ? PTColor.tint : Color.primary.opacity(0.08), in: Circle())
            .accessibilityHidden(true)
    }
}
