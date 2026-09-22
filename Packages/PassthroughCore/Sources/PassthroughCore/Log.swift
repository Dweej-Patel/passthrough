import Foundation
import os

/// Small ring log surfaced in both apps' diagnostics views and mirrored to the
/// unified logging system. Optionally backed by a file so separate processes
/// (the iPhone app and its tunnel extension) share one log: every process
/// appends to the file, and the app reads it back.
public final class PassthroughLog: @unchecked Sendable {
    public static let shared = PassthroughLog()

    public struct Entry: Identifiable, Sendable, Hashable {
        public let date: Date
        public let level: Level
        public let message: String
        /// Stable across reloads of the same line (SwiftUI keeps scroll position).
        public var id: Int {
            var h = Hasher(); h.combine(date.timeIntervalSince1970); h.combine(level); h.combine(message); return h.finalize()
        }
        public init(date: Date, level: Level, message: String) {
            self.date = date; self.level = level; self.message = message
        }
    }

    public enum Level: String, Sendable { case debug, info, warning, error }

    private let logger = Logger(subsystem: "dev.dpatel.passthrough", category: "core")
    private let lock = NSLock()
    private var entries: [Entry] = []
    private let capacity = 400
    private var fileURL: URL?
    private var fileHandle: FileHandle?
    private var appendedSinceCheck = 0
    public var onAppend: (@Sendable (Entry) -> Void)?

    /// Mirror every entry to `url` (appended, one line per entry). Call once at
    /// startup in every process that should contribute.
    public func attachFile(_ url: URL) {
        lock.lock(); defer { lock.unlock() }
        fileURL = url
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        fileHandle = try? FileHandle(forWritingTo: url)
        _ = try? fileHandle?.seekToEnd()
    }

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
        persist(entry)
        lock.unlock()
        onAppend?(entry)
    }

    public func snapshot() -> [Entry] {
        lock.lock(); defer { lock.unlock() }
        return entries
    }

    public func clear() {
        lock.lock(); entries.removeAll()
        if let fileURL {
            try? fileHandle?.close()
            try? Data().write(to: fileURL)
            fileHandle = try? FileHandle(forWritingTo: fileURL)
        }
        lock.unlock()
    }

    /// Reads the shared file back (last `capacity` lines), oldest first.
    public func loadPersisted() -> [Entry] {
        lock.lock(); let url = fileURL; lock.unlock()
        guard let url, let data = try? Data(contentsOf: url), !data.isEmpty else { return [] }
        let text = String(decoding: data, as: UTF8.self)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true).suffix(capacity)
        return lines.compactMap(Self.parse)
    }

    /// Modification date of the shared file, to skip reloads when nothing changed.
    public var persistedModificationDate: Date? {
        lock.lock(); let url = fileURL; lock.unlock()
        guard let url else { return nil }
        return (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
    }

    // MARK: File format: "<epoch>\t<level>\t<message>" (newlines in message escaped)

    private func persist(_ entry: Entry) {
        guard let handle = fileHandle else { return }
        let safe = entry.message.replacingOccurrences(of: "\n", with: "\\n")
        let line = "\(entry.date.timeIntervalSince1970)\t\(entry.level.rawValue)\t\(safe)\n"
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data(line.utf8))
        appendedSinceCheck += 1
        if appendedSinceCheck >= 200 { appendedSinceCheck = 0; trimIfLarge() }
    }

    /// Keeps the file bounded: once past ~512 KB, rewrite it with the last lines only.
    private func trimIfLarge() {
        guard let fileURL, let size = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size]) as? Int, size > 512_000,
              let data = try? Data(contentsOf: fileURL) else { return }
        let kept = String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: true).suffix(capacity)
        try? fileHandle?.close()
        try? (kept.joined(separator: "\n") + "\n").write(to: fileURL, atomically: true, encoding: .utf8)
        fileHandle = try? FileHandle(forWritingTo: fileURL)
        _ = try? fileHandle?.seekToEnd()
    }

    private static func parse(_ line: Substring) -> Entry? {
        let parts = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3, let epoch = Double(parts[0]), let level = Level(rawValue: String(parts[1])) else { return nil }
        return Entry(date: Date(timeIntervalSince1970: epoch), level: level,
                     message: String(parts[2]).replacingOccurrences(of: "\\n", with: "\n"))
    }
}

@inline(__always) public func ptLog(_ level: PassthroughLog.Level = .info, _ message: @autoclosure () -> String) {
    PassthroughLog.shared.log(level, message())
}
