import SwiftUI
import PassthroughCore
import PassthroughUI

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var lock: AppLock
    @Environment(\.dismiss) private var dismiss
    @State private var showLog = false
    @State private var confirmForgetAll = false
    @AppStorage("showDebugLog") private var showDebugLog = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Name") {
                        TextField("iPhone", text: $model.deviceName)
                            .multilineTextAlignment(.trailing)
                            .submitLabel(.done)
                    }
                } header: {
                    Text("This iPhone")
                } footer: {
                    Text("Shown on your Mac.")
                }
                Section {
                    Picker("Hosting", selection: Binding(get: { model.hosting }, set: { model.hosting = $0 })) {
                        ForEach(AppModel.Hosting.allCases) { Text($0.title).tag($0) }
                    }
                    .disabled(model.state.isActive)
                } header: {
                    Text("How the proxy runs")
                } footer: {
                    Text(model.hosting == .background
                         ? "A local VPN configuration keeps the proxy alive with the screen off. It routes none of this phone's traffic; iOS shows a VPN badge while it runs."
                         : "The proxy runs only while Passthrough is open. The screen stays awake. Use this if the VPN configuration is unavailable.")
                    + (model.extensionAvailable ? Text("") : Text("\n\nThe VPN extension is not available on this device or simulator."))
                    + (model.state.isActive ? Text("\n\nStop sharing to change this.") : Text(""))
                }
                Section {
                    Toggle("Cellular only", isOn: $model.cellularOnly)
                    Toggle("Forward UDP (DNS, QUIC, calls)", isOn: $model.allowUDP)
                } header: {
                    Text("Network")
                } footer: {
                    Text("Cellular only: your Mac uses this iPhone's cellular data. While the iPhone is on Wi-Fi it shares the Wi-Fi instead, because iOS lets cellular sleep then. Off: your Mac uses whatever this iPhone is using.")
                }
                Section {
                    Toggle("Wireless link", isOn: $model.wireless)
                        .onChange(of: model.wireless) { _, on in
                            if on { LocalNetworkPermission.request() }
                            model.restartIfRunning()
                        }
                    Toggle("Use peer-to-peer Wi-Fi", isOn: $model.peerToPeer)
                        .disabled(!model.wireless)
                        .onChange(of: model.peerToPeer) { _, _ in model.restartIfRunning() }
                } header: {
                    Text("Wireless")
                } footer: {
                    Text("Reach linked Macs without the cable. Best: join this iPhone's Personal Hotspot from the Mac's Wi-Fi menu. It stays up while the iPhone is locked, and your Mac's traffic still goes through Passthrough.\n\nPeer-to-peer Wi-Fi needs no hotspot, but iOS pauses it for minutes at a time while the iPhone is locked.\n\nA Mac links the first time it connects over USB. The link is encrypted and only a paired Mac can use it.")
                }
                RemoteShellSettings(shell: model.shell)
                AppLockSettings()
                CaptureProtectionSettings()
                Section {
                    LabeledContent("SOCKS port") {
                        TextField("", value: $model.socksPort, format: .number.grouping(.never)).keyboardType(.numberPad).multilineTextAlignment(.trailing)
                    }
                    LabeledContent("Control port") {
                        TextField("", value: $model.controlPort, format: .number.grouping(.never)).keyboardType(.numberPad).multilineTextAlignment(.trailing)
                    }
                    Button("Forget all paired Macs", role: .destructive) { confirmForgetAll = true }
                        .disabled(model.pairedClients.isEmpty)
                } header: {
                    Text("Advanced")
                } footer: {
                    if model.state.isActive { Text("Stop sharing to change these.") }
                }
                .disabled(model.state.isActive)
                Section("Diagnostics") {
                    DisclosureGroup("Log", isExpanded: $showLog) {
                        if model.logEntries.isEmpty {
                            Text("Nothing logged yet. Start the proxy and connect a Mac; the extension's messages appear here.")
                                .font(.footnote).foregroundStyle(.secondary)
                        } else {
                            LogList(entries: model.logEntries, showDebug: showDebugLog).frame(height: 260)
                        }
                        Toggle("Show debug detail", isOn: $showDebugLog)
                        HStack {
                            Button("Copy log") {
                                UIPasteboard.general.string = model.logEntries.map { "\($0.date.formatted(.dateTime.hour().minute().second())) \($0.level.rawValue) \($0.message)" }.joined(separator: "\n")
                            }
                            .buttonStyle(.borderless)
                            Spacer()
                            Button("Clear", role: .destructive) { model.clearLog() }
                                .buttonStyle(.borderless)
                        }
                    }
                }
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Passthrough \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")")
                            .font(.footnote.weight(.semibold))
                        Text("The Mac connects through usbmuxd, Apple's USB multiplexer. This app listens on loopback only, so nothing is reachable over Wi-Fi or cellular. Every Mac authenticates with a per-device key that only its own keychain holds.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .confirmationDialog("Forget all paired Macs?", isPresented: $confirmForgetAll, titleVisibility: .visible) {
                Button("Forget All", role: .destructive) { model.revokeAll() }
            } message: {
                Text("Every Mac loses access, including Remote shell, until you pair it again.")
            }
        }
    }
}

