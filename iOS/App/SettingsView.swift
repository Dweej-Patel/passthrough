import SwiftUI
import PassthroughCore
import PassthroughUI

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var showLog = false
    @AppStorage("showDebugLog") private var showDebugLog = false

    var body: some View {
        NavigationStack {
            Form {
                Section("This iPhone") {
                    TextField("Name shown on the Mac", text: $model.deviceName)
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
                }
                Section {
                    Toggle("Cellular only", isOn: $model.cellularOnly)
                    Toggle("Forward UDP (DNS, QUIC, calls)", isOn: $model.allowUDP)
                } header: {
                    Text("Network")
                } footer: {
                    Text("On: the Mac uses cellular data. While this phone is on Wi-Fi it uses the Wi-Fi instead, because iOS lets cellular sleep then. Off: the Mac rides whatever this phone is using.")
                }
                Section("Advanced") {
                    LabeledContent("SOCKS port") {
                        TextField("", value: $model.socksPort, format: .number).keyboardType(.numberPad).multilineTextAlignment(.trailing)
                    }
                    LabeledContent("Control port") {
                        TextField("", value: $model.controlPort, format: .number).keyboardType(.numberPad).multilineTextAlignment(.trailing)
                    }
                    Button("Forget all paired Macs", role: .destructive) { model.registry.revokeAll() }
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
                            Spacer()
                            Button("Clear", role: .destructive) { model.clearLog() }
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
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}
