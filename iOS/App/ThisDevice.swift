import UIKit
import PassthroughCore

/// What this device is called in the app's words: the same app runs on iPhone
/// and iPad, so text says "this iPad" on an iPad.
enum ThisDevice {
    static let isPad = UIDevice.current.userInterfaceIdiom == .pad
    /// "iPhone" or "iPad".
    static let name = isPad ? "iPad" : "iPhone"
    /// The SF Symbol for this device.
    static let symbol = isPad ? "ipad" : "iphone"

    /// The name chosen in Settings (what other devices see), else "iPhone" or "iPad".
    static var displayName: String {
        let chosen = AppModel.groupDefaults.string(forKey: SharedKeys.deviceName)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return chosen.isEmpty ? name : String(chosen.prefix(64))
    }
}
