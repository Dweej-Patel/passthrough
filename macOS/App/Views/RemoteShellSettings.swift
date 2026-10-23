import SwiftUI
import IrohTransport
import PassthroughCore
import PassthroughUI
import ScreenHost
import ShellHost

/// Remote Shell tab: turn it on, finish setting it up, and see who can
/// connect, what is open and what was recorded.
struct RemoteShellSettings: View {
    @EnvironmentObject private var session: SessionCoordinator
    @EnvironmentObject private var shell: RemoteShellController
    @EnvironmentObject private var keepAwake: KeepAwakeController
    @State private var fullDiskAccess = FullDiskAccess.isGranted
    @State private var showFullDiskAccess = false

    var body: some View {
        Form {
            Section {
                ShellHeader(summary: summary)
            }
            if session.remoteShellEnabled {
                setup
                PhonesSection()
                OpenSessionsSection()
                ReachAnywhereSettings()
            } else {
                HowItWorks()
                // Whatever is still running when the setting was just turned off.
                if shell.sessions.contains(where: \.running) { OpenSessionsSection() }
            }
            // Recorded history stays reachable (to read or delete) with the setting off.
            if session.remoteShellEnabled || !shell.history.isEmpty { HistorySection() }
        }
        .formStyle(.grouped)
        .task(id: session.remoteShellEnabled) {
            // Granted in System Settings while this is open: notice it.
            while !Task.isCancelled {
                fullDiskAccess = FullDiskAccess.isGranted
                shell.refreshScreenVideo()
                try? await Task.sleep(for: .seconds(2))
            }
        }
        .task(id: session.remoteShellEnabled) {
            // Less often: each check is a connection Screen Sharing sees.
            guard session.remoteShellEnabled else { return }
            while !Task.isCancelled {
                await shell.refreshScreenSharing()
                try? await Task.sleep(for: .seconds(5))
            }
        }
        .sheet(isPresented: $showFullDiskAccess) { FullDiskAccessSheet() }
        .sheet(isPresented: $session.fullDiskAccessPrompt) { FullDiskAccessSheet() }
    }

    private var summary: String {
        guard session.remoteShellEnabled else { return "Open this Mac's shell from your paired phone." }
        if shell.listenerError != nil { return "On, but not working. See below." }
        let open = shell.sessions.filter(\.running).count
        if open > 0 { return "On · \(open) session\(open == 1 ? "" : "s") open" }
        if shell.phones.isEmpty { return "On · finish setting up below" }
        return "On · ready for \(shell.phones.count) phone\(shell.phones.count == 1 ? "" : "s")"
    }

    private var setup: some View {
        Section {
            if let error = shell.listenerError {
                SetupStep(status: .problem, title: "Remote shell isn't running", detail: error) { EmptyView() }
            }
            SetupStep(status: fullDiskAccess ? .done : .needed,
                      title: "Full Disk Access",
                      detail: fullDiskAccess
                        ? "Shells can use files anywhere on this Mac."
                        : "Recommended. Without it, commands that touch Desktop, Documents, Downloads or iCloud Drive pause for a permission prompt on this Mac.") {
                if !fullDiskAccess { Button("Set Up…") { showFullDiskAccess = true } }
            }
            SetupStep(status: shell.phones.isEmpty ? .needed : .done,
                      title: shell.phones.isEmpty ? "Give a phone access" : "Phone access",
                      detail: shell.phones.isEmpty
                        ? "Plug in a phone you've paired with this Mac. It gets its own key automatically, then connects without the cable."
                        : "\(shell.phones.count) phone\(shell.phones.count == 1 ? "" : "s") can open a shell. Plug in another paired phone to add it.") {
                EmptyView()
            }
            screenVideoStep
            screenSharingStep
            SetupStep(status: keepAwake.isOn ? .done : .optional,
                      title: "Keep this Mac awake",
                      detail: keepAwake.isOn
                        ? "This Mac stays reachable while you're away."
                        : "Optional. A sleeping Mac can't be reached.") {
                if !keepAwake.isOn { Button("Turn On") { keepAwake.set(true) } }
            }
        } header: {
            Text("Setup")
        }
    }

    /// Passthrough streaming the screen itself: smooth video, no password.
    private var screenVideoStep: some View {
        let access = shell.screenVideo
        let wanted = shell.phones.contains(where: \.screenAllowed)
        return SetupStep(status: access.ready ? .done : (wanted ? .needed : .optional),
                         title: "Screen Recording and Accessibility",
                         detail: access.ready
                            ? "Phones you allow below see this screen as smooth video and control it."
                            : (wanted ? "A phone below may see this screen. " : "Optional. ")
                                + "Allow Passthrough under Privacy & Security › Screen Recording (to stream this screen) and › Accessibility (to take a phone's clicks and keys). macOS may want Passthrough reopened after Screen Recording.") {
            HStack(spacing: 6) {
                if !access.capture {
                    Button("Screen Recording…") {
                        ScreenVideoPermissions.requestCapture()
                        ScreenVideoPermissions.openSettings(capture: true)
                    }
                }
                if !access.control {
                    Button("Accessibility…") {
                        ScreenVideoPermissions.requestControl()
                        ScreenVideoPermissions.openSettings(capture: false)
                    }
                }
            }
        }
    }

