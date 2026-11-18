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
    /// Installed, but an older build than this app carries.
    case outdated
    /// Installed, but macOS doesn't have the device (yet: it loads drivers when its audio restarts).
    case notLoaded

    static let installedPath = "/Library/Audio/Plug-Ins/HAL/PassthroughMicrophone.driver"
    private static let executable = "Contents/MacOS/PassthroughMicrophone"

    static var current: MicrophoneDriverStatus {
        let installed = URL(fileURLWithPath: installedPath).appendingPathComponent(executable)
        guard FileManager.default.fileExists(atPath: installed.path) else { return .notInstalled }
        if let bundled = Bundle.main.builtInPlugInsURL?.appendingPathComponent("PassthroughMicrophone.driver").appendingPathComponent(executable),
           let ours = try? Data(contentsOf: bundled), let theirs = try? Data(contentsOf: installed), ours != theirs {
            return .outdated
        }
        return VirtualMicrophone.isInstalled ? .ready : .notLoaded
    }
}
