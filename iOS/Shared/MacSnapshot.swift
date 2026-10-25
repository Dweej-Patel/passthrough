import Foundation
import ActivityKit
import PassthroughCore

/// The Mac as the app last saw it, for the widget: written by the app (it
/// alone can reach the Mac), read by the widget extension. Nothing secret:
/// no session output, no keys. It lives in an app group of its own, so the
/// widget isn't in the group whose Keychain holds the pairing secrets.
struct MacSnapshot: Codable, Equatable {
    /// Which Mac it is, so another Mac's last state is never shown as this one's.
    var macID: String?
    var macName: String
    var reachable: Bool
    var awake: Bool
    /// When Keep awake's battery limit will be reached, at the rate then.
    var awakeUntil: Date?
    var battery: Double?
    var charging: Bool
    var vpnOn: Bool
    var runningShells: Int
    /// Sessions waiting on a question.
    var waiting: Int
    /// When the Mac last answered with this.
    var updatedAt: Date

    /// The widget's own app group: the app is in it and the main one, the widget in this one only.
    static let appGroup = PassthroughProtocol.appGroup + ".widget"
    /// The Home Screen widget's kind, for reloading it.
    static let widgetKind = "MacWidget"
    /// Past this without word from the Mac, the widget and Live Activity say when they last heard.
    static let staleAfter: TimeInterval = 3600

    private static let key = "macSnapshot"
    private static var defaults: UserDefaults? { UserDefaults(suiteName: appGroup) }

    static func load() -> MacSnapshot? {
        defaults?.data(forKey: key).flatMap { try? JSONDecoder().decode(MacSnapshot.self, from: $0) }
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) { Self.defaults?.set(data, forKey: Self.key) }
    }

    static func clear() { defaults?.removeObject(forKey: key) }

    /// The copy written to the main group before the widget had its own; the app drops it.
    static func removeLegacy() { UserDefaults(suiteName: PassthroughProtocol.appGroup)?.removeObject(forKey: key) }
}

/// The Live Activity turning Keep awake on from this phone starts: the Mac's awake time counts down on
/// its own; shells and "needs you" are as of the app's last look. No session
/// title or output: it shows on the Lock Screen.
struct MacActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var awakeUntil: Date?
        var charging: Bool
        var vpnOn: Bool
        var runningShells: Int
        /// A session waiting on a question, for Open.
        var waitingSession: String?
        /// When the Mac last answered with this.
        var updatedAt: Date
        /// The app can't reach the Mac now: this is as it last said.
        var reachable = true
    }

    var macName: String
    var startedAt: Date
}