    /// Only once checked, so it doesn't flash "off" while the first check runs.
    @ViewBuilder private var screenSharingStep: some View {
        if let on = shell.screenSharingOn {
            let needed = shell.phones.contains(where: \.screenAllowed) && !shell.screenVideo.ready
            SetupStep(status: on ? .done : (needed ? .needed : .optional),
                      title: "Screen Sharing",
                      detail: on
                        ? "The fallback: when Passthrough can't stream this screen itself, phones use Screen Sharing, after entering your Mac's name and password. It also answers on your local network, behind the same password."
                        : needed
                            ? "Until Passthrough may stream this screen itself, phones need Screen Sharing. Turn it on in System Settings › General › Sharing."
                            : "Optional fallback, slower, for when Passthrough can't stream this screen itself.") {
                if !on { Button("Open Settings…") { ScreenSharing.openSettings() } }
            }
        }
    }
}

// MARK: - Header and overview

private struct ShellHeader: View {
    @EnvironmentObject private var session: SessionCoordinator
    let summary: String

    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(PTTheme.accent)
                .frame(width: 38, height: 38)
                .overlay {
                    Image(systemName: "apple.terminal.fill")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                }
            VStack(alignment: .leading, spacing: 2) {
                Text("Remote Shell").font(.headline)
                Text(summary).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("Allow remote shell from paired phones", isOn: $session.remoteShellEnabled)
                .toggleStyle(.switch)
                .labelsHidden()
        }
        .padding(.vertical, 4)
    }
}

/// What turning it on means, shown while it is off.
private struct HowItWorks: View {
    var body: some View {
        Section {
            Point(symbol: "lock.shield", title: "Only your phones",
                  detail: "A phone gets access only when you plug it in after pairing. Each has its own key you can revoke.")
            Point(symbol: "network", title: "From wherever you are",
                  detail: "Connect on the same Wi-Fi, over Tailscale, or from any network with Reach from anywhere.")
            Point(symbol: "record.circle", title: "Every session recorded",
                  detail: "What happens in each shell is saved on this Mac, so you can look back at it.")
        } header: {
            Text("How it works")
        }
    }

    private struct Point: View {
        let symbol: String
        let title: String
        let detail: String

        var body: some View {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(PTTheme.accent)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.body.weight(.medium))
                    Text(detail).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, 2)
        }
    }
}

/// One setup item: whether it is done, what it means, and the action that does it.
private struct SetupStep<Accessory: View>: View {
    enum Status { case done, needed, optional, problem }

    let status: Status
    let title: String
    let detail: String
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            icon
                .font(.system(size: 17))
                .frame(width: 22)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.medium))
                Text(detail).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 8)
            accessory
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityValue(accessibilityStatus)
    }

    @ViewBuilder private var icon: some View {
        switch status {
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(PTTheme.success)
        case .needed: Image(systemName: "exclamationmark.circle.fill").foregroundStyle(PTTheme.warning)
        case .optional: Image(systemName: "circle.dashed").foregroundStyle(.secondary)
        case .problem: Image(systemName: "xmark.octagon.fill").foregroundStyle(PTTheme.danger)
        }
    }

    private var accessibilityStatus: String {
        switch status {
        case .done: return "Done"
        case .needed: return "Needs attention"
        case .optional: return "Optional"
        case .problem: return "Problem"
        }
    }
}

// MARK: - Phones and sessions

private struct PhonesSection: View {
    @EnvironmentObject private var shell: RemoteShellController
    @State private var revoking: ShellPhone?

    var body: some View {
        Section {
            if shell.phones.isEmpty {
                Text("No phones yet.").foregroundStyle(.secondary)
            }
            ForEach(shell.phones, id: \.phoneID) { phone in
                HStack(spacing: 12) {
                    Image(systemName: "iphone")
                        .font(.system(size: 17))
                        .foregroundStyle(.secondary)
                        .frame(width: 22)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(phone.label)
                        Text(detail(for: phone)).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    // Label beside the switch: a form spreads a toggle's own label across the row.
                    HStack(spacing: 6) {
                        Text("Screen").font(.callout).foregroundStyle(.secondary)
                        Toggle("Screen", isOn: Binding(get: { phone.screenAllowed },
                                                       set: { shell.setScreenAllowed($0, for: phone.phoneID) }))
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .labelsHidden()
                    }
                    .fixedSize()
                    .help("Also let \(phone.label) see and control this screen.")
                    Button("Revoke…") { revoking = phone }
                }
                .padding(.vertical, 1)
            }
        } header: {
            Text("Phones with access")
        }
        .confirmationDialog("Revoke \(revoking?.label ?? "this phone")'s access?",
                            isPresented: Binding(get: { revoking != nil }, set: { if !$0 { revoking = nil } }),
                            presenting: revoking) { phone in
            Button("Revoke Access", role: .destructive) { shell.revoke(phone.phoneID) }
        } message: { _ in
            Text("Its shells and any view of the screen close, and its key stops working. Plug it in again to give it a new one.")
        }
    }

