import Foundation
import PassthroughCore
import RemoteDesktop

/// A PC's screen through its Remote Desktop, behind a developer switch until
/// every state says what it is: on only in DEBUG builds, only with the engine
/// built in, and only when `PTWindowsScreen` is on. A launch argument
/// (`-PTWindowsScreen YES` or `NO`, which `./passthrough iphone install
/// --pc-screen` passes) sets it and it's saved, so the app opened later from the
/// home screen keeps it. A release build never has it.
enum PCScreen {
    static let switchKey = "PTWindowsScreen"

    static var isOn: Bool {
        #if DEBUG
        return RemoteDesktop.isAvailable && RemoteDesktop.isEnabled && switchedOn
        #else
        return false
        #endif
    }

    /// What a screen row or a refused view says. In a build that can show a
    /// PC's screen but has the switch off, that, not "not in this version".
    static func copy(_ state: HostScreenState, _ words: HostWords) -> String? {
        #if DEBUG
        if state == .notInThisVersion, words.kind == .windows, RemoteDesktop.isAvailable, RemoteDesktop.isEnabled, !switchedOn {
            return "\(words.name)'s screen is switched off on this \(words.device). Turn it on with ./passthrough iphone install --pc-screen. Its shell works."
        }
        #endif
        return HostCopy.screen(state, words)
    }

    #if DEBUG
    /// The switch as last set, read once per launch: a launch argument is saved first.
    private static let switchedOn: Bool = {
        let defaults = UserDefaults.standard
        if let given = defaults.volatileDomain(forName: UserDefaults.argumentDomain)[switchKey] {
            let on = (given as? Bool) ?? (given as? NSNumber)?.boolValue ?? ((given as? String).map { ($0 as NSString).boolValue } ?? false)
            defaults.set(on, forKey: switchKey)
        }
        return defaults.bool(forKey: switchKey)
    }()
    #endif
}
