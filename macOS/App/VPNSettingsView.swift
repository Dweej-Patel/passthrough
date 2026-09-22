import SwiftUI
import AppKit
import UniformTypeIdentifiers
import PassthroughCore
import PassthroughUI

/// Settings ▸ VPN: profiles for the VPN layer, NordVPN one-time setup, file import.
struct VPNSettings: View {
    @EnvironmentObject private var session: SessionCoordinator
    @State private var showNordSheet = false
    @State private var importError: String?
    @State private var refreshing = false
    @State private var refreshError: String?

    private var selection: Binding<String> {
        Binding(get: { session.activeVPNProfile?.id.uuidString ?? "" },
                set: { session.vpnActiveProfileID = $0 })
    }

    var body: some View {
        Form {
            Section {
                if session.vpnProfiles.isEmpty {
                    Text("No profiles yet. Add NordVPN with your service credentials, or import a WireGuard .conf / OpenVPN .ovpn file.")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    Picker("Active profile", selection: selection) {
                        ForEach(session.vpnProfiles) { p in Text(p.name).tag(p.id.uuidString) }
                    }
                    .disabled(session.vpnWanted)
                }
                HStack {
                    Button("Add NordVPN…") { showNordSheet = true }
                    Button("Import file…") { importFile() }
                    Spacer()
                    Text(statusText).font(.caption).foregroundStyle(.secondary)
                }
                if let importError { Label(importError, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(PTTheme.warning) }
            } header: {
                Text("VPN layer")
            } footer: {
                Text("The VPN runs on the Mac, on top of the passthrough when it is on: the iPhone and the carrier then see a single encrypted flow to the VPN server. WireGuard and OpenVPN engines are built in; nothing else needs installing.")
            }

            if let profile = session.activeVPNProfile {
                ProfileDetail(profile: profile, refreshing: $refreshing, refreshError: $refreshError)
            }

            Section {
                Toggle("Kill switch: block all traffic if the VPN drops", isOn: $session.vpnKillSwitch)
                    .disabled(session.vpnWanted)
                Toggle("Block IPv6 while the VPN is on", isOn: $session.vpnBlockIPv6)
                    .disabled(session.vpnWanted)
                Toggle("Turn the VPN layer on whenever passthrough connects", isOn: $session.vpnAutoStart)
            } header: {
                Text("Behaviour")
            } footer: {
                Text("Kill switch: nothing leaves the Mac while the VPN is reconnecting; off, traffic falls back to the passthrough or Wi-Fi meanwhile. Block IPv6: most VPN servers (NordVPN included) carry no IPv6, so without this IPv6 traffic would bypass the VPN and reach the carrier directly; apps fall back to IPv4 instantly. Turn it off only if you need IPv6 and accept that. Both apply on the next VPN start.")
            }

            if !session.vpnProfiles.isEmpty {
                Section("All profiles") {
                    ForEach(session.vpnProfiles) { p in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(p.name).font(.body)
                                Text(p.subtitle).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if p.id == session.activeVPNProfile?.id {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(PTTheme.accent)
                            }
                            Button(role: .destructive) { session.deleteProfile(p) } label: { Image(systemName: "trash") }
                                .buttonStyle(.borderless)
                                .disabled(session.vpnWanted && p.id == session.activeVPNProfile?.id)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showNordSheet) { NordSetupSheet().environmentObject(session) }
    }

    private var statusText: String {
        guard session.vpnWanted else { return "Off" }
        switch session.vpn.state {
        case "connected": return "Connected via \(session.vpn.interface ?? "VPN")"
        case "starting": return "Connecting…"
        case "reconnecting": return "Reconnecting…"
        case "blocked": return "Blocked, reconnecting…"
        default: return session.vpn.state.capitalized
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
        do { try session.importProfile(from: url); importError = nil }
        catch { importError = error.localizedDescription }
    }
}

/// Per-profile details: credentials for OpenVPN, server refresh for NordVPN.
private struct ProfileDetail: View {
    @EnvironmentObject private var session: SessionCoordinator
    let profile: VPNProfile
    @Binding var refreshing: Bool
    @Binding var refreshError: String?
    @State private var username = ""
    @State private var password = ""
    @State private var saved = false

    var body: some View {
        Section {
            LabeledContent("Engine") { Text(profile.engine.label) }
            if let server = profile.server, !server.isEmpty { LabeledContent("Server") { Text(server).textSelection(.enabled) } }
            if let location = profile.location, !location.isEmpty { LabeledContent("Location") { Text(location) } }
            if profile.source == .nordvpn {
                LabeledContent("Protocol") { Text(profile.nordProtocol == "tcp" ? "OpenVPN TCP (port 443)" : "OpenVPN UDP") }
                LabeledContent("Country") { Text(profile.nordCountryName ?? "Fastest available") }
                HStack {
                    Button(refreshing ? "Refreshing…" : "Pick a fresh recommended server") {
                        refreshing = true; refreshError = nil
                        Task {
                            do { try await session.refreshNordServer(profile) } catch { refreshError = error.localizedDescription }
                            refreshing = false
                        }
                    }
                    .disabled(refreshing)
                    if let refreshError { Text(refreshError).font(.caption).foregroundStyle(PTTheme.danger) }
                }
            }
            if profile.needsCredentials {
                TextField("Username", text: $username)
                    .textContentType(.username)
                SecureField("Password", text: $password)
                HStack {
                    Button("Save credentials") {
                        session.setCredentials(username: username, password: password, for: profile)
                        saved = true
                    }
                    .disabled(username.isEmpty || password.isEmpty)
                    if saved { Label("Saved to Keychain", systemImage: "checkmark").font(.caption).foregroundStyle(.secondary) }
                }
            }
        } header: {
            Text(profile.name)
        } footer: {
            if profile.source == .nordvpn {
                Text("These are NordVPN's *service credentials* (Nord account ▸ Manual setup), not your login. They are stored in your Keychain and handed to the engine over a pipe, never written to disk.")
            }
        }
        .onAppear(perform: load)
        .onChange(of: profile.id) { _, _ in load() }
    }

    private func load() {
        let creds = VPNProfileStore.credentials(for: profile)
        username = creds.username
        password = creds.password
        saved = false
    }
}

/// One-time NordVPN setup: service credentials + protocol + optional country.
struct NordSetupSheet: View {
    @EnvironmentObject private var session: SessionCoordinator
    @Environment(\.dismiss) private var dismiss
    @State private var username = ""
    @State private var password = ""
    @State private var tcp = false
    @State private var countries: [NordVPN.Country] = []
    @State private var countryID: Int? = nil
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
            }
            .formStyle(.columns)
            Text("Find the service credentials in your Nord account under **Manual setup** (they differ from your login). Nord picks the least-loaded server near you; you can refresh it any time.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let error { Text(error).font(.caption).foregroundStyle(PTTheme.danger) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(working ? "Adding…" : "Add profile") { add() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent).tint(PTTheme.accentEnd)
                    .disabled(working || username.isEmpty || password.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 440)
        .task {
            countries = (try? await NordVPN.countries()) ?? []
            if let existing = session.vpnProfiles.first(where: { $0.source == .nordvpn }) {
                let creds = VPNProfileStore.credentials(for: existing)
                if username.isEmpty { username = creds.username; password = creds.password }
            }
        }
    }

    private func add() {
        working = true; error = nil
        let name = countries.first { $0.id == countryID }?.name
        Task {
            do {
                try await session.addNordProfile(username: username, password: password, countryID: countryID, countryName: name, tcp: tcp)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
            working = false
        }
    }
}
