import Foundation

// Per-app usage from `nettop` (the Mac side). `nettop -x -J
// interface,bytes_in,bytes_out` prints, for each sample, a header line naming
// the columns, then each process (`name.pid`) followed by its sockets with
// their interface and running byte totals. Only open sockets carry an
// interface, so the tally credits the growth of open sockets on the tunnel's
// interface; bytes moved by sockets that close between samples can't be tied
// to the tunnel and stay unattributed ("Other").

/// One socket row: its owner, interface and running totals since it opened.
public struct NettopRecord: Equatable, Sendable {
    public var pid: Int32
    public var processName: String
    /// e.g. "tcp4 192.0.2.10:52467<->198.51.100.7:443"; with `pid`, names the socket.
    public var label: String
    public var interface: String
    public var bytesIn: Int64
    public var bytesOut: Int64

    public init(pid: Int32, processName: String, label: String, interface: String, bytesIn: Int64, bytesOut: Int64) {
        self.pid = pid; self.processName = processName; self.label = label
        self.interface = interface; self.bytesIn = bytesIn; self.bytesOut = bytesOut
    }
}

public enum NettopLine: Equatable, Sendable {
    /// A new sample starts.
    case header
    case process(pid: Int32, name: String)
    case connection(NettopRecord)
    case skipped
}

/// Line parser. Columns are found from each header, which may or may not
/// start with a `time` column; the first unnamed column holds the row label.
public struct NettopParser {
    private var label = 0, interface = 1, bytesIn = 2, bytesOut = 3
    private var hasHeader = false
    private var process: (pid: Int32, name: String)?

    public init() {}

    public mutating func parse<S: StringProtocol>(_ line: S) -> NettopLine {
        let fields = String(line).split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        if let i = fields.firstIndex(of: "bytes_in"), let o = fields.firstIndex(of: "bytes_out"),
           let f = fields.firstIndex(of: "interface"), let l = fields.firstIndex(of: "") {
            label = l; interface = f; bytesIn = i; bytesOut = o
            hasHeader = true
            process = nil
            return .header
        }
        guard hasHeader, fields.count > max(label, interface, bytesIn, bytesOut) else { return .skipped }
        let name = fields[label]
        if ["tcp4 ", "tcp6 ", "udp4 ", "udp6 "].contains(where: name.hasPrefix) {
            guard let process, let rx = Self.count(fields[bytesIn]), let tx = Self.count(fields[bytesOut]) else { return .skipped }
            return .connection(NettopRecord(pid: process.pid, processName: process.name, label: name,
                                            interface: fields[interface], bytesIn: rx, bytesOut: tx))
        }
        guard let dot = name.lastIndex(of: "."), dot > name.startIndex, let pid = Int32(name[name.index(after: dot)...]) else {
            process = nil
            return .skipped
        }
        let processName = String(name[..<dot])
        process = (pid, processName)
        return .process(pid: pid, name: processName)
    }

    /// Listening sockets print empty counts.
    private static func count(_ field: String) -> Int64? { field.isEmpty ? 0 : Int64(field) }
}

/// The app a person would recognise: `key` groups processes (an app bundle
/// path, an executable path, or the process name), `name` is shown.
public struct AppIdentity: Hashable, Sendable {
    public var key: String
    public var name: String
    public init(key: String, name: String) { self.key = key; self.name = name }
}

public protocol AppResolver {
    func identity(pid: Int32, processName: String) -> AppIdentity
}

public struct AppUsageEntry: Equatable, Sendable {
    public var app: AppIdentity
    public var bytesIn: Int64
    public var bytesOut: Int64
    public var total: Int64 { bytesIn + bytesOut }
    public init(app: AppIdentity, bytesIn: Int64 = 0, bytesOut: Int64 = 0) { self.app = app; self.bytesIn = bytesIn; self.bytesOut = bytesOut }
}

/// Session totals per app, from running socket totals. Remembers each socket's
/// last totals and credits only growth, so a socket first seen mid-life counts
/// from its start and a `nettop` restart never counts anything twice.
public struct AppUsageTally {
    /// Interfaces whose sockets count: the tunnel the apps' traffic is on.
    public var tracked: Set<String>
    private let resolver: any AppResolver
    private var entries: [String: AppUsageEntry] = [:]
    private var seen: [String: (rx: Int64, tx: Int64)] = [:]
    private var seenThisSample: Set<String> = []

    public init(tracked: Set<String>, resolver: any AppResolver) {
        self.tracked = tracked
        self.resolver = resolver
    }

    /// A new sample starts: forget sockets the last sample no longer listed
    /// (they closed), so a new socket reusing the label counts from zero.
    public mutating func beginSample() {
        seen = seen.filter { seenThisSample.contains($0.key) }
        seenThisSample = []
    }

    public mutating func add(_ record: NettopRecord) {
        let socket = "\(record.pid)|\(record.label)"
        seenThisSample.insert(socket)
        var grewIn = record.bytesIn, grewOut = record.bytesOut
        if let last = seen[socket], record.bytesIn >= last.rx, record.bytesOut >= last.tx {
            grewIn -= last.rx; grewOut -= last.tx
        }
        seen[socket] = (record.bytesIn, record.bytesOut)
        guard tracked.contains(record.interface), grewIn > 0 || grewOut > 0 else { return }
        let app = resolver.identity(pid: record.pid, processName: record.processName)
        entries[app.key, default: AppUsageEntry(app: app)].bytesIn += grewIn
        entries[app.key, default: AppUsageEntry(app: app)].bytesOut += grewOut
    }

    public var attributed: Int64 { entries.values.reduce(0) { $0 + $1.total } }

    public func top(_ n: Int) -> [AppUsageEntry] {
        Array(entries.values.sorted { $0.total != $1.total ? $0.total > $1.total : $0.app.name < $1.app.name }.prefix(n))
    }

    /// What the session moved that no open socket on the tunnel accounts for.
    public func other(sessionTotal: Int64) -> Int64 { max(0, sessionTotal - attributed) }

    public mutating func reset() {
        entries = [:]; seen = [:]; seenThisSample = []
    }
}

public enum AppBundle {
    /// The outermost `.app` around an executable, so helper apps nested inside
    /// an app (browsers, Electron apps) count as that app.
    public static func outermost(inExecutablePath path: String) -> String? {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard let i = parts.firstIndex(where: { $0.hasSuffix(".app") }) else { return nil }
        return parts[...i].joined(separator: "/")
    }
}

/// Whether to relaunch `nettop` after a batch ends: batches that end within
/// `minimumRun` several times in a row mean it is failing, not finishing.
public struct BatchRestartPolicy {
    public let minimumRun: TimeInterval
    public let maxQuickExits: Int
    private var quickExits = 0

    public init(minimumRun: TimeInterval = 5, maxQuickExits: Int = 3) {
        self.minimumRun = minimumRun
        self.maxQuickExits = maxQuickExits
    }

    public mutating func shouldRelaunch(afterRunOf duration: TimeInterval) -> Bool {
        quickExits = duration < minimumRun ? quickExits + 1 : 0
        return quickExits < maxQuickExits
    }
}
