import Foundation
import PassthroughCore
import ShellHost
import SystemConfiguration

/// Notices to phones through Apple's push service, for the app: the phones
/// that asked for them, the push key they are signed with, and the rules
/// (`PushNotifier`).
///
/// The key comes from the build: Config/Signing.xcconfig names a `.p8`
/// (`PASSTHROUGH_PUSH_KEY_FILE`), which the build copies into the app as
/// `AuthKey_<Key ID>.p8`, signed by the team in `PassthroughPushTeamID`. Built
/// without one, nothing is sent; phones that asked are kept and hear "not
/// set up", and their widget and Live Activity work as before.
@MainActor
final class PhoneNotifications: ObservableObject {
    /// Phone IDs that asked for notices.
    @Published private(set) var registeredPhones: Set<String> = []
    /// Why notices can't go out, or why the last one didn't; nil when fine.
    @Published private(set) var problem: String?
    @Published private(set) var testResult: String?

    let registry = PushRegistry(secrets: KeychainSecretStore())
    private let notifier = PushNotifier()
    private let client = Locked<APNsClient?>(nil)

    /// This build carries a push key (it may still be unusable: see `problem`).
    let isBuiltWithKey: Bool
    var isSetUp: Bool { client.get() != nil }

    init() {
        let bundled = Self.bundledCredentials()
        isBuiltWithKey = bundled != nil
        registeredPhones = Set(registry.all.keys)
        let client = self.client, registry = self.registry
        notifier.client = { client.get() }
        notifier.registrations = { registry.all }
        notifier.onTokenGone = { [weak self] phoneID in
            registry.remove(phoneID)
            Task { @MainActor in self?.registeredPhones = Set(registry.all.keys) }
        }
        notifier.onResult = { [weak self] problem in Task { @MainActor in self?.problem = problem } }
        if let bundled {
            if let problem = bundled.problem {
                self.problem = "The push key built into this app can't be used: \(problem) Fix it in Config/Signing.xcconfig (PASSTHROUGH_PUSH_KEY_FILE, PASSTHROUGH_PUSH_TEAM_ID) and rebuild."
                ptLog(.error, "push: the bundled key can't be used (\(problem))")
            } else {
                client.set(APNsClient(credentials: bundled))
                ptLog(.info, "push: key \(bundled.keyID) from the build")
            }
        }
    }

    /// The key the build put in the app, with its team; nil when built without one.
    static func bundledCredentials(_ bundle: Bundle = .main) -> APNsCredentials? {
        guard let resources = bundle.resourceURL,
              let names = try? FileManager.default.contentsOfDirectory(atPath: resources.path),
              let name = names.sorted().first(where: { $0.hasPrefix("AuthKey_") && $0.hasSuffix(".p8") }) else { return nil }
        let keyID = String(name.dropFirst("AuthKey_".count).dropLast(".p8".count))
        let teamID = (bundle.object(forInfoDictionaryKey: "PassthroughPushTeamID") as? String ?? "").uppercased()
        let pem = (try? String(contentsOf: resources.appendingPathComponent(name), encoding: .utf8)) ?? ""
        return APNsCredentials(teamID: teamID, keyID: keyID, privateKey: pem)
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

    /// For the session manager (`onStatusChange`): each change, as it happens, goes to the rules.
    func statusHandler() -> @Sendable (ShellSessionInfo, Bool) -> Void {
        let notifier = self.notifier, macName = Self.macName
        return { session, looking in notifier.observe(session, looking: looking, macName: macName) }
    }

    /// The phone lost shell access (or a pairing was forgotten): no more notices for it.
    func forget(_ phoneIDs: [String]) {
        for phoneID in phoneIDs { registry.remove(phoneID) }
        registeredPhones = Set(registry.all.keys)
    }

    /// One notice to every phone that asked, to see it all works.
    func sendTest() {
        guard let client = client.get() else { testResult = "This build has no usable push key."; return }
        let registrations = registry.all
        guard !registrations.isEmpty else { testResult = "No phone has asked for notices yet: turn them on in Passthrough on the iPhone."; return }
        testResult = "Sending…"
        let macName = Self.macName, notifier = self.notifier
        let notice = PushNotice(macName: macName, title: "Notifications work", body: "\(macName) can tell this iPhone when a shell needs you.",
                                session: "", state: "test")
        Task { [weak self] in
            var results: [String] = []
            for (phoneID, registration) in registrations {
                switch await notifier.deliver(notice, timeSensitive: false, to: registration, phoneID: phoneID, client: client) {
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