    private func detail(for phone: ShellPhone) -> String {
        var parts = ["Added \(phone.grantedAt.formatted(date: .abbreviated, time: .omitted))"]
        if shell.screenViewers.contains(where: { $0.phoneID == phone.phoneID }) { parts.append("viewing the screen") }
        switch shell.irohStatus.paths[phone.phoneID] {
        case .direct?: parts.append("connected from anywhere, directly")
        case .relay?: parts.append("connected from anywhere, through a relay")
        case .unknown?: parts.append("connecting")
        case nil: break
        }
        return parts.joined(separator: " · ")
    }
}

private struct OpenSessionsSection: View {
    @EnvironmentObject private var shell: RemoteShellController
    @State private var ending: ShellSessionInfo?

    var body: some View {
        let open = shell.sessions.filter(\.running)
        Section {
            if open.isEmpty {
                Text("No shells are open.").foregroundStyle(.secondary)
            }
            ForEach(open, id: \.id) { info in
                HStack(spacing: 12) {
                    Image(systemName: "apple.terminal")
                        .font(.system(size: 16))
                        .foregroundStyle(PTTheme.accent)
                        .frame(width: 22)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(info.title).lineLimit(1).truncationMode(.middle)
                        Text("Started \(Date(timeIntervalSince1970: info.startedAt).formatted(.relative(presentation: .named)))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("End…") { ending = info }
                }
                .padding(.vertical, 1)
            }
        } header: {
            Text("Open sessions")
        }
        .confirmationDialog("End this session?",
                            isPresented: Binding(get: { ending != nil }, set: { if !$0 { ending = nil } }),
                            presenting: ending) { info in
            Button("End Session", role: .destructive) { shell.close(info.id) }
        } message: { _ in
            Text("The shell and anything running in it are closed, as when you close a Terminal window. Its recording is kept.")
        }
    }
}

private struct HistorySection: View {
    @EnvironmentObject private var shell: RemoteShellController
    @Environment(\.openWindow) private var openWindow
    @State private var confirmClear = false

    var body: some View {
        Section {
            LabeledContent("Recorded sessions") {
                Text("\(shell.history.count) · \(ByteCountFormatter.string(fromByteCount: shell.historyBytes, countStyle: .file))")
                    .monospacedDigit()
            }
            HStack {
                Button("Open History…") {
                    NSApp.activate()
                    openWindow(id: ShellHistoryWindow.id)
                }
                Spacer()
                Button("Clear All…", role: .destructive) { confirmClear = true }
                    .disabled(!shell.history.contains { !shell.isRecording($0.id) })
            }
        } header: {
            Text("History")
        } footer: {
            Text("Recordings stay on this Mac. Phones with access can read them.")
        }
        .confirmationDialog("Delete all shell history?", isPresented: $confirmClear) {
            Button("Delete All", role: .destructive) { shell.clearHistory() }
        } message: {
            Text("The recording of every finished session is deleted from this Mac. Sessions still running keep recording. This can't be undone.")
        }
    }
}

// MARK: - Reach from anywhere

/// Remote shell over iroh: the toggle, its state, which relay, and resetting
/// the endpoint's identity.
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
            Toggle(isOn: $shell.reachAnywhere) {
                Text("Reach this Mac from anywhere")
                Text("Phones connect from any network: directly when they can, otherwise through a relay that only passes encrypted traffic.")
            }
            if shell.reachAnywhere {
                LabeledContent("Status") { status }
                Picker(selection: $useCustomRelay) {
                    Text("iroh public relays").tag(false)
                    Text("Custom relay").tag(true)
                } label: {
                    Text("Relay")
                    Text(useCustomRelay ? "Phones get it the next time they connect." : "Free relays run by n0, best for trying it out. No uptime guarantee.")
                }
                .onChange(of: useCustomRelay) { _, custom in
                    // Back to the default applies at once; a custom relay waits for Apply.
                    if !custom { shell.relay = IrohRelayConfig() }
                }
                if useCustomRelay {
                    TextField("Relay URL", text: $relayURL, prompt: Text("https://relay.example.com"))
                        .textContentType(.URL)
                        .autocorrectionDisabled()
                    SecureField("Token", text: $relayToken, prompt: Text("Optional"))
                    HStack {
                        if !relayURL.isEmpty && !draftIsValid {
                            Label("Enter an https URL of at most 256 characters.", systemImage: "exclamationmark.triangle.fill")
                                .font(.caption).foregroundStyle(PTTheme.danger)
                        }
                        Spacer()
                        Button("Apply") { shell.relay = draft }
                            .disabled(relayURL.isEmpty || !draftIsValid || draft == shell.relay)
                    }
                }
                LabeledContent("Identity") {
                    HStack(spacing: 8) {
                        if let id = shell.irohStatus.shortID {
                            Text(id).font(.callout.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                        Button("Reset…") { confirmReset = true }
                    }
                }
            }
        } header: {
            Text("Reach from anywhere")
        }
        .confirmationDialog("Reset this Mac's identity for reaching it from anywhere?", isPresented: $confirmReset) {
            Button("Reset Identity", role: .destructive) { shell.resetIrohIdentity() }
        } message: {
            Text("Phones can't reach this Mac from anywhere until they connect once over the cable, the same Wi-Fi or Tailscale, which gives them the new identity. Shell access itself isn't affected.")
        }
        .onAppear(perform: loadDraft)
    }

