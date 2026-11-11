import ActivityKit
import Foundation
import WidgetKit
import PassthroughCore

/// Keeps the system surfaces in step with what the app sees: the Keep awake
/// Live Activity (started when this phone turns Keep awake on, ended when it
/// goes off or you end it) and the widget's snapshot. Only the app can reach the Mac, so both
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

    /// This phone just asked for Keep awake: a state still saying it's off
    /// doesn't end the activity until it turns on or this passes.
    static let awakeGrace: TimeInterval = 15

    private var lastSnapshot = MacSnapshot.load()
    private var awaitingAwakeUntil: Date?
    private var lastSeen: Seen?
    private var lastSelected: Seen?
    /// The Mac selected as of the last refresh, even while it is still connecting.
    private var selection: (id: String?, name: String)?

    private var activity: Activity<MacActivityAttributes>? { Activity<MacActivityAttributes>.activities.first { $0.activityState != .ended && !endedIDs.contains($0.id) } }
    /// Activities an end was asked for that hasn't landed yet.
    private var endedIDs: Set<String> = []
    private var announcedMac: String?
    /// Called with the activity's Mac ID when it changes (nil when none), so the app can keep watching it.
    var onActivityMacChange: ((String?) -> Void)? { didSet { announced(force: true) } }

    /// The Mac the running Live Activity belongs to (from its attributes, so it survives a relaunch).
    var activityMacID: String? { activity.flatMap(macID(of:)) }

    private static let adoptedKey = "PTActivityAdoptedMacs"
    /// Mac IDs given to activities an older build started (no ID in their attributes, which can't change):
    /// by activity ID, kept so a relaunch finds them again.
    private var adopted: [String: String] = UserDefaults.standard.dictionary(forKey: adoptedKey) as? [String: String] ?? [:] {
        didSet { UserDefaults.standard.set(adopted, forKey: Self.adoptedKey) }
    }

    private func macID(of activity: Activity<MacActivityAttributes>) -> String? {
        activity.attributes.macID ?? adopted[activity.id]
    }

    /// An activity from before activities carried their Mac belongs to the paired Mac with its name,
    /// else to the Mac selected now (the only one that build could have started it for).
    func adoptUntagged(selectedMacID: String?, paired: [(id: String, name: String)]) {
        let live = Set(Activity<MacActivityAttributes>.activities.map(\.id))
        if adopted.keys.contains(where: { !live.contains($0) }) { adopted = adopted.filter { live.contains($0.key) } }
        endedIDs.formIntersection(live)   // once the system has dropped one, it can't come back
        guard let activity, activity.attributes.macID == nil, adopted[activity.id] == nil,
              let mac = MacProfiles.adoptedMac(activityMacName: activity.attributes.macName, paired: paired,
                                               selected: selectedMacID) else { return }
        adopted[activity.id] = mac
        announced()
    }

    private func announced(force: Bool = false) {
        let id = activityMacID
        guard force || id != announcedMac else { return }
        announcedMac = id
        onActivityMacChange?(id)
    }

    private func end(_ activity: Activity<MacActivityAttributes>, _ content: ActivityContent<MacActivityAttributes.ContentState>?) {
        endedIDs.insert(activity.id)
        announced()
        Task { await activity.end(content, dismissalPolicy: .immediate) }
    }

    private init() { MacSnapshot.removeLegacy() }

    /// This phone turned Keep awake on (the switch, Control Center, a
    /// Shortcut): start the Live Activity (or refresh the one running). Not
    /// without the Mac's state: there'd be nothing true to show.
    func keepAwakeAsked(_ seen: Seen) {
        guard seen.reachable, let state = seen.state else { return }
        // Keep awake on another Mac than the running activity's: it moves there.
        if let running = activity, let id = macID(of: running), id != seen.macID {
            end(running, nil)
        }
        lastSeen = seen
        awaitingAwakeUntil = state.awake == true ? nil : .now + Self.awakeGrace
        let content = ActivityContent(state: Self.content(seen), staleDate: Self.stale(state))
        if let activity {
            Task { await activity.update(content) }
        } else if ActivityAuthorizationInfo().areActivitiesEnabled {
            do {
                _ = try Activity.request(attributes: MacActivityAttributes(macName: seen.macName, startedAt: .now, macID: seen.macID), content: content)
            } catch {
                PassthroughLog.shared.log(.warning, "Live Activity could not start: \(error.localizedDescription)")
            }
        }
        // Look again once the grace is over, in case Keep awake never came on.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.awakeGrace + 1))
            guard let self, let seen = self.lastSeen else { return }
            self.refresh(selected: nil, selection: self.selection, activity: seen)
        }
        announced()
    }

    /// Something the app sees changed: update the Live Activity from the Mac
    /// it belongs to (`activity`, nil until that Mac has said anything), or
    /// end it once Keep awake is off there or its state is gone, and refresh
    /// the widget: the activity's Mac while one runs, else the selected Mac
    /// (`selected`, nil while it is connecting). Switching Macs never ends it.
    func refresh(selected: Seen?, selection: (id: String?, name: String)?, activity seen: Seen?) {
        if let selected { lastSelected = selected }
        if let selection { self.selection = selection }
        if let activity {
            guard let seen else { announced(); return }
            lastSeen = seen
            if seen.state?.awake == true { awaitingAwakeUntil = nil }
            update(activity, seen)
            // Once it has ended the widget is back to the selected Mac.
            if endedIDs.contains(activity.id) {
                writeSnapshot(selectedForWidget(selected))
            } else {
                writeSnapshot(seen)
            }
        } else if let selected {
            lastSeen = selected
            writeSnapshot(selected)
        } else if self.selection != nil {
            // The selected Mac is connecting or without its key: never leave the widget on the Mac before it.
            writeSnapshot(selectedForWidget(nil))
        }
        announced()
    }

    /// What the widget shows once the activity is gone: the selected Mac as last seen, but never another
    /// Mac's (during a switch the new one may still be connecting): then just its name, not reachable.
    private func selectedForWidget(_ selected: Seen?) -> Seen {
        if let selected { return selected }
        let id = selection?.id
        if let last = lastSelected, last.macID == id { return last }
        return Seen(macID: id, macName: selection?.name ?? "Your Mac", reachable: false, lastHeard: nil, state: nil, sessions: [])
    }

    private func update(_ activity: Activity<MacActivityAttributes>, _ seen: Seen) {
        // Out of reach: as it last said, marked as such. Checked before the state: right
        // after a switch back to this Mac nothing has been heard yet, and that's no reason to end it.
        guard seen.reachable else {
            // As it last said, marked as such; the stale date stays.
            var last = activity.content.state
            guard last.reachable else { return }
            last.reachable = false
            let content = ActivityContent(state: last, staleDate: activity.content.staleDate)
            Task { await activity.update(content) }
            return
        }
        // Reachable, but its state hasn't come yet (just connected): keep what it shows.
        guard let state = seen.state else { return }
        if state.awake != true {
            if let until = awaitingAwakeUntil, until > .now { return }
            awaitingAwakeUntil = nil
            let final = ActivityContent(state: Self.content(seen), staleDate: nil)
            end(activity, final)
            return
        }
        let content = ActivityContent(state: Self.content(seen), staleDate: Self.stale(state))
        Task { await activity.update(content) }
    }

    /// The Mac was forgotten, or nothing is set up: no stale Mac on the Lock Screen or Home Screen.
    func clear() {
        if let activity { end(activity, nil) }
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
