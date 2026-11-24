import Foundation
import PassthroughCore

/// The Mac's own stream of its screen to one phone (protocol/README.md,
/// "Screen video"), made by the app for a `screenVideo` request: capturing
/// and injecting input need the app's own permissions.
public protocol ScreenVideoSource: AnyObject, Sendable {
    /// Streams over `stream`, whose first phone bytes are `initialBytes`,
    /// until `stop()` or until it can't go on, when it calls `ended` (once).
    /// The connection owns the stream: the source must not cancel it or set
    /// its `onTerminated`; `ended` gets it closed.
    func start(stream: any ByteStream, initialBytes: Data, ended: @escaping @Sendable () -> Void)
    /// Stops capturing and sending. Idempotent; `ended` is not called after.
    func stop()
}

/// One computer's clipboard sync with this Mac (protocol/README.md,
/// "Clipboard sync"), made by the app for a `clipSync` request: the same
/// contract as `ScreenVideoSource`.
public protocol ClipSyncSource: AnyObject, Sendable {
    func start(stream: any ByteStream, initialBytes: Data, ended: @escaping @Sendable () -> Void)
    func stop()
}
