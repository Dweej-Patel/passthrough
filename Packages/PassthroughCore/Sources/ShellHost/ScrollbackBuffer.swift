#if os(macOS)
import Foundation

/// The last `capacity` bytes written to it: what a phone attaching late is
/// replayed so its terminal shows where the session is.
public struct ScrollbackBuffer {
    public let capacity: Int
    /// Up to twice `capacity`, so trimming (a copy) happens once per
    /// `capacity` bytes appended rather than on every append once full.
    private var bytes = Data()
    /// Older output has been dropped, so the contents may begin mid-stream.
    private var trimmed = false
    /// The terminal modes in force at `bytes[baseIndex]`, as what came before left them:
    /// kept at the start of `contents`, so a replay reads only the few bytes to a line start.
    private var base = TerminalModes()
    private var baseIndex = 0
    /// The terminal modes in force after everything appended.
    private(set) var modes = TerminalModes()
    /// How far into the contents a replay looks for a line start.
    static let resyncWindow = 4096

    public init(capacity: Int) { self.capacity = max(0, capacity) }

    public mutating func append(_ data: Data) {
        bytes.append(data)
        modes.scan(data)
        let start = max(0, bytes.count - capacity)   // where `contents` begins
        if start > baseIndex {
            base.scan(bytes[baseIndex..<start])
            baseIndex = start
        }
        if bytes.count > 2 * capacity {
            bytes = Data(bytes.suffix(capacity))   // re-based at index 0, which is where `contents` begins
            baseIndex = 0
            trimmed = true
        }
    }

    /// The last `capacity` bytes; may be a slice, so index from `startIndex`.
    public var contents: Data { bytes.count > capacity ? bytes.suffix(capacity) : bytes }

    /// The replay begins after the session's start: what came first is gone.
    public var isPartial: Bool { trimmed || bytes.count > capacity }

    /// What a late attach is replayed: the contents, but once older output
    /// was cut off, from just after the first newline near their start (else
    /// from the first whole UTF-8 character), so the replay does not begin
    /// inside a character or an escape sequence. May be a slice.
    ///
    /// A partial replay begins by turning on the modes the output cut off
    /// had turned on (`TerminalModes`): without it a full-screen program's
    /// frames land on the main screen, one after another.
    public var replay: Data {
        let tail = contents
        guard isPartial else { return tail }
        let from: Data
        if let newline = tail.prefix(Self.resyncWindow).firstIndex(of: 0x0A) {
            from = tail[(newline + 1)...]
        } else {
            from = tail.drop { $0 & 0xC0 == 0x80 }
        }
        let restoring = base.scanned(bytes[baseIndex..<from.startIndex]).restoring
        return restoring.isEmpty ? from : restoring + from
    }
}
#endif
