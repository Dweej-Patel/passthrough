import Foundation
import RemoteDesktop

/// A PC's screen through its Remote Desktop, behind a developer switch until
/// every state says what it is: on only in DEBUG builds, only with the engine
/// built in, and only when `PTWindowsScreen` is set (a launch argument
/// `-PTWindowsScreen YES`, or `defaults` on a development device). A release
/// build never has it.
enum PCScreen {
    static let switchKey = "PTWindowsScreen"

    static var isOn: Bool {
        #if DEBUG
        return RemoteDesktop.isAvailable && RemoteDesktop.isEnabled && UserDefaults.standard.bool(forKey: switchKey)
        #else
        return false
        #endif
    }
}
