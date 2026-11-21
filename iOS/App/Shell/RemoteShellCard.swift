import SwiftUI
import PassthroughCore
import PassthroughUI

/// The Shells tab's card: setup steps until a Mac grants access, then the
/// selected Mac's sessions and the way into the terminal, screen and history.
struct RemoteShellCard: View {
    @ObservedObject var shell: ShellModel
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var router: ShellRouter

    private var selectedMacName: String {
        shell.macs.first { $0.macID == shell.selectedMacID }?.macName ?? shell.words.your
    }

    /// The setup steps' nouns: the selected computer's, or both kinds' with none paired.
    private var setupWords: HostWords {
        model.pairedClients.isEmpty ? .generic(device: ThisDevice.name) : shell.words
    }

    var body: some View {
        PTSurface {
            VStack(alignment: .leading, spacing: 14) {
                if !shell.macs.isEmpty { statusLine }
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .animation(.easeInOut(duration: 0.2), value: shell.reach)
    }

    /// Which Mac, and how it's reached: "● MacBook Pro ⌃⌄ · via relay".
    private var statusLine: some View {
        HStack(spacing: 8) {
            PTStatusDot(color: ShellStatusLabel.color(shell.reach), live: shell.reach == .ready)
            Text(selectedMacName).font(.subheadline.weight(.semibold)).lineLimit(1)
            Text(statusDetail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    private var statusDetail: String {
        switch shell.reach {
        case .ready: shell.path?.label.map { "Connected \($0)" } ?? "Connected"
        default: ShellStatusLabel.title(shell.reach, kind: shell.selectedKind)
        }
    }

    @ViewBuilder private var content: some View {
        switch shell.reach {
        case .noAccess:
            if shell.accessRefused, let message = shell.reachMessage {
                // It let this phone in once and now refuses: no steps, they were done.
                notice(message, icon: "exclamationmark.triangle.fill", tint: PTColor.attention)
            } else {
                Text("Open \(setupWords.your)'s shell right from this \(ThisDevice.name). To set it up:")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ShellSetupSteps(paired: !model.pairedClients.isEmpty, words: setupWords)
            }
        case .connecting:
            HStack(spacing: 10) {
                ProgressView()
                Text(shell.isRedialing ? "Reconnecting to \(selectedMacName)…" : "Connecting to \(selectedMacName)…")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        case .unreachable:
            notice(shell.reachMessage ?? "", icon: shell.farewell == nil ? "wifi.exclamationmark" : "moon.zzz.fill", tint: PTColor.attention)
            Button { shell.connect() } label: {
                Label("Try again", systemImage: "arrow.clockwise")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .tint(PTColor.tintText)
        case .locked, .needsPasscode, .keyUnavailable:
            notice(shell.reachMessage ?? "", icon: "exclamationmark.triangle.fill", tint: PTColor.attention)
        case .ready:
            if let why = HostCopy.shell(page.shell, shell.words) {
                // No shell can start there: why, in place of the list and New shell.
                notice(why, icon: "person.crop.circle.badge.exclamationmark", tint: PTColor.attention)
                    .onAppear { UIAccessibility.post(notification: .announcement, argument: why) }
            } else if shell.visibleSessions.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Text("No sessions open. Start one to run commands on \(selectedMacName).")
                        .font(.subheadline).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    newShell(.prominent)
                }
            } else {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(shell.visibleSessions, id: \.id) { session in
                            row(session, now: context.date)
                        }
                    }
                }
            }
            // A refusal the shell notice already says isn't said twice.
            if page.shell == .available, let message = shell.lastError?.message(for: shell.words) {
                notice(message, icon: "exclamationmark.triangle.fill", tint: PTColor.attention)
            }
            Divider().opacity(0.5)
            if page.screen != .noRow {
                Button { router.openScreen(shell) } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "display").foregroundStyle(PTColor.tintText)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("See and control the screen").foregroundStyle(.primary)
                            if page.screen != .available, let why = HostCopy.screen(page.screen, shell.words) {
                                Text(why).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                    }
                    .font(.subheadline.weight(.medium))
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!shell.canOpenScreen)
                .opacity(shell.canOpenScreen ? 1 : 0.55)
            }
            Button { router.showHistory = true } label: {
                HStack(spacing: 10) {
                    Image(systemName: "clock.arrow.circlepath").foregroundStyle(PTColor.tintText)
                    Text("Session history").foregroundStyle(.primary)
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                }
                .font(.subheadline.weight(.medium))
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private var page: HostPage { shell.page }

    private func newShell(_ style: NewShellControl.Style) -> some View {
        NewShellControl(shells: shell.shells(for: shell.selectedMacID), preferred: shell.preferredShell(for: shell.selectedMacID),
                        hostName: selectedMacName, style: style) { router.terminal = .new(shell: $0) }
    }

    private func notice(_ text: String, icon: String, tint: Color) -> some View {
        Label {
            Text(text).foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: icon).foregroundStyle(tint)
        }
        .font(.subheadline)
    }

    private func row(_ session: ShellSessionInfo, now: Date) -> some View {
        HStack(spacing: 12) {
            Button { router.terminal = .attach(session.id) } label: {
                HStack(spacing: 12) {
                    if session.isAsking {
                        NeedsYouDot().frame(width: 16, height: 16)
                    } else if let status = session.status, session.running, status.isUnseenResult {
                        // Finished while nobody was looking (what the program reports, e.g. Claude Code).
                        Image(systemName: status.state == ShellStatus.error ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                            .font(.body)
                            .foregroundStyle(status.state == ShellStatus.error ? PTColor.problem : PTColor.tint)
                            .frame(width: 16, height: 16)
                            .accessibilityHidden(true)
                    } else {
                        PTStatusDot(color: session.running ? PTColor.tint : .secondary.opacity(0.5), live: session.running)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(session.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                        Text(Self.status(session, now: now, kind: shell.selectedKind)).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens the terminal")
            Menu {
                Button { router.terminal = .attach(session.id) } label: { Label("Open", systemImage: "terminal") }
                if session.running {
                    Button(role: .destructive) { shell.close(session.id) } label: { Label("End session", systemImage: "xmark") }
                } else {
                    Button(role: .destructive) { shell.remove(session.id) } label: { Label("Remove", systemImage: "trash") }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("More for \(session.title)")
        }
        .frame(minHeight: 44)
    }

    /// "running · 4m" (since it started) or "exited 0 · 1h" (since its last output).
    /// A session started in a terminal window on the computer says so first ("on the Mac · running · 4m").
    /// A program that reports its status (Claude Code) is described by it:
    /// "working · 3m · 2 agents", "done · 1m", "failed · 1m" (since it got there).
    static func status(_ session: ShellSessionInfo, now: Date, kind: HostKind = .mac) -> String {
        if session.running, let question = session.waiting { return "needs you · " + question }
        if session.running {
            let place = session.isOnMac ? "on \(HostWords(kind: kind, name: nil, device: "").the) · " : ""
            if let status = session.status {
                let since = age(now.timeIntervalSince1970 - status.since)
                if status.isWorking {
                    let agents = status.agents == 0 ? "" : " · " + (status.agents == 1 ? "1 agent" : "\(status.agents) agents")
                    return place + "working · " + since + agents
                }
                if status.isUnseenResult { return place + (status.state == ShellStatus.error ? "failed · " : "done · ") + since }
            }
            return place + "running · " + age(now.timeIntervalSince1970 - session.startedAt)
        }
        let exited = session.exitStatus.map { "exited \($0)" } ?? "exited"
        return exited + " · " + age(now.timeIntervalSince1970 - session.lastOutputAt)
    }

    static func age(_ seconds: Double) -> String {
        let s = max(0, Int(seconds))
        switch s {
        case ..<60: return "<1m"
        case ..<3600: return "\(s / 60)m"
        case ..<86_400: return "\(s / 3600)h"
        default: return "\(s / 86_400)d"
        }
    }
}

extension ShellPath {
    /// How the card describes an iroh connection; nil for local/Tailscale and unknown paths.
    var label: String? {
        switch self {
        case .direct: "directly"
        case .relay: "via relay"
        case .local, .unknown: nil
        }
    }
}

/// A short status for the shell's reach, with the colour of its dot.
struct ShellStatusLabel: View {
    let reach: ShellModel.Reach
    var kind: HostKind = .mac

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(Self.color(reach)).frame(width: 8, height: 8)
            Text(Self.title(reach, kind: kind))
        }
    }

    static func title(_ reach: ShellModel.Reach, kind: HostKind = .mac) -> String {
        switch reach {
        case .ready: "Connected"
        case .connecting: "Connecting…"
        case .unreachable: HostCopy.cantReach(HostWords(kind: kind, name: nil, device: ThisDevice.name))
        case .locked: "Locked"
        case .needsPasscode: "Needs a passcode"
        case .keyUnavailable: "Access needs renewing"
        case .noAccess: "Not set up"
        }
    }

    static func color(_ reach: ShellModel.Reach) -> Color {
        switch reach {
        case .ready: PTColor.tint
        case .connecting: PTColor.tintText
        case .unreachable, .needsPasscode, .keyUnavailable: PTColor.attention
        case .locked, .noAccess: Color.secondary.opacity(0.5)
        }
    }
}

/// How to give this device the shell, as numbered steps in the computer's words
/// (`HostCopy.setupSteps`); the first is ticked once a computer is paired.
struct ShellSetupSteps: View {
    let paired: Bool
    /// The computer's nouns; `.generic` with nothing paired.
    let words: HostWords
    @EnvironmentObject private var model: AppModel

    var body: some View {
        let steps = HostCopy.setupSteps(words, paired: paired, isPad: ThisDevice.isPad, cableLinkOn: model.state.isActive, needsVPNPrompt: false)
        VStack(alignment: .leading, spacing: 14) {
            ForEach(Array(steps.enumerated()), id: \.offset) { index, item in
                VStack(alignment: .leading, spacing: 8) {
                    step(index + 1, done: item.done, title: item.title, detail: item.detail)
                    if item.action == .turnOnCableLink {
                        Button { model.start() } label: { Label("Turn on the cable link", systemImage: "cable.connector") }
                            .font(.subheadline.weight(.semibold))
                            .buttonStyle(.bordered)
                            .buttonBorderShape(.capsule)
                            .tint(PTColor.tintText)
                            .frame(minHeight: 44)
                            .padding(.leading, 38)
                    }
                    if let note = item.note {
                        Text(note).font(.footnote).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.leading, 38)
                    }
                }
            }
        }
    }

    private func step(_ n: Int, done: Bool, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle().fill(done ? PTColor.tint.opacity(0.18) : PTColor.tintText.opacity(0.16))
                if done {
                    Image(systemName: "checkmark").font(.caption.weight(.bold)).foregroundStyle(PTColor.tint)
                } else {
                    Text("\(n)").font(PTTheme.mono(13, weight: .bold)).foregroundStyle(PTColor.tintText)
                }
            }
            .frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                    .foregroundStyle(done ? .secondary : .primary)
                Text(detail).font(.footnote).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Step \(n)\(done ? ", done" : ""): \(title). \(done ? "" : detail)")
    }
}
