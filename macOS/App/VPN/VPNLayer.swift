import Foundation
import SwiftUI
import PassthroughCore

/// The optional VPN layer: a bundled WireGuard/OpenVPN engine the root helper
/// runs on top of whatever network is current (the passthrough when it is up).
/// Owns the saved profiles and mirrors the helper's view of the session.
@MainActor
final class VPNLayer: ObservableObject {
    @Published private(set) var status = VPNStatus()
    /// The user turned the layer on (it may still be starting or failing).
    @Published private(set) var isWanted = false
    @Published private(set) var error: String?
    @Published private(set) var profiles: [VPNProfile] = VPNProfileStore.load()
    @AppStorage("vpnKillSwitch") var killSwitch = true
    @AppStorage("vpnBlockIPv6") var blockIPv6 = true
    @AppStorage("vpnAutoStart") var autoStart = false
    @AppStorage("vpnActiveProfile") var activeProfileID = ""
    var activeProfile: VPNProfile? { profiles.first { $0.id.uuidString == activeProfileID } ?? profiles.first }

    /// Fires when turning the layer on needs the helper approved first.
    var onHelperRequired: (() -> Void)?

    private let helper: HelperClient
    /// Bumped on every on/off so a late status poll can't undo a newer choice.
    private(set) var generation = 0
    /// A profile imported for diagnostics, removed again on quit.
    private var temporaryProfile: VPNProfile?

    init(helper: HelperClient) {
        self.helper = helper
    }

    // MARK: On and off

    /// Turn the layer on/off. The helper runs the engine and owns the routing;
    /// it also restarts the session by itself when passthrough connects or
    /// disconnects underneath it.
    func set(_ on: Bool) {
        error = nil
        generation += 1
        guard on else {
            isWanted = false
            status = VPNStatus()
            Task { await helper.stopVPN() }
            return
        }
        guard let profile = activeProfile else {
            error = "Add a VPN profile in Settings ▸ VPN first."
            return
        }
        guard let text = VPNProfileStore.config(for: profile), !text.isEmpty else {
            if profile.source == .nordvpn {
                // Re-fetch Nord's profile for the same choice, then try again.
                status = VPNStatus(state: "starting", name: profile.name, engine: profile.engine.rawValue)
                isWanted = true
                Task {
                    do { try await refreshNordServer(profile) } catch { isWanted = false; status = VPNStatus(); self.error = error.localizedDescription }
                }
                return
            }
            error = "The profile's configuration is missing. Remove it and add it again."
            return
        }
        let creds = VPNProfileStore.credentials(for: profile)
        if profile.needsCredentials, creds.username.isEmpty || creds.password.isEmpty {
            error = "\(profile.name) needs a username and password. Enter them in Settings ▸ VPN."
            return
        }
        isWanted = true
        status = VPNStatus(state: "starting", name: profile.name, engine: profile.engine.rawValue)
        let config = HelperClient.VPNConfig(engine: profile.engine.rawValue, name: profile.name, config: text,
                                            username: creds.username, password: creds.password, killSwitch: killSwitch, blockIPv6: blockIPv6)
        Task {
            guard helper.ensureRegistered() else {
                isWanted = false; status = VPNStatus()
                error = "Approve the helper in System Settings before turning the VPN layer on."
                onHelperRequired?()
                return
            }
            await helper.ensureCurrent(mayReregister: false)
            guard isWanted else { return }
            do {
                try await helper.startVPN(config)
                ptLog(.info, "VPN layer starting: \(profile.name) (\(profile.engine.label))")
                apply(await helper.status())
            } catch {
                isWanted = false
                status = VPNStatus()
                self.error = error.localizedDescription
                ptLog(.error, "VPN layer failed to start: \(error.localizedDescription)")
            }
        }
    }

    /// Passthrough just connected: start the layer if the user asked for that.
    func passthroughConnected() {
        if autoStart, !isWanted, activeProfile != nil { set(true) }
    }

