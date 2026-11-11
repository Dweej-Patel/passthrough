import Foundation

/// A Mac's open shell tabs and which one was showing.
public struct MacTabs: Codable, Equatable, Sendable {
    public var openTabs: [String]
    public var active: String?

    public init(openTabs: [String], active: String?) {
        self.openTabs = openTabs; self.active = active
    }
}

/// The tabs each paired Mac had open, so switching Macs brings them back.
public struct MacTabMemory: Codable, Equatable, Sendable {
    public private(set) var byMac: [String: MacTabs] = [:]

    public init() {}

    /// Remembers `tabs` for the Mac; nothing open and nothing active forgets it.
    public mutating func save(_ tabs: MacTabs, for macID: String) {
        byMac[macID] = tabs.openTabs.isEmpty && tabs.active == nil ? nil : tabs
    }

    public func tabs(for macID: String) -> MacTabs {
        byMac[macID] ?? MacTabs(openTabs: [], active: nil)
    }

    public mutating func forget(_ macID: String) { byMac[macID] = nil }

    /// Drops Macs no longer paired.
    public mutating func keepOnly(_ macIDs: Set<String>) {
        byMac = byMac.filter { macIDs.contains($0.key) }
    }
}

/// Sessions the phone hid from a Mac's list, per Mac.
public struct ShellHiddenSessions: Codable, Equatable, Sendable {
    public private(set) var byMac: [String: Set<String>] = [:]

    public init() {}

    public mutating func hide(_ id: String, on macID: String) { byMac[macID, default: []].insert(id) }

    /// Forgets hidden sessions the Mac no longer lists.
    public mutating func apply(listed: [String], on macID: String) {
        guard let hidden = byMac[macID] else { return }
        let kept = hidden.intersection(listed)
        byMac[macID] = kept.isEmpty ? nil : kept
    }

    public func visible(_ sessions: [ShellSessionInfo], on macID: String) -> [ShellSessionInfo] {
        let hidden = byMac[macID] ?? []
        return sessions.filter { !hidden.contains($0.id) }
    }

    public mutating func forget(_ macID: String) { byMac[macID] = nil }

    /// Drops Macs no longer paired.
    public mutating func keepOnly(_ macIDs: Set<String>) { byMac = byMac.filter { macIDs.contains($0.key) } }

    /// Only a finished session can be removed: known ended, or listed as not running. A running or unknown one can't.
    public func canRemove(_ id: String, ended: ShellEndedSessions, sessions: [ShellSessionInfo]) -> Bool {
        ended.isEnded(id) || sessions.first(where: { $0.id == id })?.running == false
    }
}

/// What the last key read learned about each Mac that granted the shell: which
/// granted (`granting`) and whose key needed authentication (`locked`). Kept
/// between refreshes so a switch to a Mac without a usable credential shows the
/// same state a refresh would. The Android app keeps the same facts.
public struct ShellKeyFacts: Equatable, Sendable {
    public var granting: Set<String>
    public var locked: Set<String>

    public init(granting: Set<String> = [], locked: Set<String> = []) {
        self.granting = granting; self.locked = locked
    }

    /// Whether `macID` (nil: nothing selected) has no usable credential because its key
    /// can't be read (plugging in renews it), rather than because it never granted the shell.
    public func keyUnavailable(for macID: String?) -> Bool {
        guard let macID else { return !granting.isEmpty || !locked.isEmpty }
        return granting.contains(macID) || locked.contains(macID)
    }
}

/// What a Mac's row in the switcher says about it.
public enum MacStatus: Equatable, Sendable {
    /// Reachable; the number of running sessions.
    case connected(shells: Int)
    case asking(title: String, question: String)
    case lastHeard(Date)
    /// Paired for internet only.
    case noShell
    case connecting
}

public enum MacProfiles {
    public static func status(sessions: [ShellSessionInfo]?, reachable: Bool, lastHeard: Date?, hasShell: Bool) -> MacStatus {
        guard hasShell else { return .noShell }
        if let asking = sessions?.first(where: \.isAsking), let question = asking.waiting {
            return .asking(title: asking.title, question: question)
        }
        if reachable { return .connected(shells: sessions?.filter(\.running).count ?? 0) }
        if let lastHeard { return .lastHeard(lastHeard) }
        return .connecting
    }

