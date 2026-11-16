import UIKit

/// What this device is called in the app's words: the same app runs on iPhone
/// and iPad, so text says "this iPad" on an iPad.
enum ThisDevice {
    static let isPad = UIDevice.current.userInterfaceIdiom == .pad
    /// "iPhone" or "iPad".
    static let name = isPad ? "iPad" : "iPhone"
    /// The SF Symbol for this device.
    static let symbol = isPad ? "ipad" : "iphone"
}
