import ActivityKit
import Foundation
import WidgetKit
import PassthroughCore

/// Keeps the system surfaces in step with what the app sees: the Step away
/// Live Activity (started by Step away, ended when Keep awake goes off or you
/// end it) and the widget's snapshot. Only the app can reach the Mac, so both
/// are as of its last look; the awake time counts down on its own until
/// `MacSnapshot.staleAfter`, then they say when they last heard.
@MainActor
final class MacActivityController {
    static let shared = MacActivityController()

    /// What the app sees of the selected Mac.
    struct Seen {
        var macID: String?
        var macName: String
        /// False once the Mac stopped answering; `state` is then as it last said.
        var reachable: Bool
        var lastHeard: Date?
        var state: MacState?
        var sessions: [ShellSessionInfo]
    }

    /// Step away asked for Keep awake: a state still saying it's off doesn't
    /// end the activity until it turns on or this passes.
    static let awakeGrace: TimeInterval = 15

    private var lastSnapshot = MacSnapshot.load()
    private var awaitingAwakeUntil: Date?
    private var lastSeen: Seen?

    private var activity: Activity<MacActivityAttributes>? { Activity<MacActivityAttributes>.activities.first }

    private init() { MacSnapshot.removeLegacy() }

    /// Step away: start the Live Activity (or refresh the one running). Not
    /// without the Mac's state: there'd be nothing true to show.
    func stepAway(_ seen: Seen) {
        guard seen.reachable, let state = seen.state else { return }
        lastSeen = seen
        awaitingAwakeUntil = state.awake == true ? nil : .now + Self.awakeGrace
        let content = ActivityContent(state: Self.content(seen), staleDate: Self.stale(state))
        if let activity {
            Task { await activity.update(content) }
        } else if ActivityAuthorizationInfo().areActivitiesEnabled {
            do {
                _ = try Activity.request(attributes: MacActivityAttributes(macName: seen.macName, startedAt: .now), content: content)
            } catch {
                PassthroughLog.shared.log(.warning, "Live Activity could not start: \(error.localizedDescription)")
            }
        }
        // Look again once the grace is over, in case Keep awake never came on.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.awakeGrace + 1))
            guard let self, let seen = self.lastSeen else { return }
            self.refresh(seen)
        }
    }

    /// Something the app sees changed: update the Live Activity, or end it
    /// once Keep awake is off (back at the desk) or the Mac's state is gone,
    /// and refresh the widget.
    func refresh(_ seen: Seen) {
        lastSeen = seen
        if seen.state?.awake == true { awaitingAwakeUntil = nil }
        if let activity { update(activity, seen) }
        writeSnapshot(seen)
    }

    private func update(_ activity: Activity<MacActivityAttributes>, _ seen: Seen) {
        guard let state = seen.state else {
            Task { await activity.end(nil, dismissalPolicy: .immediate) }
            return
        }
        guard seen.reachable else {
            // As it last said, marked as such; the stale date stays.
            var last = activity.content.state
            guard last.reachable else { return }
            last.reachable = false
            let content = ActivityContent(state: last, staleDate: activity.content.staleDate)
            Task { await activity.update(content) }
            return
        }
        if state.awake != true {
            if let until = awaitingAwakeUntil, until > .now { return }
            awaitingAwakeUntil = nil
            let final = ActivityContent(state: Self.content(seen), staleDate: nil)
            Task { await activity.end(final, dismissalPolicy: .immediate) }
            return
        }
        let content = ActivityContent(state: Self.content(seen), staleDate: Self.stale(state))
        Task { await activity.update(content) }
    }

    /// The Mac was forgotten, or nothing is set up: no stale Mac on the Lock Screen or Home Screen.
    func clear() {
        if let activity { Task { await activity.end(nil, dismissalPolicy: .immediate) } }
        awaitingAwakeUntil = nil
        lastSeen = nil
        MacSnapshot.clear()
        lastSnapshot = nil
        WidgetCenter.shared.reloadTimelines(ofKind: MacSnapshot.widgetKind)
    }

    private func writeSnapshot(_ seen: Seen) {
        let state = seen.state
        var snapshot = MacSnapshot(
            macID: seen.macID, macName: seen.macName, reachable: seen.reachable, awake: state?.awake == true,
            awakeUntil: Self.until(state), battery: state?.battery, charging: state?.charging == true,
            vpnOn: state?.vpnUp == true, runningShells: seen.sessions.filter(\.running).count,
            waiting: seen.sessions.filter(\.isAsking).count,
            updatedAt: seen.reachable ? .now : seen.lastHeard ?? .now)
        // Out of reach: keep what this Mac last said, marked as such.
        if !seen.reachable, var previous = lastSnapshot, previous.macID == seen.macID {
            previous.reachable = false
            snapshot = previous
        }
        if let previous = lastSnapshot, Self.looksSame(previous, snapshot) { return }
        lastSnapshot = snapshot
        snapshot.save()
        WidgetCenter.shared.reloadTimelines(ofKind: MacSnapshot.widgetKind)
    }

    /// What the widget shows is the same: don't reload it for a few minutes'
    /// drift in the time or the estimate.
    private static func looksSame(_ a: MacSnapshot, _ b: MacSnapshot) -> Bool {
        var a = a
        if abs(a.updatedAt.timeIntervalSince(b.updatedAt)) < 600 { a.updatedAt = b.updatedAt }
        if let x = a.awakeUntil, let y = b.awakeUntil, abs(x.timeIntervalSince(y)) < 600 { a.awakeUntil = y }
        return a == b
    }

    private static func content(_ seen: Seen) -> MacActivityAttributes.ContentState {
        MacActivityAttributes.ContentState(
            awakeUntil: until(seen.state), charging: seen.state?.charging == true, vpnOn: seen.state?.vpnUp == true,
            runningShells: seen.sessions.filter(\.running).count,
            waitingSession: seen.sessions.first(where: \.isAsking)?.id, updatedAt: .now)
    }

    private static func until(_ state: MacState?) -> Date? {
        guard state?.awake == true, state?.charging != true, let minutes = state?.minutesLeft else { return nil }
        return .now + TimeInterval(minutes * 60)
    }

    /// Past the awake time, or `staleAfter` without word, the system shows it as out of date.
    private static func stale(_ state: MacState) -> Date {
        min(until(state) ?? .distantFuture, .now + MacSnapshot.staleAfter)
    }
}