    public static func statusText(_ status: MacStatus, now: Date) -> String {
        switch status {
        case .connected(let shells):
            switch shells {
            case 0: return "Connected"
            case 1: return "Connected · 1 shell open"
            default: return "Connected · \(shells) shells open"
            }
        case .asking(let title, _): return "\(title) is asking a question"
        case .lastHeard(let date):
            let formatter = RelativeDateTimeFormatter()
            formatter.dateTimeStyle = .named
            return "Last heard \(formatter.localizedString(for: date, relativeTo: now))"
        case .noShell: return "Paired, no Remote shell"
        case .connecting: return "Connecting…"
        }
    }

    /// The avatar letter: the name's first letter, uppercased; "?" without one.
    public static func initial(_ macName: String) -> String {
        guard let first = macName.split(whereSeparator: \.isWhitespace).first?.first else { return "?" }
        return String(first).uppercased()
    }

    /// A stable palette slot per Mac: FNV-1a (32-bit) over the ID's UTF-8, mod
    /// `paletteCount`. The Android app computes the same.
    public static func colorIndex(macID: String, paletteCount: Int) -> Int {
        var hash: UInt32 = 2_166_136_261
        for byte in macID.utf8 { hash = (hash ^ UInt32(byte)) &* 16_777_619 }
        return Int(hash % UInt32(paletteCount))
    }

    /// Which Mac is selected after the paired list or credentials change: `current`
    /// while it is still paired (with or without a shell credential); else `lastUsed`
    /// if paired; else the first paired Mac with a shell, then the first paired Mac;
    /// nil when none is paired. The Android app picks the same.
    public static func selection(current: String?, lastUsed: String?, paired: [String], withShell: [String]) -> String? {
        if let current, paired.contains(current) { return current }
        if let lastUsed, paired.contains(lastUsed) { return lastUsed }
        return withShell.first(where: paired.contains) ?? paired.first
    }

    /// The Mac to open on launch: the last used one if still paired, else the first.
    public static func reopen(lastUsed: String?, available: [String]) -> String? {
        if let lastUsed, available.contains(lastUsed) { return lastUsed }
        return available.first
    }

    /// The Macs whose sessions to watch besides the selected one: every pinned
    /// Mac, then up to `limit` of the rest, most recently used first (ties keep
    /// candidate order). Pinned IDs count only when they are also in
    /// `candidates`: those are the Macs with a usable shell credential, and a
    /// Mac without one can't be dialed, so a stale pin is ignored.
    public static func watched(candidates: [String], selected: String?, recency: [String: Double],
                               pinned: Set<String>, limit: Int = 4) -> [String] {
        let others = candidates.filter { $0 != selected }
        let pinnedFirst = others.filter { pinned.contains($0) }
        let rest = others.enumerated()
            .filter { !pinned.contains($0.element) }
            .sorted { (recency[$0.element] ?? 0, -$0.offset) > (recency[$1.element] ?? 0, -$1.offset) }
            .prefix(max(limit, 0))
            .map(\.element)
        return pinnedFirst + rest
    }
    /// How recently each Mac was used, for `watched`: the later of when it
    /// last answered and when it was last selected (seconds since 1970).
    public static func recency(lastHeard: [String: Double], lastSelected: [String: Double]) -> [String: Double] {
        lastHeard.merging(lastSelected, uniquingKeysWith: max)
    }

    /// The Mac an activity with no Mac ID (started by an older build) belongs to:
    /// the one paired Mac with the activity's Mac name, else (none, or several
    /// share it) the selected Mac, the only one that build could have used.
    public static func adoptedMac(activityMacName: String, paired: [(id: String, name: String)],
                                  selected: String?) -> String? {
        let named = paired.filter { $0.name == activityMacName }
        return named.count == 1 ? named[0].id : selected
    }

    /// Which watch connections to end and which to dial so the running set
    /// becomes `wanted`: a Mac no longer wanted, or whose credential changed
    /// (a new key or address), is stopped; a wanted Mac not running, or
    /// stopped for a change, is started. `start` keeps `wanted`'s order.
    public static func watchChanges(running: [String: ShellCredential],
                                    wanted: [ShellCredential]) -> (stop: Set<String>, start: [ShellCredential]) {
        let wantedByID = Dictionary(wanted.map { ($0.macID, $0) }, uniquingKeysWith: { a, _ in a })
        let stop = Set(running.filter { id, credential in wantedByID[id] != credential }.keys)
        let start = wanted.filter { running[$0.macID] == nil || stop.contains($0.macID) }
        return (stop, start)
    }
}
