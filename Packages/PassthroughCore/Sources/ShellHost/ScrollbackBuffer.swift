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
    /// How far into the contents a replay looks for a line start.
    static let resyncWindow = 4096

    public init(capacity: Int) { self.capacity = max(0, capacity) }

    public mutating func append(_ data: Data) {
        bytes.append(data)
        if bytes.count > 2 * capacity { bytes = Data(bytes.suffix(capacity)); trimmed = true }   // re-based at index 0
    }

    /// The last `capacity` bytes; may be a slice, so index from `startIndex`.
    public var contents: Data { bytes.count > capacity ? bytes.suffix(capacity) : bytes }

    /// What a late attach is replayed: the contents, but once older output
    /// was cut off, from just after the first newline near their start (else
    /// from the first whole UTF-8 character), so the replay does not begin
    /// inside a character or an escape sequence. May be a slice.
    public var replay: Data {
        let tail = contents
        guard trimmed || bytes.count > capacity else { return tail }
        if let newline = tail.prefix(Self.resyncWindow).firstIndex(of: 0x0A) { return tail[(newline + 1)...] }
        return tail.drop { $0 & 0xC0 == 0x80 }
    }
}
#endif
