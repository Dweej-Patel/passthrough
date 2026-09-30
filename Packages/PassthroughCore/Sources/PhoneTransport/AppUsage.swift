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
