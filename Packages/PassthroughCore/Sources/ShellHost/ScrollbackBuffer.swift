#if os(macOS)
import Foundation

/// The last `capacity` bytes written to it: what a phone attaching late is
/// replayed so its terminal shows where the session is.
public struct ScrollbackBuffer {
    public let capacity: Int
    /// Up to twice `capacity`, so trimming (a copy) happens once per
    /// `capacity` bytes appended rather than on every append once full.
    private var bytes = Data()

    public init(capacity: Int) { self.capacity = max(0, capacity) }

    public mutating func append(_ data: Data) {
        bytes.append(data)
        if bytes.count > 2 * capacity { bytes = Data(bytes.suffix(capacity)) }   // re-based at index 0
    }

    /// The last `capacity` bytes; may be a slice, so index from `startIndex`.
    public var contents: Data { bytes.count > capacity ? bytes.suffix(capacity) : bytes }
}
#endif
