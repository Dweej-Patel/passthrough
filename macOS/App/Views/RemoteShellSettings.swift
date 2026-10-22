import SwiftUI
import IrohTransport
import PassthroughCore
import PassthroughUI
import ShellHost

/// General tab: let paired phones open a shell on this Mac, and see who can,
/// what is open and what was recorded.
struct RemoteShellSettings: View {
    @EnvironmentObject private var session: SessionCoordinator
    @EnvironmentObject private var shell: RemoteShellController
    @Environment(\.openWindow) private var openWindow
    @State private var fullDiskAccess = FullDiskAccess.isGranted
    @State private var confirmClear = false

    var body: some View {
        Section {
            Toggle("Allow remote shell from paired phones", isOn: $session.remoteShellEnabled)
            if session.remoteShellEnabled {
                LabeledContent("Full Disk Access") {
                    HStack {
                        Text(fullDiskAccess ? "Granted" : "Not granted")
                        if !fullDiskAccess { Button("Open System Settings…") { FullDiskAccess.openSettings() } }
                    }
                }
                if !fullDiskAccess {
                    Label("Without it, a command that touches Desktop, Documents, Downloads, iCloud Drive or an external drive waits for a prompt on this Mac.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(PTTheme.warning)
                }
            }
            if let error = shell.listenerError {
                Text(error).font(.caption).foregroundStyle(PTTheme.danger)
            }
        } header: {
            Text("Remote shell")
        } footer: {
            Text("Your phone can open a shell on this Mac over the same Wi-Fi or Tailscale. Pair over the cable to give a phone access. Every session is recorded on this Mac. The Mac must be awake; turn on Keep awake if you'll be away.")
        }
        .task(id: session.remoteShellEnabled) {
            // Granted in System Settings while this is open: notice it.
            while session.remoteShellEnabled, !Task.isCancelled {
                fullDiskAccess = FullDiskAccess.isGranted
                try? await Task.sleep(for: .seconds(2))
            }
        }
        .sheet(isPresented: $session.fullDiskAccessPrompt) { FullDiskAccessSheet() }

        if session.remoteShellEnabled {
            ReachAnywhereSettings()
            Section("Phones with access") {
                if shell.phones.isEmpty {
                    Text("None yet. Connect a paired phone over the cable to give it access.").foregroundStyle(.secondary)
                }
                ForEach(shell.phones, id: \.phoneID) { phone in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(phone.label)
                            Text("Granted \(phone.grantedAt.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Revoke", role: .destructive) { shell.revoke(phone.phoneID) }
                    }
                }
            }
        }
        // Whenever a shell runs, even with the setting just turned off.
        if session.remoteShellEnabled || shell.sessions.contains(where: \.running) {
            Section("Open sessions") {
                let open = shell.sessions.filter(\.running)
                if open.isEmpty { Text("None").foregroundStyle(.secondary) }
                ForEach(open, id: \.id) { info in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(info.title).lineLimit(1)
                            Text("Started \(Date(timeIntervalSince1970: info.startedAt), style: .relative) ago")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Close") { shell.close(info.id) }
                    }
                }
            }
        }
        // Recorded history stays reachable (to read or delete) with the setting off.
        if session.remoteShellEnabled || !shell.history.isEmpty {
            Section {
                LabeledContent("History") {
                    Text(ByteCountFormatter.string(fromByteCount: shell.historyBytes, countStyle: .file))
                }
                HStack {
                    Button("Open History…") {
                        NSApp.activate()
                        openWindow(id: ShellHistoryWindow.id)
                    }
                    Button("Clear All…", role: .destructive) { confirmClear = true }
                        .disabled(!shell.history.contains { !shell.isRecording($0.id) })
                }
                .confirmationDialog("Delete all shell history?", isPresented: $confirmClear) {
                    Button("Delete All", role: .destructive) { shell.clearHistory() }
                } message: {
                    Text("The recorded output of every finished session is deleted from this Mac. Sessions still running keep recording. This can't be undone.")
                }
            }
        }
    }
}

/// Remote shell over iroh: the toggle, which relays, what is running, and
/// resetting the endpoint's identity.
private struct ReachAnywhereSettings: View {
    @EnvironmentObject private var shell: RemoteShellController
    @State private var useCustomRelay = false
    @State private var relayURL = ""
    @State private var relayToken = ""
    @State private var confirmReset = false

    private var draft: IrohRelayConfig {
        guard useCustomRelay else { return IrohRelayConfig() }
        let url = relayURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let token = relayToken.trimmingCharacters(in: .whitespacesAndNewlines)
        return IrohRelayConfig(url: url, token: token.isEmpty ? nil : token)
    }

