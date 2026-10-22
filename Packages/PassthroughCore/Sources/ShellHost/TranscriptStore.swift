#if os(macOS)
import Darwin
import Foundation
import PassthroughCore

/// Every session's output, kept on the Mac so the owner can review it later.
/// Per session: `<id>.cast` (asciicast v2: output events, and resize events
/// whenever the terminal changes size, and every `sizeCheckpoint` bytes so a
/// tail read finds the size its start was drawn at) and `<id>.json`
/// (the `ShellHistoryEntry`). Never log what is in them.
public final class TranscriptStore: @unchecked Sendable {
    /// Most a session's cast file grows to; recording stops there with a marker.
    public static let castLimit: Int64 = 64 << 20
    /// Most output a transcript read returns: the end of the session.
    public static let readLimit = 8 << 20

    private let directory: URL
    private let castLimit: Int64
    private let sizeCheckpoint: Int64
    private let lock = NSLock()
    /// Writers still recording, so a deletion can stop them from writing again.
    private var live: [String: WeakWriter] = [:]
    /// Decoded entries by id, with the `.json` file's modification date and
    /// size when read, so a listing re-reads only what changed.
    private var cached: [String: (stamp: FileStamp, entry: ShellHistoryEntry)] = [:]

    private struct WeakWriter { weak var writer: TranscriptWriter? }
    private struct FileStamp: Equatable { let modified: Date; let size: Int }

    /// Most cast bytes between two resize events: past it, the writer restates
    /// the size, so a tail read never looks further back than this for it.
    public static let sizeCheckpoint: Int64 = 1 << 20

    /// `castLimit` and `sizeCheckpoint` are for tests.
    public init(directory: URL, castLimit: Int64 = TranscriptStore.castLimit,
                sizeCheckpoint: Int64 = TranscriptStore.sizeCheckpoint) throws {
        self.directory = directory
        self.castLimit = castLimit
        self.sizeCheckpoint = sizeCheckpoint
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // A folder that already existed keeps its mode above: tighten it too.
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }

