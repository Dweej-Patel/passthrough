import Foundation
import PassthroughCore
import ShellHost
import SystemConfiguration

/// Notices to phones through Apple's push service, for the app: the phones
/// that asked for them, the push key they are signed with (Settings ›
/// Remote Shell › Notifications), and the rules (`PushNotifier`).
///
/// Without a key nothing is sent; phones that asked are kept, and hear
/// "not set up" until there is one.
@MainActor
final class PhoneNotifications: ObservableObject {
    /// Phone IDs that asked for notices.
    @Published private(set) var registeredPhones: Set<String> = []
    /// The Team ID and Key ID as saved; the key itself stays in the Keychain.
    @Published private(set) var teamID: String
    @Published private(set) var keyID: String
    @Published private(set) var hasKey: Bool
    /// Why notices can't go out, or why the last one didn't; nil when fine.
    @Published private(set) var problem: String?
    @Published private(set) var testResult: String?

    let registry = PushRegistry(secrets: KeychainSecretStore())
    private let notifier = PushNotifier()
    private let client = Locked<APNsClient?>(nil)

    static let teamKey = "PTPushTeamID", keyIDKey = "PTPushKeyID", keyAccount = "apns.key"

    var isSetUp: Bool { client.get() != nil }

    init() {
        teamID = UserDefaults.standard.string(forKey: Self.teamKey) ?? ""
        keyID = UserDefaults.standard.string(forKey: Self.keyIDKey) ?? ""
        hasKey = Keychain.read(Self.keyAccount) != nil
        registeredPhones = Set(registry.all.keys)
        let client = self.client, registry = self.registry
        notifier.client = { client.get() }
        notifier.registrations = { registry.all }
        notifier.onTokenGone = { [weak self] phoneID in
            registry.remove(phoneID)
            Task { @MainActor in self?.registeredPhones = Set(registry.all.keys) }
        }
        notifier.onResult = { [weak self] problem in Task { @MainActor in self?.problem = problem } }
        rebuildClient()
    }

    /// Saves the push key's details and starts using them, or says what is wrong.
    func save(teamID: String, keyID: String, privateKey: String?) {
        let teamID = teamID.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let keyID = keyID.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let pem = privateKey ?? Keychain.read(Self.keyAccount) ?? ""
        if let problem = APNsCredentials(teamID: teamID, keyID: keyID, privateKey: pem).problem {
            self.problem = problem
            return
        }
        if let privateKey, !Keychain.write(privateKey, account: Self.keyAccount) {
            problem = "Could not store the key in the Keychain."
            return
        }
        UserDefaults.standard.set(teamID, forKey: Self.teamKey)
        UserDefaults.standard.set(keyID, forKey: Self.keyIDKey)
        self.teamID = teamID
        self.keyID = keyID
        hasKey = true
        problem = nil
        rebuildClient()
        ptLog(.info, "push: key set up")
    }

    /// Forgets the push key: no more notices until one is set up again.
    func removeKey() {
        Keychain.delete(Self.keyAccount)
        hasKey = false
        problem = nil
        testResult = nil
        rebuildClient()
        ptLog(.info, "push: key removed")
    }

    private func rebuildClient() {
        guard let pem = Keychain.read(Self.keyAccount) else { return client.set(nil) }
        let credentials = APNsCredentials(teamID: teamID, keyID: keyID, privateKey: pem)
        if let problem = credentials.problem {
            client.set(nil)
            self.problem = problem
        } else {
            client.set(APNsClient(credentials: credentials))
        }
    }

    // MARK: From the shell

    /// For the listeners: stores (or forgets) a phone's registration and says whether notices will go out.
    func registrationHandler() -> @Sendable (String, PushRegistration?) -> Bool {
        let registry = self.registry, client = self.client
        return { [weak self] phoneID, registration in
            registry.set(registration, for: phoneID)
            ptLog(.info, registration == nil ? "push: a phone stopped notices" : "push: a phone asked for notices")
            Task { @MainActor in self?.registeredPhones = Set(registry.all.keys) }
            return client.get() != nil
        }
    }

    /// The sessions changed: tell phones what calls for it.
    func sessionsChanged(_ sessions: [ShellSessionInfo], looking: Set<String>) {
        notifier.update(sessions, looking: looking, macName: Self.macName)
    }

    /// The phone lost shell access (or a pairing was forgotten): no more notices for it.
    func forget(_ phoneIDs: [String]) {
        for phoneID in phoneIDs { registry.remove(phoneID) }
        registeredPhones = Set(registry.all.keys)
    }

    /// Only phones that still have shell access keep their registration.
    func keep(only phoneIDs: Set<String>) {
        registry.keep(only: phoneIDs)
        registeredPhones = Set(registry.all.keys)
    }

    /// One notice to every phone that asked, to see it all works.
    func sendTest() {
        guard let client = client.get() else { testResult = "Set up a push key first."; return }
        let registrations = registry.all
        guard !registrations.isEmpty else { testResult = "No phone has asked for notices yet: turn them on in Passthrough on the iPhone."; return }
        testResult = "Sending…"
        let macName = Self.macName
        Task { [weak self] in
            var results: [String] = []
            for (_, registration) in registrations {
                guard let key = Data(base64Encoded: registration.key) else { continue }
                let notice = PushNotice(macName: macName, title: "Notifications work", body: "\(macName) can tell this iPhone when a shell needs you.",
                                        session: "", state: "test")
                guard let sealed = try? PushBox.seal(notice, key: key, macID: registration.mac) else { continue }
                let payload = PushNotifier.payload(sealed: sealed, macID: registration.mac, session: "test", timeSensitive: false)
                switch await client.send(payload, to: registration, collapseID: "test", timeSensitive: false) {
                case .sent: results.append("sent")
                case .tokenGone: results.append("a phone's registration no longer works")
                case .credentialsRefused(let reason): results.append("Apple refused the key (\(reason))")
                case .failed(let reason): results.append("not sent (\(reason))")
                }
            }
            let summary = Set(results).sorted().joined(separator: "; ")
            await MainActor.run { self?.testResult = summary.prefix(1).uppercased() + summary.dropFirst() + "." }
        }
    }

    /// The Mac's name as Sharing settings has it, read without a network lookup.
    static let macName: String = (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? "Mac"
}