    /// Folds in the helper's `getStatus` reply. An empty reply means the helper
    /// didn't answer, which says nothing about the VPN.
    func apply(_ reply: [String: Any]) {
        guard isWanted else { return }
        let parsed = VPNStatus(from: reply[VPNStatusKey.vpn] as? [String: Any] ?? [:])
        switch parsed.state {
        case "failed":
            // Stay "on" with the block in place: only an explicit toggle
            // off lifts the kill switch after a fatal failure.
            if status.state != "failed" {
                ptLog(.error, "VPN layer failed: \(parsed.error ?? "")")
                error = (parsed.error ?? "The VPN layer failed.") + (killSwitch ? " Traffic stays blocked until you turn the VPN layer off." : "")
            }
            status = parsed
        case "off":
            // Helper lost it (restart/crash); surface and reset. While we are
            // still fetching a profile the helper hasn't heard of it yet.
            guard !reply.isEmpty, status.state != "starting" else { return }
            isWanted = false
            error = "The VPN layer was stopped by the helper."
            status = VPNStatus()
        default:
            if parsed.isConnected, !status.isConnected {
                ptLog(.info, "VPN layer connected on \(parsed.interface ?? "?") over \(parsed.underlay ?? "?")")
            }
            status = parsed
        }
    }

    func shutdown() async {
        if let temporaryProfile { deleteProfile(temporaryProfile) }
        if isWanted { await helper.stopVPN() }
    }

    // MARK: Profiles

    private func persistProfiles() { VPNProfileStore.save(profiles) }

    func selectProfile(_ profile: VPNProfile) { activeProfileID = profile.id.uuidString }

    func addProfile(_ profile: VPNProfile, config: String, username: String = "", password: String = "") {
        VPNProfileStore.setConfig(config, for: profile)
        if !username.isEmpty || !password.isEmpty { VPNProfileStore.setCredentials(username: username, password: password, for: profile) }
        profiles.append(profile)
        persistProfiles()
        if profiles.count == 1 || activeProfile == nil { activeProfileID = profile.id.uuidString }
    }

    func updateProfile(_ profile: VPNProfile) {
        guard let i = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        profiles[i] = profile
        persistProfiles()
    }

    @discardableResult
    func setCredentials(username: String, password: String, for profile: VPNProfile) -> Bool {
        let ok = VPNProfileStore.setCredentials(username: username, password: password, for: profile)
        objectWillChange.send()
        return ok
    }

    func deleteProfile(_ profile: VPNProfile) {
        if isWanted, activeProfile?.id == profile.id { set(false) }
        VPNProfileStore.deleteSecrets(for: profile)
        profiles.removeAll { $0.id == profile.id }
        persistProfiles()
        if activeProfileID == profile.id.uuidString { activeProfileID = profiles.first?.id.uuidString ?? "" }
    }

    func importProfile(from url: URL) throws {
        let text = try String(contentsOf: url, encoding: .utf8)
        let profile = try VPNProfileStore.importProfile(named: url.lastPathComponent, text: text)
        addProfile(profile, config: text)
        ptLog(.info, "Imported VPN profile \(profile.name) (\(profile.engine.label))")
    }

    func renameProfile(_ profile: VPNProfile, to name: String) {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        var updated = profile; updated.name = name
        updateProfile(updated)
    }

    // MARK: NordVPN

    private static func autoName(_ server: NordVPN.Server) -> String {
        "NordVPN · \(server.hostname.split(separator: ".").first ?? "server")"
    }

    /// Creates (or refreshes) a NordVPN profile from Nord's recommended server.
    func addNordProfile(username: String, password: String, countryID: Int?, countryName: String?, cityID: Int? = nil, cityName: String? = nil, tcp: Bool) async throws {
        let server = try await NordVPN.recommend(countryID: countryID, cityID: cityID, tcp: tcp)
        let text = try await NordVPN.profileText(for: server, tcp: tcp)
        var profile = VPNProfile(name: Self.autoName(server), engine: .openvpn, source: .nordvpn)
        profile.server = server.hostname
        profile.location = server.locationText
        profile.nordProtocol = tcp ? "tcp" : "udp"
        profile.nordCountryID = countryID
        profile.nordCountryName = countryName
        profile.nordCityID = cityID
        profile.nordCityName = cityName
        profile.needsCredentials = true
        addProfile(profile, config: text, username: username, password: password)
        activeProfileID = profile.id.uuidString
        ptLog(.info, "Added NordVPN profile \(server.hostname) (\(server.locationText), load \(server.load)%)")
    }