    private func loadDraft() {
        useCustomRelay = shell.relay.url != nil
        relayURL = shell.relay.url ?? ""
        relayToken = shell.relay.token ?? ""
    }

    @ViewBuilder private var status: some View {
        let status = shell.irohStatus
        switch status.state {
        case .off:
            StatusText(color: .secondary, text: "Off")
        case .starting:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Starting…").foregroundStyle(.secondary)
            }
        case .failed(let reason):
            StatusText(color: PTTheme.danger, text: reason)
        case .running:
            if let home = status.homeRelay {
                let host = URL(string: home)?.host(percentEncoded: false)?.trimmingCharacters(in: CharacterSet(charactersIn: ".")) ?? home
                StatusText(color: PTTheme.success, text: "Online · relay \(host)")
            } else {
                StatusText(color: PTTheme.warning, text: "Online · looking for a relay")
            }
        }
    }

    private struct StatusText: View {
        let color: Color
        let text: String

        var body: some View {
            HStack(spacing: 6) {
                Circle().fill(color).frame(width: 7, height: 7)
                Text(text).foregroundStyle(.secondary).multilineTextAlignment(.trailing).textSelection(.enabled)
            }
        }
    }
}

// MARK: - Full Disk Access

/// Walks through granting Full Disk Access, and notices when it is granted.
/// Shown when Remote shell is turned on without it, and from Setup.
struct FullDiskAccessSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var granted = FullDiskAccess.isGranted

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(PTTheme.accent)
                    .frame(width: 44, height: 44)
                    .overlay {
                        Image(systemName: "externaldrive.fill.badge.checkmark")
                            .font(.system(size: 19, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Give Passthrough Full Disk Access").font(.title3.weight(.semibold))
                    Text("So commands from your phone never stop for a permission prompt on this Mac.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(alignment: .leading, spacing: 14) {
                Step(number: 1, title: "Open Full Disk Access in System Settings.") {
                    Button("Open System Settings") { FullDiskAccess.openSettings() }
                }
                Step(number: 2, title: "Turn on Passthrough in the list.",
                     detail: "Not in the list? Click + under it and choose Passthrough in Applications, or drag it in from Finder.") {
                    Button("Show in Finder") { FullDiskAccess.revealApp() }
                }
                Step(number: 3, title: "Come back here. This updates by itself.") { EmptyView() }
            }
            .padding(14)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            HStack(spacing: 8) {
                if granted {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(PTTheme.success)
                    Text("Full Disk Access is on.")
                } else {
                    ProgressView().controlSize(.small)
                    Text("Waiting for access…").foregroundStyle(.secondary)
                }
                Spacer()
                if granted {
                    Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
                } else {
                    Button("Not Now") { dismiss() }.keyboardShortcut(.cancelAction)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: granted)

            Text("The shell works without it too; macOS just asks on this Mac before a command can open those files.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(22)
        .frame(width: 480)
        .task {
            while !Task.isCancelled {
                granted = FullDiskAccess.isGranted
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private struct Step<Accessory: View>: View {
        let number: Int
        let title: String
        var detail: String?
        @ViewBuilder var accessory: Accessory

        var body: some View {
            HStack(alignment: .top, spacing: 12) {
                Text("\(number)")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 24, height: 24)
                    .background(PTTheme.accent, in: Circle())
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.body.weight(.medium))
                    if let detail {
                        Text(detail).font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.top, 2)
                Spacer(minLength: 8)
                accessory
            }
        }
    }
}
