import ActivityKit
import Foundation
import WidgetKit
import PassthroughCore

/// Keeps the system surfaces in step with what the app sees: the Step away
/// Live Activity (started by Step away, ended when Keep awake goes off or you
/// end it) and the widget's snapshot. Only the app can reach the Mac, so both
/// are as of its last look; the awake time counts down on its own.
@MainActor
final class MacActivityController {
    static let shared = MacActivityController()
    private var lastSnapshot = MacSnapshot.load(from: UserDefaults(suiteName: PassthroughProtocol.appGroup))

    private var activity: Activity<MacActivityAttributes>? { Activity<MacActivityAttributes>.activities.first }

    /// Step away: start the Live Activity (or refresh the one running).
    func stepAway(macName: String, state: MacState?, sessions: [ShellSessionInfo]) {
        let content = ActivityContent(state: Self.content(state: state, sessions: sessions), staleDate: Self.stale(state))
        if let activity {
            Task { await activity.update(content) }
            return
        }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        do {
            _ = try Activity.request(attributes: MacActivityAttributes(macName: macName, startedAt: .now), content: content)
        } catch {
            PassthroughLog.shared.log(.warning, "Live Activity could not start: \(error.localizedDescription)")
        }
    }

    /// Something the app sees changed: update the Live Activity, or end it
    /// once Keep awake is off (back at the desk), and refresh the widget.
    func refresh(macName: String, reachable: Bool, state: MacState?, sessions: [ShellSessionInfo]) {
        if let activity, reachable, let state {
            if state.awake == false {
                let final = ActivityContent(state: Self.content(state: state, sessions: sessions), staleDate: nil)
                Task { await activity.end(final, dismissalPolicy: .immediate) }
            } else {
                let content = ActivityContent(state: Self.content(state: state, sessions: sessions), staleDate: Self.stale(state))
                Task { await activity.update(content) }
            }
        }
        writeSnapshot(macName: macName, reachable: reachable, state: state, sessions: sessions)
    }

    /// The Mac was forgotten, or nothing is set up: no stale Mac on the Lock Screen or Home Screen.
    func clear() {
        if let activity { Task { await activity.end(nil, dismissalPolicy: .immediate) } }
        UserDefaults(suiteName: PassthroughProtocol.appGroup)?.removeObject(forKey: "macSnapshot")
        lastSnapshot = nil
        WidgetCenter.shared.reloadTimelines(ofKind: "MacWidget")
    }

    private func writeSnapshot(macName: String, reachable: Bool, state: MacState?, sessions: [ShellSessionInfo]) {
        var snapshot = MacSnapshot(
            macName: macName, reachable: reachable, awake: state?.awake == true, awakeUntil: Self.until(state),
            battery: state?.battery, charging: state?.charging == true, vpnOn: state?.vpnUp == true,
            runningShells: sessions.filter(\.running).count, waiting: sessions.filter { $0.waiting != nil }.count,
            updatedAt: .now)
        // Out of reach: keep what it last said, marked as such.
        if !reachable, var previous = lastSnapshot {
            previous.reachable = false
            snapshot = previous
        }
        if let previous = lastSnapshot, Self.looksSame(previous, snapshot) { return }
        lastSnapshot = snapshot
        snapshot.save(to: UserDefaults(suiteName: PassthroughProtocol.appGroup))
        WidgetCenter.shared.reloadTimelines(ofKind: "MacWidget")
    }

    /// What the widget shows is the same: don't reload it for a new timestamp or a few minutes' drift in the estimate.
    private static func looksSame(_ a: MacSnapshot, _ b: MacSnapshot) -> Bool {
        var a = a
        a.updatedAt = b.updatedAt
        if let x = a.awakeUntil, let y = b.awakeUntil, abs(x.timeIntervalSince(y)) < 600 { a.awakeUntil = y }
        return a == b
    }

    private static func content(state: MacState?, sessions: [ShellSessionInfo]) -> MacActivityAttributes.ContentState {
        let waiting = sessions.first { $0.running && $0.waiting != nil }
        return MacActivityAttributes.ContentState(
            awakeUntil: until(state), charging: state?.charging == true, vpnOn: state?.vpnUp == true,
            runningShells: sessions.filter(\.running).count,
            waitingTitle: waiting?.title, waitingSession: waiting?.id, updatedAt: .now)
    }

    private static func until(_ state: MacState?) -> Date? {
        guard state?.awake == true, state?.charging != true, let minutes = state?.minutesLeft else { return nil }
        return .now + TimeInterval(minutes * 60)
    }

    /// Past the awake time (or an hour without word), the system shows it as out of date.
    private static func stale(_ state: MacState?) -> Date { until(state) ?? .now + 3600 }
}