    /// Edit a NordVPN profile's area/protocol in place: fetches the matching
    /// server and, if this profile is live, restarts the VPN on it.
    func updateNordProfile(_ profile: VPNProfile, countryID: Int?, countryName: String?, cityID: Int?, cityName: String?, tcp: Bool, name: String?) async throws {
        let server = try await NordVPN.recommend(countryID: countryID, cityID: cityID, tcp: tcp)
        let text = try await NordVPN.profileText(for: server, tcp: tcp)
        var updated = profile
        updated.nordCountryID = countryID; updated.nordCountryName = countryName
        updated.nordCityID = cityID; updated.nordCityName = cityName
        updated.nordProtocol = tcp ? "tcp" : "udp"
        updated.server = server.hostname
        updated.location = server.locationText
        if let name, !name.isEmpty, name != profile.name {
            updated.name = name
        } else if profile.name.hasPrefix("NordVPN · ") {
            updated.name = Self.autoName(server)
        }
        VPNProfileStore.setConfig(text, for: updated)
        updateProfile(updated)
        ptLog(.info, "NordVPN profile updated: \(server.hostname) (\(server.locationText), load \(server.load)%)")
        if isWanted, activeProfile?.id == profile.id { set(false); set(true) }
    }

    func refreshNordServer(_ profile: VPNProfile) async throws {
        let tcp = profile.nordProtocol == "tcp"
        let server = try await NordVPN.recommend(countryID: profile.nordCountryID, cityID: profile.nordCityID, tcp: tcp)
        let text = try await NordVPN.profileText(for: server, tcp: tcp)
        var updated = profile
        updated.name = Self.autoName(server)
        updated.server = server.hostname
        updated.location = server.locationText
        VPNProfileStore.setConfig(text, for: updated)
        updateProfile(updated)
        ptLog(.info, "NordVPN profile now uses \(server.hostname) (\(server.locationText), load \(server.load)%)")
        if isWanted, activeProfile?.id == profile.id {
            isWanted = false
            Task { await helper.stopVPN(); set(true) }
        }
    }

    // MARK: Diagnostics and previews

    /// Imports `path` as a temporary profile and turns the layer on with it.
    func runDiagnosticProfile(path: String, username: String?, password: String?) {
        do {
            try importProfile(from: URL(fileURLWithPath: path))
            guard let p = profiles.last else { return }
            temporaryProfile = p
            activeProfileID = p.id.uuidString
            if let username, let password { setCredentials(username: username, password: password, for: p) }
            ptLog(.info, "DIAG: VPN test profile \(p.name); turning VPN layer on")
            set(true)
        } catch { ptLog(.error, "DIAG: \(error.localizedDescription)") }
    }

    func debugApply(state: String, underlay: String) {
        isWanted = true
        var v = VPNStatus(state: state, name: "NordVPN · us9591", engine: "openvpn")
        v.interface = "utun9"; v.underlay = underlay; v.since = Date().addingTimeInterval(-612)
        status = v
    }
}

/// The helper's view of the VPN layer, as reported by `getStatus`.
struct VPNStatus: Equatable {
    var state = "off"
    var name = ""
    var engine = ""
    var interface: String?
    var since: Date?
    var rx: Int64 = 0
    var tx: Int64 = 0
    var error: String?
    var underlay: String?
    var handshakeAge: Int?
    var dns: [String] = []
    var endpoint: String?

    init(state: String = "off", name: String = "", engine: String = "") {
        self.state = state; self.name = name; self.engine = engine
    }

    init(from dict: [String: Any]) {
        state = dict[VPNStatusKey.state] as? String ?? "off"
        name = dict[VPNStatusKey.name] as? String ?? ""
        engine = dict[VPNStatusKey.engine] as? String ?? ""
        interface = dict[VPNStatusKey.interface] as? String
        if let t = dict[VPNStatusKey.since] as? Double { since = Date(timeIntervalSince1970: t) }
        rx = Int64(dict[VPNStatusKey.rxBytes] as? Int ?? 0)
        tx = Int64(dict[VPNStatusKey.txBytes] as? Int ?? 0)
        error = dict[VPNStatusKey.error] as? String
        underlay = dict[VPNStatusKey.underlay] as? String
        handshakeAge = dict[VPNStatusKey.handshakeAge] as? Int
        dns = dict[VPNStatusKey.dns] as? [String] ?? []
        endpoint = dict[VPNStatusKey.endpoint] as? String
    }

    var isConnected: Bool { state == "connected" }
    var isBusy: Bool { state == "starting" || state == "reconnecting" || state == "blocked" }
    var engineLabel: String { engine == "wireguard" ? "WireGuard" : engine == "openvpn" ? "OpenVPN" : engine }
    var duration: TimeInterval? { since.map { Date().timeIntervalSince($0) } }
}
