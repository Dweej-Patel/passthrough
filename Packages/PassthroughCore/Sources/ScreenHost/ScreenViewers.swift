#if os(macOS)
import Foundation

/// The devices viewing this Mac's screen now, for "Use Here": each view is
/// told who else is viewing, and one can end the others' views (they're told
/// who took over). A device counts once, however many streams it has (one
/// trying to replace Screen Sharing, say).
final class ScreenViewers: @unchecked Sendable {
    /// One view: who it is, and how to reach it.
    struct Viewer {
        let phoneID: String
        let name: String
        /// Who else is viewing now (names, no duplicates); called on any thread.
        let others: @Sendable ([String]) -> Void
        /// Another device took over, by this name: end this view.
        let movedAway: @Sendable (String) -> Void
    }

    static let shared = ScreenViewers()

    private let lock = NSLock()
    private var viewers: [UUID: Viewer] = [:]

    func join(_ id: UUID, _ viewer: Viewer) {
        lock.withLock { viewers[id] = viewer }
        tellEveryone()
    }

    func leave(_ id: UUID) {
        let left = lock.withLock { viewers.removeValue(forKey: id) != nil }
        if left { tellEveryone() }
    }

    /// `id`'s device is used here now: every other device's views end.
    func takeOver(by id: UUID) {
        let (name, gone) = lock.withLock { () -> (String?, [Viewer]) in
            guard let me = viewers[id] else { return (nil, []) }
            let gone = viewers.filter { $0.value.phoneID != me.phoneID }
            gone.keys.forEach { viewers.removeValue(forKey: $0) }
            return (me.name, Array(gone.values))
        }
        guard let name else { return }
        gone.forEach { $0.movedAway(name) }
        tellEveryone()
    }

    /// Each view's list of the others.
    private func tellEveryone() {
        let all = lock.withLock { Array(viewers.values) }
        for viewer in all {
            var seen = Set<String>(), names: [String] = []
            for other in all where other.phoneID != viewer.phoneID && seen.insert(other.phoneID).inserted {
                names.append(other.name)
            }
            viewer.others(names)
        }
    }
}
#endif