/// Remote shell: whether it's set up, how to set it up, and how this iPhone reaches the Mac.
private struct RemoteShellSettings: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var shell: ShellModel

    var body: some View {
        // Macs that granted the shell; the shell's own list covers a grant it read before the registry caught up.
        let granting = model.pairedClients.filter { $0.shell != nil }.map { (id: $0.id, name: $0.shell?.macName ?? $0.name) }
        let shellMacs = granting.isEmpty ? shell.macs.map { (id: $0.macID, name: $0.macName) } : granting
        Section {
            if shellMacs.isEmpty {
                ShellSetupSteps(paired: !model.pairedClients.isEmpty)
                    .padding(.vertical, 6)
            } else {
                LabeledContent("Status") {
                    ShellStatusLabel(reach: shell.reach)
                }
                LabeledContent("Allowed by", value: ListFormatter.localizedString(byJoining: shellMacs.map(\.name)))
            }
        } header: {
            Text("Remote shell")
        } footer: {
            if shellMacs.isEmpty {
                Text("Open your Mac's shell from this iPhone. Every session is recorded on the Mac.")
            } else {
                Text("Every session is recorded on your Mac. To take access away, turn Remote shell off on the Mac, or forget the Mac on this iPhone.")
            }
        }
        if !shellMacs.isEmpty {
            Section {
                ConnectModePicker(shell: shell)
            } header: {
                Text("Connect from")
            }
            Section {
                ForEach(shellMacs, id: \.id) { mac in
                    ManualShellAddressRow(shell: shell, macID: mac.id, macName: mac.name)
                }
            } header: {
                Text("Mac address (optional)")
            } footer: {
                Text("Only needed when this iPhone can't find your Mac by itself, for example over Tailscale. Enter its Tailscale name or IP address. Leave blank to use the addresses your Mac shares.")
            }
        }
    }
}

/// "Hide shell and Screen from screenshots and recordings" (`CaptureProtection`).
private struct CaptureProtectionSettings: View {
    @AppStorage(CaptureProtection.key) private var enabled = CaptureProtection.defaultOn

    var body: some View {
        Section {
            Toggle("Hide shell and Screen from screenshots and recordings", isOn: $enabled)
        } header: {
            Text("Privacy")
        } footer: {
            Text("Covers the terminal, session history and your Mac's screen while this iPhone's screen is recorded, mirrored or shared. iOS doesn't let apps block screenshots, so take care with those.")
        }
    }
}

/// The app lock is always on; this explains how it behaves.
private struct AppLockSettings: View {
    @EnvironmentObject private var lock: AppLock

    var body: some View {
        let method = lock.method
        Section {
            LabeledContent("Unlock with", value: method == .none ? "No passcode set" : method.title)
            LabeledContent("Locks again", value: "After 1 minute away")
        } header: {
            Text("App lock")
        } footer: {
            Text(method == .none
                 ? "Set a passcode in the Settings app to lock Passthrough and to use Remote shell."
                 : "Passthrough opens locked, and locks again after a minute in the background. Tap Unlock to use \(method.title). Locking the app never stops sharing: your Mac stays online.")
        }
    }
}

/// "Connect from", for this iPhone only. Inline, so each choice says what it does.
private struct ConnectModePicker: View {
    @ObservedObject var shell: ShellModel

    var body: some View {
        Picker("Connect from", selection: $shell.connectMode) {
            option("Anywhere", detail: "Same Wi-Fi or Tailscale first, then from any network when \u{201C}Reach this Mac from anywhere\u{201D} is on in the Mac's Remote Shell settings.")
                .tag(ShellConnectMode.automatic)
            option("Same network only", detail: "Only on the same Wi-Fi or over Tailscale. Never through a relay.")
                .tag(ShellConnectMode.localOnly)
        }
        .pickerStyle(.inline)
        .labelsHidden()
    }

    private func option(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            Text(detail).font(.footnote).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

/// One Mac's manual shell address, saved as it is typed.
private struct ManualShellAddressRow: View {
    let shell: ShellModel
    let macID: String
    let macName: String
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(macName, systemImage: "laptopcomputer")
                .font(.subheadline.weight(.semibold))
            TextField("Tailscale name or IP address", text: $text)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.done)
        }
        .padding(.vertical, 4)
        .onAppear { text = shell.manualAddress(for: macID) ?? "" }
        .onChange(of: text) { _, value in shell.setManualAddress(value, for: macID) }
    }
}
