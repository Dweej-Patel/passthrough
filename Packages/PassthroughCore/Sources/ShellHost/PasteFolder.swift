import Foundation
import PassthroughCore

/// Where files a phone pastes into a session (`upload`) are saved: one
/// folder of the Mac user's own, holding the newest `keep`. A pasted path is
/// read by whatever runs in the session (Claude Code attaches the image), so
/// a file stays a while after its paste.
public final class PasteFolder: @unchecked Sendable {
    public let directory: URL
    public let keep: Int
    private let lock = NSLock()

    public init(directory: URL = PasteFolder.defaultDirectory(), keep: Int = 30) {
        self.directory = directory
        self.keep = max(1, keep)
    }

    /// `~/Library/Caches/<identifier>/Pasted`: no spaces, so a pasted path needs no quoting.
    public static func defaultDirectory() -> URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(PassthroughProtocol.identifier, isDirectory: true)
            .appendingPathComponent("Pasted", isDirectory: true)
    }

    /// A new empty file named for now (`pasted-20261125-091500-a1b2.png`), and its handle.
    func create(extension ext: String) throws -> (url: URL, handle: FileHandle) {
        lock.lock(); defer { lock.unlock() }
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let stamp = Self.stamp.string(from: Date())
        for _ in 0..<8 {
            let suffix = String(UInt16.random(in: 0...UInt16.max), radix: 16)
            let url = directory.appendingPathComponent("pasted-\(stamp)-\(suffix).\(ext)")
            // `createFile` would replace a file already there.
            guard !fm.fileExists(atPath: url.path),
                  fm.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { continue }
            return (url, try FileHandle(forWritingTo: url))
        }
        throw CocoaError(.fileWriteFileExists)
    }

    /// Drops all but the newest `keep` files.
    func prune() {
        lock.lock(); defer { lock.unlock() }
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.creationDateKey],
                                                     options: [.skipsHiddenFiles]) else { return }
        guard files.count > keep else { return }
        let dated = files.map { ($0, (try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast) }
        for (url, _) in dated.sorted(by: { $0.1 > $1.1 }).dropFirst(keep) { try? fm.removeItem(at: url) }
    }

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f
    }()
}
