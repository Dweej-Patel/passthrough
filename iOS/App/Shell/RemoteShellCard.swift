import SwiftUI
import PassthroughCore
import PassthroughUI

/// The home screen's Remote shell card: the selected Mac's sessions, a New
/// button, and the way into the terminal and history.
struct RemoteShellCard: View {
    @ObservedObject var shell: ShellModel
    @EnvironmentObject private var lock: AppLock
    @State private var terminal: TerminalIntent?
    @State private var showHistory = false

    var body: some View {
        PTCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    PTSectionTitle("Remote shell", icon: "terminal")
                    if shell.macs.count > 1 { macPicker }
                    if shell.reach == .ready, let label = shell.path?.label {
                        Text(label).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Button { terminal = .new } label: {
                        Label("New", systemImage: "plus").font(.caption.weight(.bold))
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .tint(PTTheme.accentEnd)
                    .controlSize(.small)
                    .disabled(shell.reach != .ready)
                }
                content
            }
        }
        .fullScreenCover(item: $terminal) { intent in
            TerminalScreen(shell: shell, intent: intent)
        }
        .sheet(isPresented: $showHistory) {
            ShellHistoryView(shell: shell)
        }
        .onChange(of: lock.isUnlocked) { _, unlocked in
            // The lock dismisses presentations; keep this state in step with it.
            if !unlocked {
                terminal = nil
                showHistory = false
            }
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
            HStack(spacing: 3) {
                Text(shell.macs.first { $0.macID == shell.selectedMacID }?.macName ?? "Mac").lineLimit(1)
                Image(systemName: "chevron.up.chevron.down").font(.caption2.weight(.bold))
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var content: some View {
        switch shell.reach {
        case .connecting:
            HStack {
                Spacer()
                ProgressView()
                Spacer()
            }
            .padding(.vertical, 6)
        case .ready:
            if shell.sessions.isEmpty {
                Text("No open sessions. Tap New to start one.")
                    .font(.subheadline).foregroundStyle(.secondary)
            } else {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(shell.sessions, id: \.id) { session in
                            row(session, now: context.date)
                        }
                    }
                }
            }
            if let message = shell.lastError?.message {
                Text(message).font(.subheadline).foregroundStyle(PTTheme.warning)
            }
            Button { showHistory = true } label: {
                HStack(spacing: 4) {
                    Text("History")
                    Image(systemName: "chevron.right").font(.caption2.weight(.bold))
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(PTTheme.accentEnd)
            }
            .buttonStyle(.plain)
        default:
            Text(shell.reachMessage ?? "")
                .font(.subheadline).foregroundStyle(.secondary)
        }
    }

    private func row(_ session: ShellSessionInfo, now: Date) -> some View {
        HStack(spacing: 12) {
            Button { terminal = .attach(session.id) } label: {
                HStack(spacing: 12) {
                    PTStatusDot(color: session.running ? PTTheme.success : .secondary.opacity(0.5), live: session.running)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(session.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                        Text(Self.status(session, now: now)).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Menu {
                Button(role: .destructive) { shell.close(session.id) } label: { Label("End session", systemImage: "xmark") }
            } label: {
                Image(systemName: "ellipsis.circle").foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    /// "running · 4m" (since it started) or "exited 0 · 1h" (since its last output).
    static func status(_ session: ShellSessionInfo, now: Date) -> String {
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
        case .direct: "direct"
        case .relay: "via relay"
        case .local, .unknown: nil
        }
    }
}
