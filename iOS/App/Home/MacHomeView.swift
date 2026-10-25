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
    }

    // MARK: Tiles

    private var tiles: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
            Button { model.toggle() } label: {
                MacTile(title: "Internet", detail: internetDetail, symbol: "wifi", on: model.state.isActive)
            }
            .disabled(model.state == .starting || model.state == .stopping)
            .accessibilityHint(model.state.isActive ? "Stops sharing this iPhone's connection" : "Shares this iPhone's connection with the Mac")

            Button { router.showScreen = true } label: {
                MacTile(title: "Screen", detail: shell.reach == .ready ? "See and control" : "When it's reachable", symbol: "display", on: false)
            }
            .disabled(shell.reach != .ready)
        }
        .buttonStyle(MacTileButtonStyle())
        .sensoryFeedback(.selection, trigger: model.state.isActive)
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
                    MacFigure(asleep: shell.reach == .unreachable, live: shell.reach == .ready || online)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(title).font(.title3.weight(.bold))
                            .contentTransition(.opacity)
                        if let detail { Text(detail).font(.subheadline).foregroundStyle(.secondary) }
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

    private var title: String {
        if !paired { return "Set up your Mac" }
        switch shell.reach {
        case .ready: return "Reachable"
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
                    Text("It may be asleep, off, or offline").font(.subheadline.weight(.semibold)).foregroundStyle(PTColor.attentionText)
                    if let message = shell.reachMessage {
                        Text(message).font(.subheadline).fixedSize(horizontal: false, vertical: true)
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

// MARK: - Tiles

struct MacTile: View {
    let title: String
    let detail: String
    let symbol: String
    let on: Bool
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        VStack(alignment: .leading) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(on ? PTColor.onTint : Color.primary)
                .frame(width: 36, height: 36)
                .background(on ? PTColor.tint : Color.primary.opacity(0.08), in: Circle())
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

/// A laptop: lid open while it's reachable or online, shut and dozing when it can't be reached.
struct MacFigure: View {
    let asleep: Bool
    let live: Bool

    var body: some View {
        ZStack(alignment: .bottom) {
            if asleep {
                closed.transition(.opacity)
            } else {
                open.transition(.opacity)
            }
        }
        .frame(width: 104, height: 76)
        .animation(.easeOut(duration: 0.35), value: asleep)
        .accessibilityElement()
        .accessibilityLabel(asleep ? "Mac, not answering" : "Mac")
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
            VStack(spacing: 0) {
                Spacer()
                LidShape()
                    .fill(Color.primary.opacity(0.14))
                    .frame(width: 104, height: 12)
                base
            }
            Text("z").font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(.secondary)
                .offset(x: -6, y: 22)
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
