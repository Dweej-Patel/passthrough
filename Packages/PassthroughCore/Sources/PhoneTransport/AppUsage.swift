import Foundation

// Per-app usage from `nettop` (the Mac side). `nettop -x -J
// interface,bytes_in,bytes_out` prints, for each sample, a header line naming
// the columns, then each process (`name.pid`) followed by its sockets with
// their interface and running byte totals. Only open sockets carry an
// interface, so the tally credits the growth of open sockets on the tunnel's
// interface; bytes moved by sockets that close between samples can't be tied
// to the tunnel and stay unattributed ("Other").
//
// Socket rows are BSD sockets (`tcp4`, `tcp6`, `udp4`, `udp6`, with the
// interface's name) and Network.framework QUIC flows (`quic4`, `quic6`, e.g.
// `quic6 .64600<->.65013,idx-25,...`), whose interface is `idx-` and the
// interface's index instead.

/// The command the sampler runs, shared with the smoke test so a format change
/// in the exact production invocation is caught.
public enum NettopCommand {
    public static let path = "/usr/bin/nettop"

    /// Bounded batches: an unbounded `-L 0` run ignores `-s` and spins a core.
    /// `-n` keeps addresses numeric: nettop otherwise swaps in host names as it
    /// resolves them, changing a socket's label between samples.
    public static func arguments(samples: Int = 30, interval: Int = 2) -> [String] {
        ["-n", "-c", "-x", "-s", String(interval), "-L", String(samples), "-J", "interface,bytes_in,bytes_out"]
    }
}

/// One socket row: its owner, interface and running totals since it opened.
public struct NettopRecord: Equatable, Sendable {
    public var pid: Int32
    public var processName: String
    /// e.g. "tcp4 192.0.2.10:52467<->198.51.100.7:443"; with `pid`, names the socket.
    public var label: String
    /// An interface name ("utun6"), or "idx-" and its index for a QUIC flow ("idx-28").
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
        if Self.socketKinds.contains(where: name.hasPrefix) {
            guard let process, let rx = Self.count(fields[bytesIn]), let tx = Self.count(fields[bytesOut]) else { return .skipped }
            return .connection(NettopRecord(pid: process.pid, processName: process.name, label: name,
                                            interface: fields[interface], bytesIn: rx, bytesOut: tx))
        }
        // A row naming endpoints or an interface is a socket of a kind not
        // known here, not a process: its trailing port isn't a pid, and the
        // rows after it still belong to the current process.
        if name.contains("<->") || !fields[interface].isEmpty { return .skipped }
        guard let dot = name.lastIndex(of: "."), dot > name.startIndex, let pid = Int32(name[name.index(after: dot)...]) else {
            process = nil
            return .skipped
        }
        let processName = String(name[..<dot])
        process = (pid, processName)
        return .process(pid: pid, name: processName)
    }

    static let socketKinds = ["tcp4 ", "tcp6 ", "udp4 ", "udp6 ", "quic4 ", "quic6 "]

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

/// Session totals per app, from running socket totals. Rows are collected
/// per sample and credited when the sample closes: each socket's growth past
/// the highest totals it has shown, so a `nettop` restart never counts
/// anything twice, and neither does a bad reading.
public struct AppUsageTally {
    /// Interfaces whose sockets count: the tunnel the apps' traffic is on,
    /// by name and as QUIC rows name it (see `NettopInterface.names`).
    public var tracked: Set<String>
    private let resolver: any AppResolver
    private var entries: [String: AppUsageEntry] = [:]
    /// Highest running totals per socket, and how many complete samples in
    /// a row have left it out.
    private var seen: [Socket: Seen] = [:]
    /// The sample being read. Rows sharing a key (unconnected UDP) are summed.
    private var current: [Socket: Totals] = [:]
    /// The session's first sample is a baseline: sockets already open on the
    /// tracked interface (a VPN that was up before the session) aren't usage.
    private var baselined = false
    /// Each batch's first sample is dropped: under load nettop's first sample
    /// lists some sockets with counters not read yet (0), and the jump to
    /// their real totals in the next sample would be credited as usage.
    private var dropNextSample = true
    private var dropping = false

    /// Complete samples a socket can be left out of before it is forgotten.
    /// A live socket missing from one sample must not count its whole total
    /// again when it's back; closed sockets must not pile up. 15 samples is
    /// 30 seconds at the sampler's interval.
    public static let forgetAfterMissedSamples = 15