    private var draftIsValid: Bool {
        guard let url = draft.url else { return true }
        return IrohInfo.isValidRelay(url) && (draft.token.map(IrohInfo.isValidToken) ?? true)
    }

    var body: some View {
        Section {
            Toggle("Reach this Mac from anywhere (built-in)", isOn: $shell.reachAnywhere)
            if shell.reachAnywhere {
                Picker("Relay", selection: $useCustomRelay) {
                    Text("Default (iroh public relays — for development, no uptime guarantee)").tag(false)
                    Text("Custom").tag(true)
                }
                .onChange(of: useCustomRelay) { _, custom in
                    // Back to the default applies at once; a custom relay waits for Apply.
                    if !custom { shell.relay = IrohRelayConfig() }
                }
                if useCustomRelay {
                    TextField("Relay URL", text: $relayURL, prompt: Text("https://relay.example.com"))
                        .textContentType(.URL)
                        .autocorrectionDisabled()
                    SecureField("Token (optional)", text: $relayToken)
                    HStack {
                        if !relayURL.isEmpty && !draftIsValid {
                            Text("Enter an https URL (at most 256 characters).")
                                .font(.caption).foregroundStyle(PTTheme.danger)
                        }
                        Spacer()
                        Button("Apply") { shell.relay = draft }
                            .disabled(relayURL.isEmpty || !draftIsValid || draft == shell.relay)
                    }
                }
                LabeledContent("Status") { Text(statusText).multilineTextAlignment(.trailing).textSelection(.enabled) }
                ForEach(connectedPhones, id: \.id) { phone in
                    LabeledContent(phone.label) { Text(phone.path).foregroundStyle(.secondary) }
                }
            }
            Button("Reset built-in identity…", role: .destructive) { confirmReset = true }
                .confirmationDialog("Reset this Mac's built-in identity?", isPresented: $confirmReset) {
                    Button("Reset Identity", role: .destructive) { shell.resetIrohIdentity() }
                } message: {
                    Text("This Mac gets a new identity for reaching it from anywhere. Phones can no longer reach it that way until they connect to this Mac again over the cable (or once over the same Wi-Fi or Tailscale), which gives them the new one. Shell access itself is not affected.")
                }
        } header: {
            Text("Reach from anywhere")
        } footer: {
            Text("Paired phones can reach this Mac's shell from any network, directly when possible or through a relay that only sees encrypted traffic. Phones still need their shell key. A custom relay is given to phones the next time they connect.")
        }
        .onAppear(perform: loadDraft)
    }

    private func loadDraft() {
        useCustomRelay = shell.relay.url != nil
        relayURL = shell.relay.url ?? ""
        relayToken = shell.relay.token ?? ""
    }

    private var statusText: String {
        let status = shell.irohStatus
        switch status.state {
        case .off: return "Off"
        case .starting: return "Starting…"
        case .failed(let reason): return reason
        case .running:
            var parts = ["ID \(status.shortID ?? "?")"]
            if let home = status.homeRelay {
                parts.append("relay \(URL(string: home)?.host(percentEncoded: false)?.trimmingCharacters(in: CharacterSet(charactersIn: ".")) ?? home)")
            } else {
                parts.append("no relay yet")
            }
            return parts.joined(separator: " · ")
        }
    }

    private var connectedPhones: [(id: String, label: String, path: String)] {
        shell.irohStatus.paths.map { id, path in
            let label = shell.phones.first { $0.phoneID == id }?.label ?? "Phone"
            let text = switch path {
            case .direct: "direct"
            case .relay: "via relay"
            case .unknown: "connecting"
            }
            return (id, label, text)
        }
        .sorted { $0.label < $1.label }
    }
}

/// Why Remote shell wants Full Disk Access, shown when it is turned on without it.
private struct FullDiskAccessSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Give Passthrough Full Disk Access", systemImage: "lock.shield").font(.headline)
            Text("Shells opened from your phone run with Passthrough's privacy permissions, not Terminal's. Without Full Disk Access, a command that touches Desktop, Documents, Downloads, iCloud Drive or an external drive makes macOS show a prompt on this Mac, and the command waits until someone answers it.")
            Text("The shell still works without it. You can change this at any time in System Settings › Privacy & Security › Full Disk Access.")
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Not Now") { dismiss() }
                Button("Open System Settings…") {
                    FullDiskAccess.openSettings()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .font(.callout)
        .padding(20)
        .frame(width: 420)
    }
}
