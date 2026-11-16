import UIKit

/// On iPhone the app is portrait-only except while a view (the Mac's screen)
/// asks for more: the Info.plist lists landscape so that view can turn, and
/// this delegate narrows every other moment back to portrait. On iPad every
/// orientation is always allowed (Split View and Stage Manager need it).
final class AppOrientation: NSObject, UIApplicationDelegate {
    /// What the app allows when no view asks for more.
    @MainActor static let standard: UIInterfaceOrientationMask =
        UIDevice.current.userInterfaceIdiom == .pad ? .all : .portrait

    @MainActor static var allowed = standard {
        didSet { apply() }
    }

    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        Self.allowed
    }

    // Notices from Macs (`PushRegistrar`): set up before launch ends, so a tap that launched the app is handled.
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        MainActor.assumeIsolated { PushRegistrar.shared.start() }
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        MainActor.assumeIsolated { PushRegistrar.shared.registered(deviceToken) }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        MainActor.assumeIsolated { PushRegistrar.shared.registrationFailed(error) }
    }

    /// Re-asks the windows, and turns the phone back to portrait when that's all that's left.
    @MainActor private static func apply() {
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            for window in scene.windows {
                var top = window.rootViewController
                while let presented = top?.presentedViewController { top = presented }
                top?.setNeedsUpdateOfSupportedInterfaceOrientations()
                window.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
            }
            if allowed == .portrait, standard == .portrait {
                scene.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait))
            }
        }
    }
}
