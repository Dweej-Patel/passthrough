import Foundation

/// A value guarded by a lock, for state shared between network callbacks.
public final class Locked<T>: @unchecked Sendable {
    private var value: T
    private let lock = NSLock()
    public init(_ value: T) { self.value = value }
    public func exchange(_ new: T) -> T { lock.lock(); defer { lock.unlock() }; let old = value; value = new; return old }
    public func get() -> T { lock.lock(); defer { lock.unlock() }; return value }
    public func set(_ new: T) { lock.lock(); value = new; lock.unlock() }
}
