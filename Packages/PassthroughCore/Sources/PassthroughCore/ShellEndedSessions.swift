import Foundation

/// The sessions a phone knows have ended, learned from the Mac's `ended`
/// message and from `sessions` entries with `running == false` (the Mac keeps
/// ended sessions listed for a while). An ended session's terminal is a
/// read-only log of its output.
public struct ShellEndedSessions: Equatable, Sendable {
    /// Exit status per ended session; nil when the Mac didn't say.
    public private(set) var exits: [String: Int32?] = [:]

    public init() {}

    /// The Mac said `id` ended. A negative status means it gave none
    /// (real ones are 0...255, or 128 + signal).
    public mutating func ended(_ id: String, exitStatus: Int32?) {
        let status = exitStatus.flatMap { $0 < 0 ? nil : $0 }
        // Don't lose a status already known from the list to a message without one.
        // `.some`: assigning a bare nil would remove the entry instead.
        if status != nil || exits[id] == nil { exits[id] = .some(status) }
    }

    /// Takes in the Mac's session list: entries no longer running have ended.
    /// Ended sessions the Mac stopped listing are forgotten unless in `keeping`
    /// (a tab still showing its log).
    public mutating func apply(_ list: [ShellSessionInfo], keeping: Set<String> = []) {
        let listed = Set(list.map(\.id))
        exits = exits.filter { listed.contains($0.key) || keeping.contains($0.key) }
        for info in list where !info.running { ended(info.id, exitStatus: info.exitStatus) }
        // A listed running session is running, whatever an earlier message said.
        for info in list where info.running { exits[info.id] = nil }
    }

    /// The tab was closed: nothing to remember about it.
    public mutating func forget(_ id: String) { exits[id] = nil }

    public func isEnded(_ id: String) -> Bool { exits[id] != nil }

    /// The exit status of an ended session, if the Mac gave one.
    public func exitStatus(_ id: String) -> Int32? { exits[id] ?? nil }

    /// Whether the terminal showing `id` takes input. Nothing shown yet (a
    /// session still opening) counts as writable: there's no log to protect.
    public func isWritable(_ id: String?) -> Bool {
        guard let id else { return true }
        return !isEnded(id)
    }

    /// Whether the terminal showing `id` takes input, given the open tabs: a
    /// session whose tab was closed doesn't either (its stale output may still
    /// be on screen).
    public func isWritable(_ id: String?, openTabs: [String]) -> Bool {
        guard let id else { return true }
        return openTabs.contains(id) && !isEnded(id)
    }

    /// The banner over an ended session's log; nil while it runs.
    public func banner(_ id: String) -> String? {
        isEnded(id) ? Self.banner(exitStatus: exitStatus(id)) : nil
    }

    public static func banner(exitStatus: Int32?) -> String {
        guard let exitStatus, exitStatus >= 0 else { return "Session closed — read-only" }
        return "Session ended (exit \(exitStatus)) — read-only"
    }
}
