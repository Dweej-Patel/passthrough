import UIKit

/// The app is portrait-only except while a view (the Mac's screen) asks for
/// more: the Info.plist lists landscape so that view can turn, and this
/// delegate narrows every other moment back to portrait.
final class AppOrientation: NSObject, UIApplicationDelegate {
    @MainActor static var allowed = UIInterfaceOrientationMask.portrait {
        didSet { apply() }
    }

    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        Self.allowed
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
            if allowed == .portrait {
                scene.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait))
            }
        }
    }
}
