import SwiftUI
import AppKit
import UniformTypeIdentifiers
import PassthroughCore
import PassthroughUI

/// Settings ▸ VPN: profiles for the VPN layer, NordVPN one-time setup, file import.
struct VPNSettings: View {
    @EnvironmentObject private var vpnLayer: VPNLayer
    @State private var showNordSheet = false
    @State private var importError: String?
    @State private var refreshing = false
    @State private var refreshError: String?

    private var selection: Binding<String> {
        Binding(get: { vpnLayer.activeProfile?.id.uuidString ?? "" },
                set: { vpnLayer.activeProfileID = $0 })
    }

    var body: some View {
        Form {
            Section {
                if vpnLayer.profiles.isEmpty {
                    Text("No profiles yet. Add NordVPN with your service credentials, or import a WireGuard .conf / OpenVPN .ovpn file.")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    Picker("Active profile", selection: selection) {
                        ForEach(vpnLayer.profiles) { p in Text(p.name).tag(p.id.uuidString) }
                    }
                    .disabled(vpnLayer.isWanted)
                }
                LabeledContent("Status") {
                    HStack(spacing: 6) {
                        Circle().fill(statusColor).frame(width: 7, height: 7)
                        Text(statusText)
                    }
                }
                HStack {
                    Button("Add NordVPN…") { showNordSheet = true }
                    Button("Import File…") { importFile() }
                }
                if let importError { Label(importError, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(PTTheme.warning) }
            } header: {
                Text("VPN layer")
            } footer: {
                Text("Runs on this Mac, on top of passthrough, so the phone and the carrier see one encrypted flow. WireGuard and OpenVPN are built in.")
            }

            if let profile = vpnLayer.activeProfile {
                ProfileDetail(profile: profile, refreshing: $refreshing, refreshError: $refreshError)
            }

            Section {
                Toggle(isOn: $vpnLayer.killSwitch) {
                    Text("Kill switch")
                    Text("Nothing leaves the Mac while the VPN reconnects. Off, traffic falls back to passthrough or Wi-Fi meanwhile.")
                }
                .disabled(vpnLayer.isWanted)
                Toggle(isOn: $vpnLayer.blockIPv6) {
                    Text("Block IPv6 while the VPN is on")
                    Text("Most VPN servers, NordVPN included, carry no IPv6, so it would go around the VPN. Apps fall back to IPv4.")
                }
                .disabled(vpnLayer.isWanted)
                Toggle(isOn: $vpnLayer.autoStart) {
                    Text("Start with passthrough")
                    Text("Turns the VPN on whenever passthrough connects.")
                }
            } header: {
                Text("Behaviour")
            } footer: {
                Text(vpnLayer.isWanted ? "Turn the VPN off to change the kill switch or IPv6." : "Kill switch and IPv6 changes apply the next time the VPN starts.")
            }

            if !vpnLayer.profiles.isEmpty {
                Section("All profiles") {
                    ForEach(vpnLayer.profiles) { p in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(p.name).font(.body)
                                Text(p.subtitle).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if p.id == vpnLayer.activeProfile?.id {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(PTTheme.accent)
                            }
                            Button(role: .destructive) { vpnLayer.deleteProfile(p) } label: { Image(systemName: "trash") }
                                .buttonStyle(.borderless)
                                .disabled(vpnLayer.isWanted && p.id == vpnLayer.activeProfile?.id)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showNordSheet) { NordSetupSheet().environmentObject(vpnLayer) }
    }

    private var statusColor: Color {
        guard vpnLayer.isWanted else { return .secondary }
        switch vpnLayer.status.state {
        case "connected": return PTTheme.success
        case "blocked": return PTTheme.danger
        default: return PTTheme.warning
        }
    }

    private var statusText: String {
        guard vpnLayer.isWanted else { return "Off" }
        switch vpnLayer.status.state {
        case "connected": return "Connected via \(vpnLayer.status.interface ?? "VPN")"
        case "starting": return "Connecting…"
        case "reconnecting": return "Reconnecting…"
        case "blocked": return "Blocked, reconnecting…"
        default: return vpnLayer.status.state.capitalized
        }
    }

    private func importFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        var types: [UTType] = [.plainText, .data]
        if let ovpn = UTType(filenameExtension: "ovpn") { types.append(ovpn) }
        if let conf = UTType(filenameExtension: "conf") { types.append(conf) }
        panel.allowedContentTypes = types
        panel.message = "Choose a WireGuard .conf or OpenVPN .ovpn profile"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try vpnLayer.importProfile(from: url); importError = nil }
        catch { importError = error.localizedDescription }
    }
}

/// Per-profile details: editable name, area and protocol for NordVPN,
/// credentials for OpenVPN.
private struct ProfileDetail: View {
    @EnvironmentObject private var vpnLayer: VPNLayer
    let profile: VPNProfile
    @Binding var refreshing: Bool
    @Binding var refreshError: String?
    @State private var name = ""
    @State private var username = ""
    @State private var password = ""
    @State private var saved = false
    @State private var saveFailed = false
    @State private var countries: [NordVPN.Country] = []
    @State private var countryID: Int? = nil
    @State private var cityID: Int? = nil
    @State private var tcp = false

    private var nordEdited: Bool {
        countryID != profile.nordCountryID || cityID != profile.nordCityID || tcp != (profile.nordProtocol == "tcp")
    }

    var body: some View {
        Section {
            TextField("Name", text: $name, onCommit: { vpnLayer.renameProfile(profile, to: name) })
            LabeledContent("Engine") { Text(profile.engine.label) }
            if profile.source == .nordvpn {
                Picker("Protocol", selection: $tcp) {
                    Text("OpenVPN UDP (recommended)").tag(false)
                    Text("OpenVPN TCP 443 (if UDP is blocked)").tag(true)
                }
                Picker("Country", selection: $countryID) {
                    Text("Fastest available").tag(Int?.none)
                    ForEach(countries) { c in Text(c.name).tag(Int?.some(c.id)) }
                }
                .onChange(of: countryID) { old, new in if old != new, new != profile.nordCountryID { cityID = nil } }
                if let country = countries.first(where: { $0.id == countryID }), country.cities.count > 1 {
                    Picker("City", selection: $cityID) {
                        Text("Any city").tag(Int?.none)
                        ForEach(country.cities.sorted { $0.name < $1.name }) { c in Text(c.name).tag(Int?.some(c.id)) }
                    }
                }
                if let server = profile.server { LabeledContent("Current server") { Text("\(server)\(profile.location.map { " · \($0)" } ?? "")").textSelection(.enabled) } }
                HStack {
                    Button(refreshing ? "Working…" : (nordEdited ? "Apply and Pick Server" : "Pick a Fresh Server")) {
                        refreshing = true; refreshError = nil
                        let country = countries.first { $0.id == countryID }
                        let city = country?.cities.first { $0.id == cityID }
                        Task {
                            do {
                                if nordEdited || name != profile.name {
                                    try await vpnLayer.updateNordProfile(profile, countryID: countryID, countryName: country?.name,
                                                                        cityID: cityID, cityName: city?.name, tcp: tcp, name: name)
                                } else {
                                    try await vpnLayer.refreshNordServer(profile)
                                }
                            } catch { refreshError = error.localizedDescription }
                            refreshing = false
                        }
                    }
                    .disabled(refreshing)
                    if let refreshError { Text(refreshError).font(.caption).foregroundStyle(PTTheme.danger) }
                }
            } else {
                if let server = profile.server, !server.isEmpty { LabeledContent("Server") { Text(server).textSelection(.enabled) } }
            }
            if profile.needsCredentials {
                TextField("Username", text: $username)
                    .textContentType(.username)
                SecureField("Password", text: $password)
                HStack {
                    Button("Save Credentials") {
                        saveFailed = !vpnLayer.setCredentials(username: username, password: password, for: profile)
                        saved = !saveFailed
                    }
                    .disabled(username.isEmpty || password.isEmpty)
                    if saved { Label("Saved to Keychain", systemImage: "checkmark").font(.caption).foregroundStyle(.secondary) }
                    if saveFailed { Label("Could not save to the Keychain (see Diagnostics)", systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(PTTheme.danger) }
                }
            }
        } header: {
            Text("Edit profile")
        } footer: {
            if profile.source == .nordvpn {
                Text("Applying picks Nord's least-loaded server for that area and reconnects if this profile is running. Service credentials are in your Nord account under Manual setup, and are kept in the Keychain.")
            }
        }
        .onAppear(perform: load)
        .onChange(of: profile.id) { _, _ in load() }
        .task(id: profile.id) {
            if profile.source == .nordvpn, countries.isEmpty { countries = (try? await NordVPN.countries()) ?? [] }
        }
    }

    private func load() {
        name = profile.name
        let creds = VPNProfileStore.credentials(for: profile)
        username = creds.username
        password = creds.password
        saved = false
        countryID = profile.nordCountryID
        cityID = profile.nordCityID
        tcp = profile.nordProtocol == "tcp"
    }
}

/// One-time NordVPN setup: service credentials + protocol + optional country.
struct NordSetupSheet: View {
    @EnvironmentObject private var vpnLayer: VPNLayer
    @Environment(\.dismiss) private var dismiss
    @State private var username = ""
    @State private var password = ""
    @State private var tcp = false
    @State private var countries: [NordVPN.Country] = []
    @State private var countryID: Int? = nil
    @State private var cityID: Int? = nil
    @State private var working = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "lock.shield.fill").font(.system(size: 22, weight: .semibold)).foregroundStyle(PTTheme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Add NordVPN").font(.headline)
                    Text("Uses Nord's official manual-setup profiles with your service credentials.").font(.caption).foregroundStyle(.secondary)
                }
            }
            Form {
                TextField("Service username", text: $username).textContentType(.username)
                SecureField("Service password", text: $password)
                Picker("Protocol", selection: $tcp) {
                    Text("UDP (recommended)").tag(false)
                    Text("TCP 443 (if UDP is blocked)").tag(true)
                }
                Picker("Country", selection: $countryID) {
                    Text("Fastest available").tag(Int?.none)
                    ForEach(countries) { c in Text(c.name).tag(Int?.some(c.id)) }
                }
                .onChange(of: countryID) { _, _ in cityID = nil }
                if let country = countries.first(where: { $0.id == countryID }), country.cities.count > 1 {
                    Picker("City", selection: $cityID) {
                        Text("Any city").tag(Int?.none)
                        ForEach(country.cities.sorted { $0.name < $1.name }) { c in Text(c.name).tag(Int?.some(c.id)) }
                    }
                }
            }
            .formStyle(.columns)
            Text("Find the service credentials in your Nord account under **Manual setup** (they differ from your login). Nord picks the least-loaded server near you; you can refresh it any time.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let error { Text(error).font(.caption).foregroundStyle(PTTheme.danger) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(working ? "Adding…" : "Add Profile") { add() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent).tint(PTTheme.accentEnd)
                    .disabled(working || username.isEmpty || password.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 440)
        .task {
            countries = (try? await NordVPN.countries()) ?? []
            if let existing = vpnLayer.profiles.first(where: { $0.source == .nordvpn }) {
                let creds = VPNProfileStore.credentials(for: existing)
                if username.isEmpty { username = creds.username; password = creds.password }
            }
        }
    }

    private func add() {
        working = true; error = nil
        let country = countries.first { $0.id == countryID }
        let city = country?.cities.first { $0.id == cityID }
        Task {
            do {
                try await vpnLayer.addNordProfile(username: username, password: password, countryID: countryID, countryName: country?.name,
                                                 cityID: cityID, cityName: city?.name, tcp: tcp)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
            working = false
        }
    }
}