    private struct Socket: Hashable {
        var pid: Int32
        var label: String
        var interface: String
        var processName: String
    }
    private struct Totals { var rx: Int64; var tx: Int64 }
    private struct Seen { var totals: Totals; var missed = 0 }

    public init(tracked: Set<String>, resolver: any AppResolver) {
        self.tracked = tracked
        self.resolver = resolver
    }

    /// A new sample starts: close the one being read.
    public mutating func beginSample() {
        if dropNextSample {
            dropNextSample = false
            dropping = true
            return
        }
        dropping = false
        close(complete: true)
    }

    /// The batch ended: credit its last sample, which may have been cut short,
    /// so the sockets it didn't reach don't count as missing.
    public mutating func endBatch() {
        dropNextSample = true
        dropping = false
        close(complete: false)
    }

    public mutating func add(_ record: NettopRecord) {
        guard !dropping else { return }
        let socket = Socket(pid: record.pid, label: record.label, interface: record.interface, processName: record.processName)
        current[socket, default: Totals(rx: 0, tx: 0)].rx += record.bytesIn
        current[socket, default: Totals(rx: 0, tx: 0)].tx += record.bytesOut
    }

    private mutating func close(complete: Bool) {
        guard !current.isEmpty else { return }
        let counting = baselined
        baselined = true
        for (socket, now) in current {
            // A counter below the socket's highest reading is a bad reading
            // (nettop lists sockets at 0 before it has read them), not a new
            // socket: only growth past the highest reading counts.
            let last = seen[socket]?.totals ?? Totals(rx: 0, tx: 0)
            let grewIn = max(0, now.rx - last.rx), grewOut = max(0, now.tx - last.tx)
            seen[socket] = Seen(totals: Totals(rx: max(last.rx, now.rx), tx: max(last.tx, now.tx)))
            guard counting, tracked.contains(socket.interface), grewIn > 0 || grewOut > 0 else { continue }
            let app = resolver.identity(pid: socket.pid, processName: socket.processName)
            entries[app.key, default: AppUsageEntry(app: app)].bytesIn += grewIn
            entries[app.key, default: AppUsageEntry(app: app)].bytesOut += grewOut
        }
        if complete {
            for (socket, entry) in seen where current[socket] == nil {
                if entry.missed >= Self.forgetAfterMissedSamples {
                    seen[socket] = nil
                } else {
                    seen[socket]?.missed += 1
                }
            }
        }
        current = [:]
    }

    public var attributed: Int64 { entries.values.reduce(0) { $0 + $1.total } }

    public func top(_ n: Int) -> [AppUsageEntry] {
        Array(entries.values.sorted { $0.total != $1.total ? $0.total > $1.total : $0.app.name < $1.app.name }.prefix(n))
    }

    public mutating func reset() {
        entries = [:]; seen = [:]; current = [:]; baselined = false
        dropNextSample = true; dropping = false
    }
}

/// What the card shows: the top apps and "Other", never adding up to more
/// than the session total. nettop and the tunnel's counters are read at
/// different moments, so the apps can briefly run ahead of the total; they
/// are then scaled down to fit it and "Other" is 0.
public struct AppUsageBreakdown: Equatable, Sendable {
    public var top: [AppUsageEntry]
    public var other: Int64

    /// `attributed` is what every app was credited, shown or not.
    public init(top: [AppUsageEntry], attributed: Int64, sessionTotal: Int64) {
        let total = max(0, sessionTotal)
        guard attributed > total else {
            self.top = top
            self.other = total - attributed
            return
        }
        let scale = Double(total) / Double(attributed)
        self.top = top.map {
            AppUsageEntry(app: $0.app, bytesIn: Int64((Double($0.bytesIn) * scale).rounded(.down)),
                          bytesOut: Int64((Double($0.bytesOut) * scale).rounded(.down)))
        }
        self.other = 0
    }
}

public enum NettopInterface {
    /// `interfaces` as socket rows name them: by name, and as `idx-` and the
    /// interface's index for QUIC flows. An interface that doesn't exist
    /// (index 0) keeps only its name.
    public static func names(_ interfaces: Set<String>, index: (String) -> UInt32 = { if_nametoindex($0) }) -> Set<String> {
        interfaces.reduce(into: interfaces) { names, interface in
            let i = index(interface)
            if i != 0 { names.insert("idx-\(i)") }
        }
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
