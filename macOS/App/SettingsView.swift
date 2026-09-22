import SwiftUI
import ServiceManagement
import PassthroughCore
import PassthroughUI

struct SettingsView: View {
    @EnvironmentObject private var session: SessionCoordinator

    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }
            NetworkSettings().tabItem { Label("Network", systemImage: "network") }
            DiagnosticsSettings().tabItem { Label("Diagnostics", systemImage: "stethoscope") }
        }
        .frame(width: 460, height: 380)
    }
}

struct GeneralSettings: View {
    @EnvironmentObject private var session: SessionCoordinator
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    private var batteryFooter: String {
        let now: String
        if session.battery.hasBattery, session.battery.percent >= 0 {
            now = " Currently \(session.battery.percent)%\(session.battery.isOnAC ? " (on power)" : " (on battery)")."
        } else {
            now = ""
        }
        return "When on battery power and keep awake is on, it switches off automatically at this level so a closed laptop can sleep instead of draining.\(now)"
    }

    var body: some View {
        Form {
            Section {
                Toggle("Connect automatically when the iPhone is plugged in", isOn: $session.autoConnect)
                Toggle("Keep this Mac awake (even with the lid closed)", isOn: Binding(
                    get: { session.keepAwake },
                    set: { session.setKeepAwake($0) }))
                if let reason = session.keepAwakeBlockedReason {
                    Label(reason, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(PTTheme.warning)
                }
                Toggle("Open Passthrough at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        do { on ? try SMAppService.mainApp.register() : try SMAppService.mainApp.unregister(); loginError = nil }
                        catch { loginError = error.localizedDescription; launchAtLogin = !on }
                    }
                if let loginError { Text(loginError).font(.caption).foregroundStyle(PTTheme.danger) }
            } footer: {
                Text("Keep awake stops the Mac from sleeping so long sessions survive when you step away, including with the lid closed (via the root helper). It reverts automatically when you turn it off or quit Passthrough. Caution: a closed, running Mac in a bag can overheat and drain the battery, so only use lid-closed on power or in open air.")
            }
            Section {
                Toggle("Turn off keep awake at low battery", isOn: $session.batteryAutoOff)
                if session.batteryAutoOff {
                    Stepper(value: $session.batteryAutoOffThreshold, in: 5...80, step: 5) {
                        HStack {
                            Text("Threshold")
                            Spacer()
                            Text("\(session.batteryAutoOffThreshold)%").foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                }
            } header: {
                Text("Battery")
            } footer: {
                Text(batteryFooter)
            }
            Section("Pairing") {
                LabeledContent("This Mac") { Text(session.macName) }
                LabeledContent("Paired") { Text(session.hasToken ? "Yes" : "Not yet") }
                Button("Forget pairing", role: .destructive) { session.forgetPairing() }.disabled(!session.hasToken)
            }
            Section("Helper") {
                LabeledContent("Status") { Text(helperText) }
                HStack {
                    Button("Open Login Items") { session.openLoginItems() }
                    Button("Register again") { session.retryHelper() }
                }
            }
        }
        .formStyle(.grouped)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Log").font(.headline)
                Spacer()
                Button("Copy") {
                    let text = session.logEntries.map { "\($0.date.formatted(.dateTime.hour().minute().second())) \($0.level.rawValue) \($0.message)" }.joined(separator: "\n")
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
            }
            LogList(entries: session.logEntries)
            Text("Helper logs go to the unified log: `log stream --predicate 'process == \"PassthroughHelper\"'`.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(16)
    }
}
