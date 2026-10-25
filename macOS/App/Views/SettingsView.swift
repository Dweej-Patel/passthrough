import SwiftUI
import ServiceManagement
import PassthroughCore
import PassthroughUI

/// The Settings tabs; `SettingsWindow.show(_:tab:)` opens one directly.
enum SettingsTab: String {
    case general, remoteShell, vpn, network, diagnostics
    static let storageKey = "settingsTab"
}

struct SettingsView: View {
    @AppStorage(SettingsTab.storageKey) private var tab = SettingsTab.general

    var body: some View {
        TabView(selection: $tab) {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }.tag(SettingsTab.general)
            RemoteShellSettings().tabItem { Label("Remote Shell", systemImage: "terminal") }.tag(SettingsTab.remoteShell)
            VPNSettings().tabItem { Label("VPN", systemImage: "lock.shield") }.tag(SettingsTab.vpn)
            NetworkSettings().tabItem { Label("Network", systemImage: "network") }.tag(SettingsTab.network)
            DiagnosticsSettings().tabItem { Label("Diagnostics", systemImage: "stethoscope") }.tag(SettingsTab.diagnostics)
        }
        .frame(width: 540, height: 600)
    }
}

struct GeneralSettings: View {
    @EnvironmentObject private var session: SessionCoordinator
    @EnvironmentObject private var keepAwake: KeepAwakeController
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?
    @State private var confirmForget = false

    private var batteryText: String {
        guard keepAwake.battery.hasBattery, keepAwake.battery.percent >= 0 else { return "No battery" }
        return "\(keepAwake.battery.percent)% · \(keepAwake.battery.isOnAC ? "on power" : "on battery")"
    }

    private var wirelessText: String {
        switch session.wirelessWatch.state {
        case .watching: return session.device?.medium == .wireless ? "Linked" : "Waiting for a phone"
        case .unavailable: return session.wirelessWatch.hint ?? "Not available"
        default: return "Off"
        }
    }

