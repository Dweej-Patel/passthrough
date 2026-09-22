import Foundation
import os

/// Tiny in-memory ring log that both apps surface in their diagnostics views,
/// mirrored to the unified logging system.
public final class PassthroughLog: @unchecked Sendable {
    public static let shared = PassthroughLog()

    public struct Entry: Identifiable, Sendable, Hashable {
        public let id = UUID()
        public let date: Date
        public let level: Level
        public let message: String
    }

    public enum Level: String, Sendable { case debug, info, warning, error }

    private let logger = Logger(subsystem: "dev.dpatel.passthrough", category: "core")
    private let lock = NSLock()
    private var entries: [Entry] = []
    private let capacity = 400
    public var onAppend: (@Sendable (Entry) -> Void)?

    public func log(_ level: Level, _ message: @autoclosure () -> String) {
        let text = message()
        switch level {
        case .debug: logger.debug("\(text, privacy: .public)")
        case .info: logger.notice("\(text, privacy: .public)")
        case .warning: logger.warning("\(text, privacy: .public)")
        case .error: logger.error("\(text, privacy: .public)")
        }
        let entry = Entry(date: Date(), level: level, message: text)
        lock.lock()
        entries.append(entry)
        if entries.count > capacity { entries.removeFirst(entries.count - capacity) }
        lock.unlock()
        onAppend?(entry)
    }

    public func snapshot() -> [Entry] {
        lock.lock(); defer { lock.unlock() }
        return entries
    }

    public func clear() {
        lock.lock(); entries.removeAll(); lock.unlock()
    }
}

@inline(__always) public func ptLog(_ level: PassthroughLog.Level = .info, _ message: @autoclosure () -> String) {
    PassthroughLog.shared.log(level, message())
}
