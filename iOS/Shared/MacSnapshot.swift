import Foundation
import ActivityKit

/// The Mac as the app last saw it, for the widget: written by the app (it
/// alone can reach the Mac), read by the widget extension. Nothing secret:
/// no session output, no keys.
struct MacSnapshot: Codable, Equatable {
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
    var updatedAt: Date

    private static let key = "macSnapshot"

    static func load(from defaults: UserDefaults?) -> MacSnapshot? {
        defaults?.data(forKey: key).flatMap { try? JSONDecoder().decode(MacSnapshot.self, from: $0) }
    }

    func save(to defaults: UserDefaults?) {
        if let data = try? JSONEncoder().encode(self) { defaults?.set(data, forKey: Self.key) }
    }
}

/// The Live Activity a Step away starts: the Mac's awake time counts down on
/// its own; shells and "needs you" are as of the app's last look. Only the
/// session's title is shown (on the Lock Screen too), never its output.
struct MacActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var awakeUntil: Date?
        var charging: Bool
        var vpnOn: Bool
        var runningShells: Int
        /// The title of a session waiting on a question, and its ID for Open.
        var waitingTitle: String?
        var waitingSession: String?
        var updatedAt: Date
    }

    var macName: String
    var startedAt: Date
}
