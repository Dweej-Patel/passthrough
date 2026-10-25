#if os(macOS)
import Foundation
import PassthroughCore

/// What happened on the Mac, for a phone's timeline: events and battery
/// samples from the last `MacEvent.kept`, held in memory (a phone's request is
/// answered on the listener's queue, so reading never waits on the disk) and
/// saved to a JSON file shortly after each change.
public final class MacEventLog: @unchecked Sendable {
    private struct Stored: Codable {
        var events: [MacEvent]
        var battery: [BatterySample]
    }

    private let file: URL?
    private let now: @Sendable () -> Date
    private let saveDelay: TimeInterval
    private let lock = NSLock()
    private var stored = Stored(events: [], battery: [])
    private let writer = DispatchQueue(label: "passthrough.event-log")
    private var savePending = false

    /// Most kept, whatever their age.
    static let maxEvents = 2000
    static let maxSamples = Int(MacEvent.kept / BatterySample.interval)

    /// `file` nil keeps it in memory only. `now` and `saveDelay` are for tests.
    public init(file: URL?, now: @escaping @Sendable () -> Date = Date.init, saveDelay: TimeInterval = 2) {
        self.file = file
        self.now = now
        self.saveDelay = saveDelay
        if let file, let data = try? Data(contentsOf: file), let loaded = try? JSONDecoder().decode(Stored.self, from: data) {
            stored = loaded
            prune()
        }
    }

    /// `~/Library/Application Support/<identifier>/Activity/events.json`, in
    /// a folder only this user can open and kept out of backups: it holds
    /// shell titles and the questions they asked.
    public static func defaultFile() throws -> URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(PassthroughProtocol.identifier, isDirectory: true)
            .appendingPathComponent("Activity", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        var folder = dir
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? folder.setResourceValues(values)
        return dir.appendingPathComponent("events.json")
    }

    public func record(_ kind: String, _ title: String, detail: String? = nil, session: String? = nil, warning: Bool = false) {
        let event = MacEvent(t: now().timeIntervalSince1970, kind: kind, title: title, detail: detail, session: session,
                             warning: warning ? true : nil)
        lock.withLock {
            stored.events.append(event)
            prune()
        }
        scheduleSave()
    }

    /// Keeps a sample at most every `BatterySample.interval`, and always when charging starts or stops.
    public func sample(level: Double, charging: Bool) {
        let t = now().timeIntervalSince1970
        let kept: Bool = lock.withLock {
            if let last = stored.battery.last, t - last.t < BatterySample.interval, (last.charging ?? false) == charging { return false }
            stored.battery.append(BatterySample(t: t, level: max(0, min(1, level)), charging: charging ? true : nil))
            prune()
            return true
        }
        if kept { scheduleSave() }
    }

    /// Since `since` (and no further back than `MacEvent.kept`), oldest first;
    /// the battery from the sample just before `since`, so its line starts at the left edge.
    public func since(_ since: Double) -> (events: [MacEvent], battery: [BatterySample]) {
        let floor = max(since, now().timeIntervalSince1970 - MacEvent.kept)
        return lock.withLock {
            let events = stored.events.filter { $0.t >= floor }
            let start = stored.battery.lastIndex { $0.t < floor } ?? stored.battery.startIndex
            let battery = stored.battery[start...].filter { $0.t >= floor || $0.t == stored.battery[start].t }
            return (events, Array(battery))
        }
    }

    /// Under `lock`.
    private func prune() {
        let oldest = now().timeIntervalSince1970 - MacEvent.kept
        stored.events.removeAll { $0.t < oldest }
        stored.battery.removeAll { $0.t < oldest }
        // Over the cap, the oldest plain events go first: a burst of them
        // can't push out a warning such as the VPN being turned off.
        var excess = stored.events.count - Self.maxEvents
        if excess > 0 {
            stored.events.removeAll { event in
                guard excess > 0, event.warning != true else { return false }
                excess -= 1
                return true
            }
            if excess > 0 { stored.events.removeFirst(excess) }
        }
        if stored.battery.count > Self.maxSamples { stored.battery.removeFirst(stored.battery.count - Self.maxSamples) }
    }

    /// One write per burst of changes, off the caller's thread.
    private func scheduleSave() {
        guard let file else { return }
        let first = lock.withLock { () -> Bool in
            defer { savePending = true }
            return !savePending
        }
        guard first else { return }
        let save: @Sendable () -> Void = { [weak self] in
            guard let self else { return }
            let data: Data? = lock.withLock {
                self.savePending = false
                return try? JSONEncoder().encode(self.stored)
            }
            guard let data, (try? data.write(to: file, options: .atomic)) != nil else { return }
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
        if saveDelay > 0 { writer.asyncAfter(deadline: .now() + saveDelay, execute: save) } else { writer.async(execute: save) }
    }

    /// For tests: waits for a save already due (with a `saveDelay` of 0).
    func flush() { writer.sync {} }
}
#endif
