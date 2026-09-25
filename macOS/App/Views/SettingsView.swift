import SwiftUI
import ServiceManagement
import PassthroughCore
import PassthroughUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }
            VPNSettings().tabItem { Label("VPN", systemImage: "lock.shield") }
            NetworkSettings().tabItem { Label("Network", systemImage: "network") }
            DiagnosticsSettings().tabItem { Label("Diagnostics", systemImage: "stethoscope") }
        }
        .frame(width: 500, height: 520)
    }
}

struct GeneralSettings: View {
    @EnvironmentObject private var session: SessionCoordinator
    @EnvironmentObject private var keepAwake: KeepAwakeController
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    private var batteryFooter: String {
        let now: String
        if keepAwake.battery.hasBattery, keepAwake.battery.percent >= 0 {
            now = " Currently \(keepAwake.battery.percent)%\(keepAwake.battery.isOnAC ? " (on power)" : " (on battery)")."
        } else {
            now = ""
        }
        return "When on battery power and keep awake is on, it switches off automatically at this level so a closed laptop can sleep instead of draining.\(now)"
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
                Toggle("Connect automatically when a phone is plugged in", isOn: $session.autoConnect)
                Toggle("Keep this Mac awake (even with the lid closed)", isOn: Binding(
                    get: { keepAwake.isOn },
                    set: { keepAwake.set($0) }))
                if let reason = keepAwake.blockedReason {
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
                Text("Keep awake stops the Mac from sleeping so long sessions survive when you step away, including with the lid closed (via the root helper). It reverts automatically when you turn it off or quit Passthrough, and switches itself off at low battery or when the Mac runs hot (below). Still, a closed, running Mac in a bag can overheat, so use lid-closed on power or in open air.")
            }
            Section {
                Toggle("Turn off keep awake at low battery", isOn: $keepAwake.batteryAutoOff)
                if keepAwake.batteryAutoOff {
                    Stepper(value: $keepAwake.batteryAutoOffThreshold, in: 5...80, step: 5) {
                        HStack {
                            Text("Threshold")
                            Spacer()
                            Text("\(keepAwake.batteryAutoOffThreshold)%").foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                }
            } header: {
                Text("Battery")
            } footer: {
                Text(batteryFooter)
            }
            Section {
                Toggle("Turn off keep awake when the Mac runs hot", isOn: $keepAwake.thermalAutoOff)
            } header: {
                Text("Heat")
            } footer: {
                Text("macOS reports how hard it is working to stay cool. When it reaches “serious”, where it starts slowing the Mac down, keep awake switches off so a closed laptop can sleep and cool. Right now the Mac is \(KeepAwakeController.describe(keepAwake.thermal)).")
            }
            Section {
                Picker("Connect over", selection: $session.connectionMode) {
                    ForEach(SessionCoordinator.ConnectionMode.allCases) { Text($0.title).tag($0) }
                }
                if session.connectionMode != .cable {
                    LabeledContent("Wireless") { Text(wirelessText) }
                    LabeledContent("Linked phones") { Text("\(session.linkedPhoneCount)") }
                    Toggle("Don't use the hotspot's own data", isOn: $session.hotspotGuard)
                    Toggle("Use peer-to-peer Wi-Fi", isOn: $session.peerToPeer)
                }
            } header: {
                Text("Connection")
            } footer: {
                Text("Wireless: join the iPhone's Personal Hotspot from the Wi-Fi menu (it stays up while the iPhone is locked) and turn on Wireless link in Passthrough on the phone. Traffic still goes through Passthrough; with \"Don't use the hotspot's own data\" the Mac reaches nothing but the phone while passthrough is down, so the hotspot allowance isn't touched. Peer-to-peer Wi-Fi needs no hotspot but drops for minutes while an iPhone is locked. A phone links the first time it connects over USB. Automatic prefers the cable.")
            }
            Section {
                Toggle("Android phones (via adb)", isOn: $session.androidEnabled)
                if session.androidEnabled { LabeledContent("adb") { Text(adbText) } }
                if let hint = session.androidHint {
                    Label(hint, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(PTTheme.warning)
                }
            } header: {
                Text("Android")
            } footer: {
                Text("Android phones connect through adb, Android's USB debugging bridge. Install platform-tools (brew install android-platform-tools), turn on USB debugging on the phone, and allow this Mac when it asks.")
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