    public static func defaultDirectory() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support
            .appendingPathComponent(PassthroughProtocol.identifier, isDirectory: true)
            .appendingPathComponent("ShellHistory", isDirectory: true)
    }

    public func begin(id: String, title: String, phoneLabel: String, cols: Int, rows: Int, at: Date) throws -> TranscriptWriter {
        let castURL = try url(id, "cast")
        let jsonURL = try url(id, "json")
        // One critical section with `deleteFinished`: files exist only once the writer is registered.
        lock.lock(); defer { lock.unlock() }
        // Clamped like resizes, so the size a replay starts with is always a valid one.
        let cols = ShellReplay.clamp(cols), rows = ShellReplay.clamp(rows)
        let header: [String: Any] = [
            "version": 2, "width": cols, "height": rows,
            "timestamp": Int(at.timeIntervalSince1970), "title": title,
        ]
        let handle = try Self.create(castURL)
        let headerLine = try JSONSerialization.data(withJSONObject: header) + Data("\n".utf8)
        try handle.write(contentsOf: headerLine)
        let entry = ShellHistoryEntry(id: id, title: title, phoneLabel: phoneLabel,
                                      startedAt: at.timeIntervalSince1970, bytes: 0, cols: cols, rows: rows)
        try Self.writeEntry(entry, to: jsonURL)
        let writer = TranscriptWriter(handle: handle, entry: entry, castURL: castURL, jsonURL: jsonURL,
                                      written: Int64(headerLine.count), limit: castLimit,
                                      cols: cols, rows: rows, checkpoint: sizeCheckpoint)
        live = live.filter { $0.value.writer != nil }   // drop sessions long gone
        live[id] = WeakWriter(writer: writer)
        return writer
    }

    /// Newest first. `bytes` is the cast file's size now, so live sessions are
    /// current. Only `.json` files that changed since the last call are decoded.
    public func entries() -> [ShellHistoryEntry] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys)) ?? []
        lock.lock()
        let known = cached
        lock.unlock()
        var fresh: [String: (stamp: FileStamp, entry: ShellHistoryEntry)] = [:]
        for file in files where file.pathExtension == "json" {
            let id = file.deletingPathExtension().lastPathComponent
            guard let values = try? file.resourceValues(forKeys: Set(keys)),
                  let modified = values.contentModificationDate else { continue }
            let stamp = FileStamp(modified: modified, size: values.fileSize ?? 0)
            if let hit = known[id], hit.stamp == stamp {
                fresh[id] = hit
            } else if let entry = (try? Data(contentsOf: file)).flatMap({ try? JSONDecoder().decode(ShellHistoryEntry.self, from: $0) }) {
                fresh[id] = (stamp, entry)
            }
        }
        lock.lock()
        cached = fresh   // removed files drop out here
        lock.unlock()
        return fresh.values.map { item -> ShellHistoryEntry in
            var entry = item.entry
            entry.bytes = Self.size(of: directory.appendingPathComponent("\(item.entry.id).cast"))
            return entry
        }.sorted { $0.startedAt > $1.startedAt }
    }

    /// The end of the session's output, as the bytes the shell wrote: at most
    /// `maxBytes`, read backwards from the end of the cast file a block at a
    /// time, so a long session never has to fit in memory.
    public func output(of id: String, maxBytes: Int = TranscriptStore.readLimit) throws -> Data {
        try Self.tail(of: url(id, "cast"), maxBytes: maxBytes).output
    }

    /// The end of the session (at most `maxBytes` of output) with the
    /// terminal's sizes: first the size its first byte was drawn at (the last
    /// resize before it, else the header's), then output and size changes in order.
    public func replay(of id: String, maxBytes: Int = TranscriptStore.readLimit) throws -> [ShellReplayChunk] {
        try Self.replay(of: url(id, "cast"), maxBytes: maxBytes).chunks
    }

    static let tailBlock = 256 << 10
    /// A line longer than this is not one the writer produced; reading stops there.
    static let tailLineLimit = 16 << 20

    /// The last `maxBytes` of output in a cast file, and how many bytes of the
    /// file were read to find them.
    static func tail(of url: URL, maxBytes: Int) throws -> (output: Data, bytesRead: Int) {
        let (chunks, bytesRead) = try replay(of: url, maxBytes: maxBytes)
        var output = Data()
        for case let .output(data) in chunks { output.append(data) }
        return (output, bytesRead)
    }

    /// How far past the cut a tail read looks for the size in effect there
    /// before taking the header's (a cast from before sizes were restated
    /// every `sizeCheckpoint` may have none until its header).
    static let sizeSearchLimit = 2 << 20
    private static let resizeMarker = Data(#","r","#.utf8)

    /// `replay(of:maxBytes:)` for a cast file, and how many bytes of it were read.
    /// Size events' lines count against a budget of their own, also `maxBytes`,
    /// so a cast of little but resizes is still read only so far.
    static func replay(of url: URL, maxBytes: Int) throws -> (chunks: [ShellReplayChunk], bytesRead: Int) {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var position = try handle.seekToEnd()
        var carry = Data()                  // the start of a line whose beginning is in an earlier block
        var pieces: [ShellReplayChunk] = [] // newest first
        var output = 0                      // output bytes taken
        var sizes = 0                       // resize line lengths taken
        var bytesRead = 0
        var pastCut = 0                     // bytes read looking for the size once full
        var startSize: (cols: Int, rows: Int)?
        var full: Bool { output >= maxBytes || sizes >= maxBytes }
        func take(_ line: Data.SubSequence) {
            if full, line.range(of: resizeMarker) == nil { return }
            guard let event = try? JSONSerialization.jsonObject(with: Data(line)) as? [Any],
                  event.count == 3, let text = event[2] as? String else { return }
            switch event[1] as? String {
            case "o" where !full:
                let data = Data(text.utf8)
                pieces.append(.output(data))
                output += data.count
            case "r":
                guard let size = ShellReplay.parseSize(text) else { return }
                if full {
                    startSize = size
                } else {
                    pieces.append(.resize(cols: size.cols, rows: size.rows))
                    sizes += line.count
                    if full { startSize = size }   // the oldest piece is a size: it is where the replay starts
                }
            default:
                break
            }
        }
        while position > 0, startSize == nil {
            if full, pastCut > sizeSearchLimit { break }
            let start = position > UInt64(tailBlock) ? position - UInt64(tailBlock) : 0
            try handle.seek(toOffset: start)
            let block = try handle.read(upToCount: Int(position - start)) ?? Data()
            bytesRead += block.count
            if full { pastCut += block.count }
            position = start
            var buffer = block + carry
            if full, buffer.range(of: resizeMarker) == nil {
                // No size here: keep only the line that may continue into the previous block.
                carry = Data(buffer[..<(buffer.firstIndex(of: 0x0A) ?? buffer.endIndex)])
                guard carry.count <= tailLineLimit else { break }
                continue
            }
            // Every complete line after the first newline; what precedes it may continue into the previous block.
            while startSize == nil, let newline = buffer.lastIndex(of: 0x0A) {
                take(buffer[(newline + 1)...])
                buffer = buffer[..<newline]
            }
            carry = Data(buffer)
            guard carry.count <= tailLineLimit else { break }
        }
        // The header's size: the first one, or the fallback when no resize is close enough.
        if startSize == nil {
            let header = position == 0 ? carry : try readHeader(handle)
            if let object = try? JSONSerialization.jsonObject(with: header) as? [String: Any],
               let cols = object["width"] as? Int, let rows = object["height"] as? Int,
               ShellReplay.isValid(cols: cols, rows: rows) {
                startSize = (cols, rows)
            }
        }
        var chunks: [ShellReplayChunk] = []
        if let startSize { chunks.append(.resize(cols: startSize.cols, rows: startSize.rows)) }
        // Oldest first; the oldest piece may be output reaching back past the cut.
        var excess = pieces.last.map { if case .output = $0 { max(0, output - maxBytes) } else { 0 } } ?? 0
        var joined = Data()
        func flush() { if !joined.isEmpty { chunks.append(.output(joined)); joined = Data() } }
        for piece in pieces.reversed() {
            switch piece {
            case let .resize(cols, rows):
                flush()
                // Resizes with no output between them: only the last matters.
                if case .resize = chunks.last { chunks.removeLast() }
                chunks.append(.resize(cols: cols, rows: rows))
            case var .output(data):
                if excess > 0 {
                    var cut = min(excess, data.count)
                    // Start on a character, not inside one.
                    while cut < data.count, data[data.startIndex + cut] & 0xC0 == 0x80 { cut += 1 }
                    data = data.subdata(in: (data.startIndex + cut)..<data.endIndex)
                    excess = 0
                }
                joined.append(data)
            }
        }
        flush()
        return (chunks, bytesRead)
    }

    /// The cast's first line.
    private static func readHeader(_ handle: FileHandle) throws -> Data {
        try handle.seek(toOffset: 0)
        let start = try handle.read(upToCount: 64 << 10) ?? Data()
        return Data(start[..<(start.firstIndex(of: 0x0A) ?? start.endIndex)])
    }

    public func delete(id: String) {
        lock.lock()
        let writer = live.removeValue(forKey: id)?.writer
        lock.unlock()
        writer?.cancel()
        for ext in ["cast", "json"] {
            if let url = try? url(id, ext) { try? FileManager.default.removeItem(at: url) }
        }
    }

    /// Deletes every transcript that is not still being recorded. A session
    /// just opening has a live writer, so its files stay.
    public func deleteFinished() {
        lock.lock(); defer { lock.unlock() }
        let recording = Set(live.compactMap { $0.value.writer?.isRecording == true ? $0.key : nil })
        for file in (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [] {
            if recording.contains(file.deletingPathExtension().lastPathComponent) { continue }
            try? FileManager.default.removeItem(at: file)
        }
        live = live.filter { recording.contains($0.key) }
        cached = cached.filter { recording.contains($0.key) }
    }

    public func deleteAll() {
        lock.lock()
        let writers = live.values.compactMap(\.writer)
        live.removeAll()
        lock.unlock()
        writers.forEach { $0.cancel() }
        for file in (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [] {
            try? FileManager.default.removeItem(at: file)
        }
    }

    public func totalBytes() -> Int64 {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.reduce(0) { $0 + Self.size(of: $1) }
    }

    /// Ids are opaque, but they become file names: nothing that can leave the directory.
    private func url(_ id: String, _ ext: String) throws -> URL {
        guard !id.isEmpty, !id.contains("/"), !id.contains("..") else { throw CocoaError(.fileNoSuchFile) }
        return directory.appendingPathComponent("\(id).\(ext)")
    }

    private static func size(of url: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.int64Value ?? 0
    }

    /// Created 0600 (not chmod'ed afterwards), truncating any earlier file.
    static func create(_ url: URL) throws -> FileHandle {
        let fd = open(url.path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }

    static func writeEntry(_ entry: ShellHistoryEntry, to url: URL) throws {
        let handle = try create(url)
        defer { try? handle.close() }
        try handle.write(contentsOf: try JSONEncoder().encode(entry))
    }
}

/// Appends one session's output to its cast file. Safe to call from any queue.
public final class TranscriptWriter: @unchecked Sendable {
    private let lock = NSLock()
    private var handle: FileHandle?
    private var entry: ShellHistoryEntry
    private let castURL: URL
    private let jsonURL: URL
    /// An incomplete UTF-8 sequence at the end of the last chunk (at most 3 bytes).
    private var pending = Data()
    private var cancelled = false
    /// The cast file's size so far, and the most it may reach.
    private var written: Int64
    private let limit: Int64
    /// The limit was reached: the marker is written and nothing more is.
    private var truncated = false
    /// The terminal's size now, and the cast's size when it was last written down.
    private var cols: Int
    private var rows: Int
    private var sizeWrittenAt: Int64
    private let checkpoint: Int64

    /// What ends a cast that reached its limit.
    static let truncationMarker = "\r\n[transcript truncated]\r\n"
    /// Room kept below the limit for the marker's event line.
    private static let markerReserve: Int64 = 128

    init(handle: FileHandle, entry: ShellHistoryEntry, castURL: URL, jsonURL: URL, written: Int64, limit: Int64,
         cols: Int, rows: Int, checkpoint: Int64) {
        self.handle = handle; self.entry = entry; self.castURL = castURL; self.jsonURL = jsonURL
        self.written = written; self.limit = limit
        self.cols = cols; self.rows = rows; self.sizeWrittenAt = written; self.checkpoint = checkpoint
    }

    /// The terminal changed size: a resize event (asciicast v2 `"r"`), so a
    /// replay draws what follows at the width the shell drew it for. Output
    /// held back as an incomplete character stays held: it continues after.
    public func resize(cols: Int, rows: Int, at: Date) {
        lock.lock(); defer { lock.unlock() }
        let cols = ShellReplay.clamp(cols), rows = ShellReplay.clamp(rows)
        guard handle != nil, !truncated, cols != self.cols || rows != self.rows else { return }
        self.cols = cols
        self.rows = rows
        writeSize(at: at)
    }

    public func append(_ data: Data, at: Date) {
        lock.lock(); defer { lock.unlock() }
        guard handle != nil, !truncated else { return }
        let bytes = pending + data
        let keep = Self.incompleteTailLength(bytes)
        pending = Data(bytes.suffix(keep))
        write(Data(bytes.dropLast(keep)), at: at)
    }

    /// Still writing: neither finished nor deleted.
    var isRecording: Bool { lock.lock(); defer { lock.unlock() }; return handle != nil && !cancelled }

    /// The session was deleted: stop writing and recreate nothing.
    func cancel() {
        lock.lock(); defer { lock.unlock() }
        try? handle?.close()
        handle = nil
        cancelled = true
    }

    /// The title is only known once the first command is typed; the cast header keeps its original.
    public func setTitle(_ title: String) {
        lock.lock(); defer { lock.unlock() }
        guard !cancelled else { return }
        entry.title = title
        try? TranscriptStore.writeEntry(entry, to: jsonURL)
    }

    public func finish(exitStatus: Int32?, at: Date) {
        lock.lock(); defer { lock.unlock() }
        guard let handle, !cancelled else { return }
        write(pending, at: at)
        pending = Data()
        try? handle.close()
        self.handle = nil
        entry.endedAt = at.timeIntervalSince1970
        entry.exitStatus = exitStatus
        entry.bytes = written
        try? TranscriptStore.writeEntry(entry, to: jsonURL)
    }

    /// One output event, after restating the size if the last statement is
    /// `checkpoint` bytes back.
    private func write(_ bytes: Data, at: Date) {
        guard !bytes.isEmpty, !truncated else { return }
        if written - sizeWrittenAt >= checkpoint { writeSize(at: at) }
        record("o", String(decoding: bytes, as: UTF8.self), at: at)
    }

    private func writeSize(at: Date) {
        record("r", ShellReplay.sizeString(cols: cols, rows: rows), at: at)
        sizeWrittenAt = written
    }

    /// Appends one event line. Past the limit, the marker goes in instead and
    /// recording stops; the session itself carries on.
    private func record(_ code: String, _ text: String, at: Date) {
        guard !truncated, let line = eventLine(code, text, at: at) else { return }
        if written + Int64(line.count) > limit - Self.markerReserve {
            truncated = true
            pending = Data()
            guard let marker = eventLine("o", Self.truncationMarker, at: at) else { return }
            append(marker)
            ptLog(.warning, "shell: a session's transcript reached its size limit; recording stopped")
            return
        }
        append(line)
    }

    private func eventLine(_ code: String, _ text: String, at: Date) -> Data? {
        let seconds = max(0, at.timeIntervalSince1970 - entry.startedAt)
        let event: [Any] = [seconds, code, text]
        return (try? JSONSerialization.data(withJSONObject: event)).map { $0 + Data("\n".utf8) }
    }

    private func append(_ line: Data) {
        guard let handle else { return }
        do {
            try handle.write(contentsOf: line)
            written += Int64(line.count)
        } catch {}
    }

    /// How many bytes at the end begin a multi-byte sequence the next chunk completes.
    private static func incompleteTailLength(_ bytes: Data) -> Int {
        guard !bytes.isEmpty else { return 0 }
        for back in 1...min(3, bytes.count) {
            let byte = bytes[bytes.endIndex - back]
            if byte & 0xC0 == 0x80 { continue }                  // continuation: keep looking for the lead
            let needed = byte >= 0xF0 ? 4 : byte >= 0xE0 ? 3 : byte >= 0xC0 ? 2 : 1
            return needed > back ? back : 0
        }
        return 0
    }
}
#endif
