import Foundation
import ScreenHost

/// Where the "Passthrough Microphone" audio driver stands on this Mac. The root
/// helper installs it from this app (`HelperClient.setMicrophoneDriver`); with it
/// a phone viewing the screen can be this Mac's microphone.
enum MicrophoneDriverStatus: Equatable {
    /// Not in /Library/Audio/Plug-Ins/HAL.
    case notInstalled
    /// Installed, and macOS has the device.
    case ready
    /// Installed, but another version of the driver than this app carries.
    case outdated
    /// Installed, but macOS doesn't have the device (yet: it loads drivers when its audio restarts).
    case notLoaded

    static let installedPath = "/Library/Audio/Plug-Ins/HAL/PassthroughMicrophone.driver"
    private static let executable = "Contents/MacOS/PassthroughMicrophone"

    static var current: MicrophoneDriverStatus {
        let installed = URL(fileURLWithPath: installedPath)
        guard FileManager.default.fileExists(atPath: installed.appendingPathComponent(executable).path) else { return .notInstalled }
        if let bundled = Bundle.main.builtInPlugInsURL?.appendingPathComponent("PassthroughMicrophone.driver"),
           isOutdated(installed: version(of: installed), bundled: version(of: bundled)) {
            return .outdated
        }
        return VirtualMicrophone.isInstalled ? .ready : .notLoaded
    }

    /// The driver's own version (its Info.plist's CFBundleVersion), which changes only when its source does
    /// (MicrophoneDriverVersionTests holds the two together).
    static func version(of driver: URL) -> String? {
        guard let data = try? Data(contentsOf: driver.appendingPathComponent("Contents/Info.plist")),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
        return plist["CFBundleVersion"] as? String
    }

    /// By version, not by the file's bytes: the same source builds to different bytes in every build of the app (the
    /// build's place and configuration are in them), which made every newly installed app ask for an update though
    /// the driver was the same. An installed driver whose version can't be read is replaced; without the app's own
    /// version there is nothing to compare, so nothing is asked.
    static func isOutdated(installed: String?, bundled: String?) -> Bool {
        guard let bundled else { return false }
        return installed != bundled
    }
}