    private var adbText: String {
        switch session.adbStatus {
        case .watching: return "Running"
        case .starting: return "Starting…"
        case .notInstalled: return "Not installed"
        case .unavailable: return "Not responding"
        case .idle: return "Off"
        }
    }

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $session.autoConnect) {
                    Text("Connect automatically")
                    Text("Starts passthrough when a phone is plugged in.")
                }
                Toggle(isOn: $launchAtLogin) {
                    Text("Open Passthrough at login")
                }
                .onChange(of: launchAtLogin) { _, on in
                    do { on ? try SMAppService.mainApp.register() : try SMAppService.mainApp.unregister(); loginError = nil }
                    catch { loginError = error.localizedDescription; launchAtLogin = !on }
                }
                if let loginError { Text(loginError).font(.caption).foregroundStyle(PTTheme.danger) }
            }
            Section {
                Toggle(isOn: Binding(get: { keepAwake.isOn }, set: { keepAwake.set($0) })) {
                    Text("Keep this Mac awake")
                    Text(keepAwake.hasLid ? "Even with the lid closed, so long sessions survive. The screen still turns off and locks."
                                          : "So long sessions survive. The screen still turns off and locks.")
                }
                if let reason = keepAwake.blockedReason {
                    Label(reason, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(PTTheme.warning)
                }
                if keepAwake.hasLid {
                    Toggle(isOn: $keepAwake.batteryAutoOff) {
                        Text("Turn off at low battery")
                        Text("So a closed laptop sleeps instead of draining.")
                    }
                }
                if keepAwake.hasLid, keepAwake.batteryAutoOff {
                    Stepper(value: $keepAwake.batteryAutoOffThreshold, in: 5...80, step: 5) {
                        HStack {
                            Text("Battery level")
                            Spacer()
                            Text("\(keepAwake.batteryAutoOffThreshold)%").foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                }
                Toggle(isOn: $keepAwake.thermalAutoOff) {
                    Text("Turn off when the Mac runs hot")
                    Text("When macOS starts slowing the Mac down to cool it.")
                }
                LabeledContent("Right now") {
                    Text("\(batteryText) · \(KeepAwakeController.describe(keepAwake.thermal))")
                }
            } header: {
                Text("Keep awake")
            } footer: {
                Text(keepAwake.hasLid ? "Turns itself off when you quit Passthrough. A closed, running Mac in a bag can overheat: keep it on power or in open air."
                                      : "Turns itself off when you quit Passthrough.")
            }
            Section {
                Picker(selection: $session.connectionMode) {
                    ForEach(SessionCoordinator.ConnectionMode.allCases) { Text($0.title).tag($0) }
                } label: {
                    Text("Connect over")
                    Text("Automatic prefers the cable.")
                }
                if session.connectionMode != .cable {
                    LabeledContent("Wireless") { Text(wirelessText) }
                    LabeledContent("Linked phones") { Text("\(session.linkedPhoneCount)") }
                    Toggle(isOn: $session.hotspotGuard) {
                        Text("Don't use the hotspot's own data")
                        Text("While passthrough is down, the Mac reaches only the phone.")
                    }
                    Toggle(isOn: $session.peerToPeer) {
                        Text("Use peer-to-peer Wi-Fi")
                        Text("No hotspot needed, but it drops for minutes while an iPhone is locked.")
                    }
                }
            } header: {
                Text("Connection")
            } footer: {
                if session.connectionMode != .cable {
                    Text("To go wireless, join the iPhone's Personal Hotspot from the Wi-Fi menu and turn on Wireless link in Passthrough on the phone. A phone links the first time it connects over USB.")
                }
            }
            Section {
                Toggle(isOn: $session.androidEnabled) {
                    Text("Android phones")
                    Text("Connect through adb, Android's USB debugging bridge.")
                }
                if session.androidEnabled { LabeledContent("adb") { Text(adbText) } }
                if let hint = session.androidHint {
                    Label(hint, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(PTTheme.warning)
                }
            } header: {
                Text("Android")
            } footer: {
                if session.androidEnabled {
                    Text("Needs platform-tools (brew install android-platform-tools) and USB debugging turned on in the phone's Developer options. Allow this Mac when the phone asks.")
                }
            }
            Section("Pairing") {
                LabeledContent("This Mac") { Text(session.macName) }
                LabeledContent("Paired") { Text(session.hasToken ? "Yes" : "Not yet") }
                Button("Forget Pairing…", role: .destructive) { confirmForget = true }.disabled(!session.hasToken)
            }
            Section {
                LabeledContent("Status") {
                    HStack(spacing: 6) {
                        Circle().fill(helperColor).frame(width: 7, height: 7)
                        Text(helperText)
                    }
                }
                if let note = session.helperNote {
                    Text(note).font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Button("Open Login Items") { session.openLoginItems() }
                    Button("Register Again") { session.retryHelper() }
                }
            } header: {
                Text("Helper")
            } footer: {
                Text("The helper routes the Mac's traffic. Approve it once in System Settings › General › Login Items.")
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Forget this Mac's pairing?", isPresented: $confirmForget) {
            Button("Forget Pairing", role: .destructive) { session.forgetPairing() }
        } message: {
            Text("The phone needs a new pairing code before it can connect again, and loses its remote shell access.")
        }
    }

    private var helperColor: Color {
        switch session.helperAvailability {
        case .ready: return PTTheme.success
        case .needsApproval: return PTTheme.warning
        case .notRegistered, .failed: return PTTheme.danger
        }
    }

    private var helperText: String {
        switch session.helperAvailability {
        case .ready: return "Approved and ready"
        case .needsApproval: return "Waiting for approval in System Settings"
        case .notRegistered: return "Not registered"
        case .failed(let why): return why
        }
    }
}

struct NetworkSettings: View {
    @EnvironmentObject private var session: SessionCoordinator

    var body: some View {
        Form {
            Section {
                TextField("DNS servers", text: $session.dnsServers, prompt: Text("1.1.1.1, 1.0.0.1"))
                Toggle("Route IPv6 as well", isOn: $session.ipv6Enabled)
            } footer: {
                Text("DNS queries travel through the iPhone like everything else. Changes apply on the next connection.")
            }
            Section("Advanced") {
                TextField("Local SOCKS port", value: $session.localPort, format: .number)
                TextField("Tunnel MTU", value: $session.mtu, format: .number)
            }
        }
        .formStyle(.grouped)
        .disabled(session.phase.isConnected)
    }
}

struct DiagnosticsSettings: View {
    @EnvironmentObject private var session: SessionCoordinator
    @AppStorage("showDebugLog") private var showDebugLog = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Log").font(.headline)
                Spacer()
                Toggle("Debug detail", isOn: $showDebugLog).toggleStyle(.checkbox).font(.caption)
                Button("Copy") {
                    let text = session.logEntries.map { "\($0.date.formatted(.dateTime.hour().minute().second())) \($0.level.rawValue) \($0.message)" }.joined(separator: "\n")
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
            }
            LogList(entries: session.logEntries, showDebug: showDebugLog)
            Text("Helper logs go to the unified log: `log stream --predicate 'process == \"PassthroughHelper\"'`.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(16)
    }
}
