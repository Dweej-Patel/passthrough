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
                ComputersWithAccessSection()
                if !shell.screenGuests.isEmpty { ScreenGuestsSection() }
                OpenSessionsSection()
                MacTerminalsSection()
                PhoneNotificationsSection()
                ReachAnywhereSettings()
            } else {
                HowItWorks()
                // Whatever is still running when the setting was just turned off.
                if shell.sessions.contains(where: \.running) { OpenSessionsSection() }
            }
            // Reaching another computer doesn't need this Mac's own remote shell.
            if !shell.screenPasses.isEmpty || !shell.reachableComputers.isEmpty { ReachableComputersSection() }
            // Recorded history stays reachable (to read or delete) with the setting off.
            if session.remoteShellEnabled || !shell.history.isEmpty { HistorySection() }
        }
        .formStyle(.grouped)
        .task(id: session.remoteShellEnabled) {
            // Granted in System Settings while this is open: notice it.
            while !Task.isCancelled {
                fullDiskAccess = FullDiskAccess.isGranted
                shell.refreshScreenVideo()
                session.refreshMicrophoneDriver()
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
            microphoneStep
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
        let wanted = shell.phones.contains(where: \.screenAllowed) || !shell.screenGuests.isEmpty
        return SetupStep(status: access.ready ? .done : (wanted ? .needed : .optional),
                         title: "Screen Recording and Accessibility",
                         detail: access.ready
                            ? "Phones you allow below see this screen as smooth video and control it. Shells inherit these permissions too, so any phone with shell access can also capture the screen and post input from a shell."
                            : (wanted ? "A phone below may see this screen. " : "Optional. ")
                                + "Allow Passthrough under Privacy & Security › Screen Recording (to stream this screen) and › Accessibility (to take a phone's clicks and keys). Shells inherit them too, so any phone with shell access could then capture the screen and post input from a shell. macOS may want Passthrough reopened after Screen Recording.") {
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
    /// A phone viewing the screen as this Mac's microphone: the audio driver that makes its voice an input device.
    @ViewBuilder private var microphoneStep: some View {
        let driver = session.microphoneDriver
        SetupStep(status: session.microphoneDriverError != nil ? .problem : (driver == .ready ? .done : (driver == .notInstalled ? .optional : .needed)),
                  title: "Phone as microphone",
                  detail: microphoneDetail(driver)) {
            if session.microphoneDriverBusy {
                ProgressView().controlSize(.small)
            } else {
                switch driver {
                case .notInstalled: Button("Install…") { session.setMicrophoneDriver(true) }
                case .outdated: Button("Update") { session.setMicrophoneDriver(true) }
                case .notLoaded:
                    HStack {
                        Button("Install Again") { session.setMicrophoneDriver(true) }
                        Button("Remove") { session.setMicrophoneDriver(false) }
                    }
                case .ready: Button("Remove") { session.setMicrophoneDriver(false) }
                }
            }
        }
    }

    private func microphoneDetail(_ driver: MicrophoneDriverStatus) -> String {
        if let error = session.microphoneDriverError { return error }
        switch driver {
        case .notInstalled:
            return "Optional. Adds a \"Passthrough Microphone\" input device to this Mac: a phone viewing the screen can turn its microphone on and be heard through it, for dictation or a call. Installing it restarts this Mac's audio, so sound stops for a moment."
        case .ready:
            return "A phone viewing the screen can turn its microphone on. Choose \"Passthrough Microphone\" as the input in the app that should hear it. Any app allowed to use the microphone can listen while it's on."
        case .outdated:
            return "This version of Passthrough has a newer microphone driver. Updating it restarts this Mac's audio, so sound stops for a moment."
        case .notLoaded:
            return "The driver is installed but macOS hasn't loaded it. Install it again, or restart this Mac."
        }
    }

    @ViewBuilder private var screenSharingStep: some View {
        if let on = shell.screenSharingOn {
            // A pass never uses Screen Sharing: only the phones' fallback does.
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
            if let problem = shell.screenSharingProblem {
                Label(problem, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(PTTheme.warning)
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

/// Notices to phones: on when the build carries a push key
/// (Config/Signing.xcconfig), hidden when it doesn't.
private struct PhoneNotificationsSection: View {
    @EnvironmentObject private var shell: RemoteShellController

    var body: some View {
        if shell.notifications.isBuiltWithKey {
            Section {
                NotificationsContent(notifications: shell.notifications)
            } header: {
                Text("Notifications")
            } footer: {
                Text("Phones that turn on notifications hear when a shell needs them or finishes a long task, even with Passthrough closed. Notices go through Apple's push service sealed with a key only that phone holds: Apple sees that a notice was sent, not what it says. The push key comes from this build (Config/Signing.xcconfig).")
            }
        }
    }
}

private struct NotificationsContent: View {
    @ObservedObject var notifications: PhoneNotifications

    var body: some View {
        LabeledContent("Status") {
            Text(status).foregroundStyle(notifications.isSetUp ? Color.primary : Color.secondary)
        }
        Button("Send Test Notification") { notifications.sendTest() }
            .disabled(!notifications.isSetUp)
        if let problem = notifications.problem {
            Label(problem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.caption)
        }
        if let result = notifications.testResult {
            Text(result).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var status: String {
        let phones = notifications.registeredPhones.count
        let asked = phones == 0 ? "no phone has asked yet" : phones == 1 ? "1 phone asked" : "\(phones) phones asked"
        return (notifications.isSetUp ? "Ready" : "Not set up") + " · " + asked
    }
}

/// Other Macs a phone let see this screen (screen-only passes): each can
/// only view and control the screen, and goes when removed here or when the
/// phone that let it in loses access.
private struct ScreenGuestsSection: View {
    @EnvironmentObject private var shell: RemoteShellController
    @State private var removing: ShellPhone?

    var body: some View {
        Section {
            ForEach(shell.screenGuests, id: \.phoneID) { guest in
                HStack(spacing: 12) {
                    Image(systemName: "desktopcomputer")
                        .font(.system(size: 17))
                        .foregroundStyle(.secondary)
                        .frame(width: 22)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(guest.label)
                        Text(detail(for: guest)).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Remove…") { removing = guest }
                }
                .padding(.vertical, 1)
            }
        } header: {
            Text("Macs that can see this screen")
        } footer: {
            Text("Let in from a phone. They can see and control this screen, so they can type into any app open on it, but can't open Passthrough's shells, switches or history.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .confirmationDialog("Stop \(removing?.label ?? "this Mac") from seeing this screen?",
                            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                            presenting: removing) { guest in
            Button("Remove", role: .destructive) { shell.revoke(guest.phoneID) }
        } message: { _ in
            Text("Any view it has open closes and its pass stops working. A phone can let it in again.")
        }
    }

    private func detail(for guest: ShellPhone) -> String {
        var parts = ["Added \(guest.grantedAt.formatted(date: .abbreviated, time: .omitted))"]
        if let by = shell.granterLabel(of: guest) { parts.append("through \(by)") }
        if shell.screenViewers.contains(where: { $0.phoneID == guest.phoneID }) { parts.append("viewing the screen") }
        return parts.joined(separator: " · ")
    }
}

/// The computers this Mac can reach, each handed over by a phone: access to a
/// PC (or another computer), and passes to other Macs' screens. Removing one
/// only forgets it here.
private struct ReachableComputersSection: View {
    @EnvironmentObject private var shell: RemoteShellController
    @State private var removing: Removal?
    /// PCs with a Windows login saved, read when this shows and as the list changes (no prompt: it isn't read).
    @State private var savedSignIns: Set<String> = []

    enum Removal: Identifiable {
        case computer(ReachableComputer)
        case pass(ReceivedScreenPass)

        var id: String {
            switch self {
            case .computer(let computer): "computer \(computer.id)"
            case .pass(let pass): "pass \(pass.id)"
            }
        }

        var name: String {
            switch self {
            case .computer(let computer): computer.credential.macName
            case .pass(let pass): pass.macName
            }
        }
    }

    var body: some View {
        Section {
            ForEach(shell.reachableComputers) { computer in
                ReachableComputerRow(computer: computer, hasSavedSignIn: savedSignIns.contains(computer.id),
                                     forgetSignIn: { forgetSignIn(computer.id) },
                                     remove: { removing = .computer(computer) })
            }
            ForEach(shell.screenPasses) { pass in
                ScreenPassRow(pass: pass, remove: { removing = .pass(pass) })
            }
        } header: {
            Text("Computers this Mac can reach")
        } footer: {
            Text("A phone with access to both handed these over. Removing one only forgets it on this Mac; the other computer can remove this Mac too. A saved sign-in is the Windows login a PC's screen window remembered, in this Mac's Keychain.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .confirmationDialog("Remove \(removing?.name ?? "this computer") from this Mac?",
                            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                            presenting: removing) { removal in
            Button("Remove", role: .destructive) { remove(removal) }
        } message: { removal in
            switch removal {
            case .computer:
                Text("This Mac can no longer reach it, and its saved sign-in is deleted. A view of it open here ends. A phone can hand it over again.")
            case .pass:
                Text("This Mac can no longer view its screen. A view of it open here ends. A phone can hand it over again.")
            }
        }
        .onAppear(perform: refreshSignIns)
        .onChange(of: shell.reachableComputers) { refreshSignIns() }
    }

    private func remove(_ removal: Removal) {
        switch removal {
        case .computer(let computer): shell.removeReachableComputer(computer.id)
        case .pass(let pass): shell.removeScreenPass(pass.id)
        }
        refreshSignIns()
    }

    private func forgetSignIn(_ hostID: String) {
        WindowsLoginStore.delete(hostID: hostID)
        refreshSignIns()
    }

    private func refreshSignIns() {
        savedSignIns = Set(shell.reachableComputers.map(\.id).filter { WindowsLoginStore.has(hostID: $0) })
    }
}

/// Access to another computer: what it is, which phone handed it over, what
/// this Mac may do there, and View, Forget Saved Sign-In and Remove.
private struct ReachableComputerRow: View {
    @Environment(\.openWindow) private var openWindow
    let computer: ReachableComputer
    let hasSavedSignIn: Bool
    let forgetSignIn: () -> Void
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: computer.credential.hostKind == HostInfo.kindWindows ? "pc" : "desktopcomputer")
                .font(.system(size: 17))
                .foregroundStyle(.secondary)
                .frame(width: 22)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(computer.credential.macName)
                Text(detail).font(.caption).foregroundStyle(.secondary)
                Text(access).font(.caption)
                    .foregroundStyle(computer.screenWaitsForOwner ? PTColor.attentionText : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if hasSavedSignIn {
                    Button("Forget Saved Sign-In", action: forgetSignIn)
                        .buttonStyle(.link)
                        .font(.caption)
                        .help("Delete the Windows login saved for \(computer.credential.macName). Its screen window asks for one again.")
                        .accessibilityLabel("Forget the saved sign-in for \(computer.credential.macName)")
                }
            }
            Spacer()
            if computer.mayAskForScreen {
                Button("View") { openWindow(id: PCScreenWindow.id, value: computer.id) }
                    .accessibilityLabel("View \(computer.credential.macName)'s screen")
            }
            Button("Remove…", action: remove)
                .accessibilityLabel("Remove \(computer.credential.macName)")
        }
        .padding(.vertical, 1)
    }

    /// "PC · from Dweej's iPhone · Nov 20, 2026".
    private var detail: String {
        var parts = [computer.kindName]
        if let from = computer.from { parts.append("from \(from)") }
        parts.append(computer.receivedAt.formatted(date: .abbreviated, time: .omitted))
        return parts.joined(separator: " · ")
    }

    /// What this Mac may do there, as the hand-over said: "Shell and screen", "Shell · the screen waits for its owner to allow it".
    private var access: String {
        var may: [String] = []
        if computer.scopes.contains(Computers.scopeShell) { may.append("shell") }
        if computer.scopes.contains(Computers.scopeScreen) { may.append("screen") }
        var parts = may.isEmpty ? [] : [may.joined(separator: " and ").capitalizedFirst]
        if computer.screenWaitsForOwner { parts.append(parts.isEmpty ? "Waits for its owner to allow the screen" : "waits for its owner to allow the screen") }
        return parts.isEmpty ? "Nothing yet" : parts.joined(separator: " · ")
    }
}

/// A pass to another Mac's screen: View and Remove.
private struct ScreenPassRow: View {
    @Environment(\.openWindow) private var openWindow
    let pass: ReceivedScreenPass
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "display")
                .font(.system(size: 17))
                .foregroundStyle(.secondary)
                .frame(width: 22)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(pass.macName)
                Text("Mac · screen pass · from \(pass.from) · \(pass.receivedAt.formatted(date: .abbreviated, time: .omitted))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("View") { openWindow(id: RemoteScreenWindow.id, value: pass.id) }
                .accessibilityLabel("View \(pass.macName)'s screen")
            Button("Remove…", action: remove)
                .accessibilityLabel("Remove the pass to \(pass.macName)'s screen")
        }
        .padding(.vertical, 1)
    }
}

/// Computers a phone gave access to this Mac (`Computers`): what each is and
/// may do, which phone shared it, and Stop (end what it has open now) or
/// Revoke (take its access away).
private struct ComputersWithAccessSection: View {
    @EnvironmentObject private var shell: RemoteShellController
    @State private var revoking: ShellPhone?

    var body: some View {
        Section {
            if shell.computerGuests.isEmpty {
                Text("No computers yet.").foregroundStyle(.secondary)
            }
            ForEach(shell.computerGuests, id: \.phoneID) { computer in
                ComputerGuestRow(computer: computer, revoke: { revoking = computer })
            }
        } header: {
            Text("Computers with access")
        } footer: {
            Text("A phone you let share access with other computers gave these access. Stop ends a computer's shells and its view of the screen now; it can connect again. Revoke takes its access away.")
        }
        .confirmationDialog("Revoke \(revoking?.label ?? "this computer")'s access?",
                            isPresented: Binding(get: { revoking != nil }, set: { if !$0 { revoking = nil } }),
                            presenting: revoking) { computer in
            Button("Revoke Access", role: .destructive) { shell.revokeComputer(computer.phoneID) }
        } message: { _ in
            Text("Its shells and any view of the screen close, and its key stops working. A phone you let share access can give it access again.")
        }
    }
}

/// One computer with access: its name and kind, which phone shared it and
/// when, what it may do now, and what it has open here.
private struct ComputerGuestRow: View {
    @EnvironmentObject private var shell: RemoteShellController
    let computer: ShellPhone
    let revoke: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: computer.kind == HostInfo.kindWindows ? "pc" : "desktopcomputer")
                .font(.system(size: 17))
                .foregroundStyle(.secondary)
                .frame(width: 22)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(computer.label)
                Text(detail).font(.caption).foregroundStyle(.secondary)
                Text(mayDo).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button("Stop") { shell.disconnectComputer(computer.phoneID) }
                .help("End \(computer.label)'s shells and its view of the screen now. It keeps its access and can connect again.")
                .accessibilityLabel("Stop \(computer.label)'s connections")
            Button("Revoke…", action: revoke)
                .accessibilityLabel("Revoke \(computer.label)'s access")
        }
        .padding(.vertical, 1)
    }

    private var kindName: String {
        switch computer.kind {
        case HostInfo.kindWindows: "PC"
        case HostInfo.kindMac: "Mac"
        default: "Computer"
        }
    }

    /// "PC · shared by Dweej's iPhone 2 days ago".
    private var detail: String {
        let when = computer.grantedAt.formatted(.relative(presentation: .named))
        if let by = shell.granterLabel(of: computer) { return "\(kindName) · shared by \(by) \(when)" }
        return "\(kindName) · shared \(when)"
    }

    /// What it may do now, as each of its requests is checked, then what it has open here.
    private var mayDo: String {
        let scopes = shell.computerScopes(computer.phoneID)
        var may: [String] = []
        if scopes.contains(Computers.scopeShell) { may.append("open shells as you") }
        if scopes.contains(Computers.scopeScreen) { may.append("see and control the screen") }
        var parts = [may.isEmpty ? "May do nothing for now" : "May " + may.joined(separator: " and ")]
        // Given the screen, but the phone that shared it may no longer see it: neither may the computer.
        if computer.screen == true, !scopes.contains(Computers.scopeScreen) {
            parts.append("the screen is off while \(shell.granterLabel(of: computer) ?? "its phone") may not see it")
        }
        parts += live
        return parts.joined(separator: " · ")
    }

    /// What it has open here that this Mac knows of: its view of the screen, a connection from anywhere, its shells.
    private var live: [String] {
        var parts: [String] = []
        if shell.screenViewers.contains(where: { $0.phoneID == computer.phoneID }) { parts.append("viewing the screen") }
        switch shell.irohStatus.paths[computer.phoneID] {
        case .direct?: parts.append("connected from anywhere, directly")
        case .relay?: parts.append("connected from anywhere, through a relay")
        case .unknown?: parts.append("connecting")
        case nil: break
        }
        let shells = shell.terminals.filter { terminal in
            shell.opener(of: terminal).map { $0.name == computer.label && $0.isComputer != false } ?? false
        }.count
        if shells > 0 { parts.append(shells == 1 ? "1 shell open" : "\(shells) shells open") }
        return parts
    }
}

private extension String {
    /// "Shell and screen", for the start of a line.
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

private struct PhonesSection: View {
    @EnvironmentObject private var shell: RemoteShellController
    @State private var revoking: ShellPhone?

    var body: some View {
        Section {
            if shell.phones.isEmpty {
                Text("No phones yet.").foregroundStyle(.secondary)
            }
            ForEach(shell.phones, id: \.phoneID) { phone in
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 12) {
                        Image(systemName: Self.symbol(for: phone))
                            .font(.system(size: 17))
                            .foregroundStyle(.secondary)
                            .frame(width: 22)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(phone.label)
                            Text(detail(for: phone)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Revoke…") { revoking = phone }
                    }
                    // What else this phone may do, under its name so long details don't squeeze it.
                    HStack(spacing: 18) {
                        permission("Screen", isOn: Binding(get: { phone.screenAllowed },
                                                           set: { shell.setScreenAllowed($0, for: phone.phoneID) }))
                            .help("Also let \(phone.label) see and control this screen.")
                        permission("Awake & VPN", isOn: Binding(get: { phone.controlAllowed },
                                                                set: { shell.setControlAllowed($0, for: phone.phoneID) }))
                            .help("Let \(phone.label) turn Keep awake and the VPN on or off, and lock this screen. Turning the VPN off asks for Face ID on the phone and shows a notice here. Battery and heat limits, VPN accounts and the kill switch setting stay on this Mac.")
                    }
                    .padding(.leading, 34)
                    permission("May share access with other computers", isOn: Binding(get: { phone.shareAllowed },
                                                                                      set: { shell.setShareAllowed($0, for: phone.phoneID) }))
                        .help("Let \(phone.label) give another of your computers access to this Mac.")
                        .padding(.leading, 34)
                }
                .padding(.vertical, 1)
            }
        } header: {
            Text("Phones with access")
        } footer: {
            if !shell.phones.isEmpty {
                Text("May share access with other computers lets that phone give another of your computers access to this Mac, from anywhere. Turning it off stops new sharing; computers it already let in stay until you remove them.")
            }
        }
        .confirmationDialog("Revoke \(revoking?.label ?? "this phone")'s access?",
                            isPresented: Binding(get: { revoking != nil }, set: { if !$0 { revoking = nil } }),
                            presenting: revoking) { phone in
            Button("Revoke Access", role: .destructive) { shell.revoke(phone.phoneID) }
        } message: { _ in
            Text("Its shells and any view of the screen close, and its key stops working. Plug it in again to give it a new one.")
        }
    }

    /// Label beside the switch: a form spreads a toggle's own label across the row.
    private func permission(_ title: String, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 6) {
            Toggle(title, isOn: isOn)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
            Text(title).font(.callout).foregroundStyle(.secondary)
        }
        .fixedSize()
    }

    /// The device it was granted through, by its pairing slot (`PhoneDevice`).
    static func symbol(for phone: ShellPhone) -> String {
        if phone.pairingSlot.hasPrefix("token.ipad.") { return "ipad" }
        if phone.pairingSlot.hasPrefix("token.android.") { return "smartphone" }
        return "iphone"
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
        let open = shell.terminals
        Section {
            if open.isEmpty {
                Text("No shells are open.").foregroundStyle(.secondary)
            }
            ForEach(open) { terminal in
                HStack(spacing: 12) {
                    Image(systemName: terminal.origin == .mac ? "macwindow" : "apple.terminal")
                        .font(.system(size: 16))
                        .foregroundStyle(PTTheme.accent)
                        .frame(width: 22)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(terminal.info.title).lineLimit(1).truncationMode(.middle)
                        Text(SessionWording.detail(terminal, opener: shell.opener(of: terminal)?.name,
                                                   someone: shell.computerGuests.isEmpty ? "a phone" : "a phone or computer"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if terminal.macViewers == 0 {
                        Button("Open in Terminal") { shell.openInTerminal(terminal.id) }
                            .help("Show this session in a terminal window here. A phone attached to it keeps it too.")
                    } else if terminal.origin == .phone {
                        Button("Stop Showing Here") { shell.stopShowingHere(terminal.id) }
                            .help("Stop showing this session in terminal windows here. It keeps running for the phone.")
                    }
                    Button("End…") { ending = terminal.info }
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

/// How a session's row says where it is and who is looking at it.
enum SessionWording {
    /// "In a terminal here · a phone is attached", "From Office PC · started 5 minutes ago".
    /// `opener` is who opened it, by name (`RemoteShellController.opener(of:)`); `someone` is who
    /// that may be while it isn't known, and who may be attached: "a phone", or "a phone or
    /// computer" once a computer has access.
    static func detail(_ terminal: ShellSessionDetail, opener: String? = nil, someone: String = "a phone", now: Date = Date()) -> String {
        var parts: [String] = []
        let from = "From \(opener ?? someone)"
        switch (terminal.origin, terminal.macViewers > 0) {
        case (.mac, true): parts.append("In a terminal here")
        case (.mac, false): parts.append("Started in a terminal here")
        case (.phone, true): parts.append(from + " · open in a terminal here")
        case (.phone, false): parts.append(from)
        }
        if terminal.phoneAttached { parts.append("\(someone) is attached") }
        parts.append("started " + Date(timeIntervalSince1970: terminal.info.startedAt).formatted(.relative(presentation: .named)))
        return parts.joined(separator: " · ")
    }
}

/// "Show new terminals on my phones": every new terminal window on this Mac
/// as a session, through a few lines in the shell's startup file.
private struct MacTerminalsSection: View {
    @EnvironmentObject private var shell: RemoteShellController

    var body: some View {
        Section {
            Toggle(isOn: Binding(get: { shell.sharesNewTerminals }, set: { shell.setSharesNewTerminals($0) })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Show new terminals on my phones")
                    Text("Each new terminal window (Terminal, iTerm, an editor's terminal) is a session your phones can open, with you still typing in it here.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .disabled(shell.terminalsUnsupported != nil)
            if let problem = shell.terminalsError ?? shell.terminalsUnsupported {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(PTColor.attentionText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            Text("Terminals on this Mac")
        } footer: {
            Text(footer)
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var footer: String {
        if shell.sharesNewTerminals {
            return "Passthrough added a few lines to \(shell.startupFileName); turning this off removes them. Terminals already open are not changed. "
                + "These terminals are recorded like any session, a phone with shell access can type into them, and quitting Passthrough closes their shells (the window then starts a new one). "
                + "They run inside Passthrough with its permissions, such as Full Disk Access, and while this is on any program on this Mac can start one."
        }
        if shell.hookWithoutChoice {
            return "Off, though Passthrough's lines are in \(shell.startupFileName) (an earlier version, or something else, put them there): "
                + "new terminals stay plain. Turn this on to show them on your phones, or on and off again to remove the lines."
        }
        return "Off: phones see only the sessions they start. Turning it on adds a few lines to \(shell.startupFileName). "
            + "Those terminals are then recorded like any session, a phone with shell access can type into them, and quitting Passthrough closes their shells. "
            + "They run inside Passthrough with its permissions, such as Full Disk Access, and while it is on any program on this Mac can start one."
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
            Picker(selection: $shell.historyRetention) {
                ForEach(RemoteShellController.HistoryRetention.allCases) { Text($0.title).tag($0) }
            } label: {
                Text("Keep shell history")
                Text("Older finished sessions are deleted, and the oldest go first past \(ByteCountFormatter.string(fromByteCount: TranscriptStore.maxTotalBytes, countStyle: .file)).")
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
            Text("Recordings stay on this Mac, out of backups, \(shell.historyRetention.keptFor). Phones with access can read them.")
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
