import Foundation
import UIKit
import UserNotifications
import PassthroughCore

/// Notices from Macs through Apple's push service, on the phone: whether
/// they're on, the device token, the key each Mac seals them with
/// (`PushKeys`), and what a tap on one opens.
///
/// Every connection to a Mac says what this phone wants (`registration`),
/// so turning notices on or off reaches each Mac the next time the app
/// talks to it.
@MainActor
final class PushRegistrar: NSObject, ObservableObject {
    static let shared = PushRegistrar()

    static let enabledKey = "PTPushEnabled"
    @Published private(set) var enabled = UserDefaults.standard.bool(forKey: PushRegistrar.enabledKey)
    /// The device token from APNs, as lowercase hex; nil until it arrives.
    @Published private(set) var token: String?
    /// iOS says no: notifications are off for Passthrough in Settings.
    @Published private(set) var denied = false

    private let secrets = PushKeys.store()

    /// At launch: taps are handled, and an enabled phone gets its token again (it can change).
    func start() {
        UNUserNotificationCenter.current().delegate = self
        guard enabled else { return }
        Task {
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            denied = settings.authorizationStatus == .denied
            UIApplication.shared.registerForRemoteNotifications()
        }
    }

    /// Asks iOS first when turning them on.
    func setEnabled(_ on: Bool) async {
        if on {
            let granted = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
            denied = !granted
            guard granted else { return save(false) }
            save(true)
            UIApplication.shared.registerForRemoteNotifications()
        } else {
            save(false)
        }
    }

    private func save(_ on: Bool) {
        enabled = on
        UserDefaults.standard.set(on, forKey: Self.enabledKey)
    }

    func registered(_ deviceToken: Data) {
        let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
        if hex != token { token = hex }
    }

    func registrationFailed(_ error: Error) {
        ptLog(.warning, "push: no device token (\(error.localizedDescription))")
    }

    /// What to ask `mac` for: notices sealed with its own key, or nil (none).
    func registration(for mac: String) -> PushRegistration? {
        guard enabled, !denied, let token, let topic = Bundle.main.bundleIdentifier,
              let key = PushKeys.keyCreating(for: mac, in: secrets) else { return nil }
        return PushRegistration(token: token, environment: Self.environment, topic: topic, key: key.base64EncodedString(), mac: mac)
    }

    /// Development builds (from Xcode) get tokens for APNs' sandbox.
    static var environment: String {
        #if DEBUG
        PushRegistration.sandbox
        #else
        PushRegistration.production
        #endif
    }
}

extension PushRegistrar: UNUserNotificationCenterDelegate {
    /// With the app open, a notice still shows (it is about a session not on screen: the Mac doesn't send one otherwise).
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    /// A tap opens the session it is about, on its Mac.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        guard let mac = info["mac"] as? String else { return }
        let session = (info["session"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        await MainActor.run {
            PendingLinks.shared.open(session.map { AppLink.session($0, mac: mac) } ?? AppLink.mac(mac))
        }
    }
}
