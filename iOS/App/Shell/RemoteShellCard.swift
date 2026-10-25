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
        shell.macs.first { $0.macID == shell.selectedMacID }?.macName ?? "your Mac"
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
            if shell.macs.count > 1 {
                macPicker
            } else {
                Text(selectedMacName).font(.subheadline.weight(.semibold)).lineLimit(1)
            }
            Text(statusDetail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    private var statusDetail: String {
        switch shell.reach {
        case .ready: shell.path?.label.map { "Connected \($0)" } ?? "Connected"
        default: ShellStatusLabel.title(shell.reach)
        }
    }

    private var macPicker: some View {
        Menu {
            Picker("Mac", selection: $shell.selectedMacID) {
                ForEach(shell.macs, id: \.macID) { mac in
                    Text(mac.macName).tag(Optional(mac.macID))
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(selectedMacName).lineLimit(1)
                Image(systemName: "chevron.up.chevron.down").font(.caption2.weight(.bold))
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.primary)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .accessibilityLabel("Mac, \(selectedMacName)")
        .accessibilityHint("Choose which Mac to open a shell on")
    }

    @ViewBuilder private var content: some View {
        switch shell.reach {
        case .noAccess:
            Text("Open your Mac's shell right from this iPhone. To set it up:")
                .font(.subheadline).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ShellSetupSteps(paired: !model.pairedClients.isEmpty)
        case .connecting:
            HStack(spacing: 10) {
                ProgressView()
                Text(shell.isRedialing ? "Reconnecting to \(selectedMacName)…" : "Connecting to \(selectedMacName)…")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        case .unreachable:
            notice(shell.reachMessage ?? "", icon: "wifi.exclamationmark", tint: PTColor.attention)
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
            if shell.sessions.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Text("No sessions open. Start one to run commands on \(selectedMacName).")
                        .font(.subheadline).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button { router.terminal = .new } label: {
                        Label("New session", systemImage: "plus")
                    }
                    .buttonStyle(PTProminentButtonStyle())
                }
            } else {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(shell.sessions, id: \.id) { session in
                            row(session, now: context.date)
                        }
                    }
                }
            }
            if let message = shell.lastError?.message {
                notice(message, icon: "exclamationmark.triangle.fill", tint: PTColor.attention)
            }
            Divider().opacity(0.5)
            Button { router.showScreen = true } label: {
                HStack(spacing: 10) {
                    Image(systemName: "display").foregroundStyle(PTColor.tintText)
                    Text("See and control the screen").foregroundStyle(.primary)
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                }
                .font(.subheadline.weight(.medium))
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
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
                    } else {
                        PTStatusDot(color: session.running ? PTColor.tint : .secondary.opacity(0.5), live: session.running)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(session.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                        Text(Self.status(session, now: now)).font(.caption).foregroundStyle(.secondary)
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
                Button(role: .destructive) { shell.close(session.id) } label: { Label("End session", systemImage: "xmark") }
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
    static func status(_ session: ShellSessionInfo, now: Date) -> String {
        if session.running, let question = session.waiting { return "needs you · " + question }
        if session.running {
            return "running · " + age(now.timeIntervalSince1970 - session.startedAt)
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

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(Self.color(reach)).frame(width: 8, height: 8)
            Text(Self.title(reach))
        }
    }

    static func title(_ reach: ShellModel.Reach) -> String {
        switch reach {
        case .ready: "Connected"
        case .connecting: "Connecting…"
        case .unreachable: "Can't reach Mac"
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

/// How to give this iPhone the shell, as numbered steps; the first is ticked once a Mac is paired.
struct ShellSetupSteps: View {
    let paired: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            step(1, done: paired, title: "Pair this iPhone with your Mac",
                 detail: paired ? "Done." : "On the Mac tab, tap This iPhone, then Pair.")
            step(2, done: false, title: "Turn on Remote shell on your Mac",
                 detail: "On the Mac, open Passthrough's Settings, go to Remote Shell and turn on \u{201C}Allow remote shell from paired phones\u{201D}.")
            step(3, done: false, title: "Connect over USB once",
                 detail: "With sharing on, plug this iPhone into the Mac. Its shells then show up on the Mac and Shells tabs by themselves.")
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
