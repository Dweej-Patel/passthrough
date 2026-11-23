import Foundation
import PassthroughCore

/// One side of clipboard sync over a stream (protocol/README.md, "Clipboard
/// sync"), the same for a host and a viewer: sends transfers as fast as the
/// stream takes them, takes the other side's into folders under `staging`,
/// and says what happened through `onEvent`, on `eventQueue`.
public final class ClipSyncSession: @unchecked Sendable {
    public enum Event: Sendable {
        /// The other side finished sending a transfer: it's complete and checked.
        /// Answer with `result`.
        case received(ReceivedTransfer)
        /// The other side won't take one of ours.
        case declined(transfer: UInt32, reason: ClipSyncWire.DeclineReason)
        /// What the other side did with one of ours.
        case result(transfer: UInt32, status: ClipSyncWire.ResultStatus)
        /// All of one of ours has gone out.
        case sent(transfer: UInt32)
        /// The other side began sending one: `total` bytes are coming.
        /// (`x`, `y`): a drop's point, for the receiver to note what's there now.
        case incoming(transfer: UInt32, kind: ClipSyncWire.Kind, total: UInt64, x: UInt16, y: UInt16)
        /// The other side stopped sending one, or it failed here.
        case incomingEnded(transfer: UInt32)
        /// The stream ended (nil: `close()`).
        case closed(Error?)
    }

    /// Bytes this side lets wait on the stream before it reads more from disk.
    static let inFlightLimit = 1 << 20
    /// Most items in a drop this side takes.
    public static let maxDropItems: UInt32 = 200_000
    /// Most transfers from the other side this side takes at once; past it, an offer is declined (2).
    public static let maxOpenIncoming = 4

    private let stream: any ByteStream
    private var initialBytes: Data
    private let staging: URL
    private let queue = DispatchQueue(label: "passthrough.clipsync")
    private let eventQueue: DispatchQueue
    private let onEvent: @Sendable (Event) -> Void
    private var reader = ClipSyncWire.Reader()
    private var closed = false
    private var started = false

    // Sending
    private var nextTransfer: UInt32 = 1
    private var outgoing: [Outgoing] = []
    private var inFlight = 0

    // Receiving
    private var incoming: [UInt32: Incoming] = [:]
    private var lastOffer: UInt32 = 0
    /// Whether the other side may drop files here (a host takes its viewers' drops; a viewer takes none).
    private let acceptsDrops: Bool

    /// `staging`: where the other side's files go, one folder per transfer.
    public init(stream: any ByteStream, initialBytes: Data = Data(), staging: URL, acceptsDrops: Bool = true,
                eventQueue: DispatchQueue = .main, onEvent: @escaping @Sendable (Event) -> Void) {
        self.acceptsDrops = acceptsDrops
        self.stream = stream
        self.initialBytes = initialBytes
        self.staging = staging
        self.eventQueue = eventQueue
        self.onEvent = onEvent
    }

    public func start() {
        queue.async { [self] in
            guard !started, !closed else { return }
            started = true
            stream.onTerminated = { [weak self] error in self?.queue.async { self?.end(error) } }
            write(.hello(version: ClipSyncWire.version))
            if !initialBytes.isEmpty {
                let bytes = initialBytes
                initialBytes = Data()
                take(bytes)
            }
            receive()
        }
    }

    /// Ends the session; the stream is cancelled. Idempotent.
    public func close() {
        queue.async { [self] in end(nil) }
    }

    // MARK: Sending

    /// Starts sending `payload`; returns its transfer number. A clipboard
    /// transfer abandons this side's previous unfinished one.
    @discardableResult
    public func send(_ payload: ClipPayload, kind: ClipSyncWire.Kind, x: UInt16 = 0, y: UInt16 = 0) -> UInt32 {
        queue.sync {
            let id = nextTransfer
            nextTransfer &+= 1
            guard !closed, !payload.items.isEmpty else { return id }
            if kind == .clipboard {
                for old in outgoing where old.offer.kind == .clipboard {
                    old.handle?.closeFile()
                    if old.offerSent { write(.abandon(transfer: old.offer.transfer)) }
                }
                outgoing.removeAll { $0.offer.kind == .clipboard }
            }
            let offer = ClipSyncWire.Offer(transfer: id, kind: kind, x: x, y: y, count: UInt32(payload.items.count), total: payload.total)
            outgoing.append(Outgoing(offer: offer, items: payload.items))
            pump()
            return id
        }
    }

    /// Tells the other side what became of its transfer.
    public func result(_ transfer: UInt32, _ status: ClipSyncWire.ResultStatus) {
        queue.async { [self] in
            guard !closed else { return }
            write(.result(transfer: transfer, status: status))
        }
    }

    private final class Outgoing {
        let offer: ClipSyncWire.Offer
        let items: [ClipPayload.Item]
        var offerSent = false
        var index = 0
        var announced = false
        var sentOfItem: UInt64 = 0
        var handle: FileHandle?

        init(offer: ClipSyncWire.Offer, items: [ClipPayload.Item]) {
            self.offer = offer
            self.items = items
        }
    }

    /// Writes what's next while under `inFlightLimit`: clipboard transfers before drops.
    private func pump() {
        while !closed, inFlight < Self.inFlightLimit {
            guard let t = outgoing.first(where: { $0.offer.kind == .clipboard }) ?? outgoing.first else { return }
            if !t.offerSent {
                t.offerSent = true
                write(.offer(t.offer))
                continue
            }
            guard t.index < t.items.count else {
                write(.done(transfer: t.offer.transfer))
                finishOutgoing(t)
                emit(.sent(transfer: t.offer.transfer))
                continue
            }
            let item = t.items[t.index]
            if !t.announced {
                t.announced = true
                t.sentOfItem = 0
                write(.item(transfer: t.offer.transfer, index: UInt32(t.index),
                            ClipSyncWire.Item(format: item.format, size: item.size, name: item.name)))
                if case let .file(url) = item.content, item.size > 0 {
                    guard let handle = try? FileHandle(forReadingFrom: url) else { abandon(t); continue }
                    t.handle = handle
                }
                continue
            }
            let left = item.size - t.sentOfItem
            guard left > 0 else {
                // A file that grew since it was offered isn't cut short without a word: abandoned.
                if case .file = item.content, let handle = t.handle, let more = try? handle.read(upToCount: 1), !more.isEmpty {
                    abandon(t)
                    continue
                }
                t.handle?.closeFile()
                t.handle = nil
                t.index += 1
                t.announced = false
                continue
            }
            let n = Int(min(left, UInt64(ClipSyncWire.maxChunk)))
            let chunk: Data
            switch item.content {
            case let .data(data):
                let start = data.startIndex + Int(t.sentOfItem)
                chunk = data[start..<(start + n)]
            case .file:
                // Exactly `size` bytes, or the transfer is abandoned: a file that shrank isn't padded.
                guard let handle = t.handle, let read = try? handle.read(upToCount: n), read.count == n else { abandon(t); continue }
                chunk = read
            case .folder:
                chunk = Data()
            }
            t.sentOfItem += UInt64(n)
            write(.data(transfer: t.offer.transfer, item: UInt32(t.index), bytes: Data(chunk)))
        }
    }

    private func abandon(_ t: Outgoing) {
        write(.abandon(transfer: t.offer.transfer))
        finishOutgoing(t)
        emit(.declined(transfer: t.offer.transfer, reason: .failed))
    }

    private func finishOutgoing(_ t: Outgoing) {
        t.handle?.closeFile()
        t.handle = nil
        outgoing.removeAll { $0 === t }
    }

    private func write(_ message: ClipSyncWire.Message) {
        let bytes = ClipSyncWire.encode(message)
        inFlight += bytes.count
        stream.send(bytes, isComplete: false) { [weak self] error in
            guard let self else { return }
            self.queue.async {
                self.inFlight -= bytes.count
                if let error { return self.end(error) }
                self.pump()
            }
        }
    }

    // MARK: Receiving

    private final class Incoming {
        var check: ClipSyncWire.ItemCheck
        var folder: URL?
        var items: [ReceivedTransfer.Item] = []
        /// The item now being received (its number on the wire, and where it is in `items`:
        /// nil for a format this side doesn't know), its size and how much has come.
        var current: UInt32?
        var slot: Int?
        var size: UInt64 = 0
        var got: UInt64 = 0
        var inline: Data?
        var handle: FileHandle?
        /// Bytes taken so far, all items.
        var written: UInt64 = 0

        init(_ offer: ClipSyncWire.Offer) { check = ClipSyncWire.ItemCheck(offer) }
        var offer: ClipSyncWire.Offer { check.offer }
    }

    private func receive() {
        stream.receive(maximumLength: 256 << 10) { [weak self] data, complete, error in
            guard let self else { return }
            self.queue.async {
                guard !self.closed else { return }
                if let data, !data.isEmpty { self.take(data) }
                if self.closed { return }
                if let error { return self.end(error) }
                if complete { return self.end(nil) }
                self.receive()
            }
        }
    }

    private func take(_ data: Data) {
        let messages: [ClipSyncWire.Message]
        do { messages = try reader.append(data) } catch { return end(error) }
        for message in messages {
            handle(message)
            if closed { return }
        }
    }

    private func handle(_ message: ClipSyncWire.Message) {
        switch message {
        case .hello, .unknown:
            break
        case let .offer(offer):
            offered(offer)
        case let .unknownOffer(transfer):
            // A kind this side can't do: declined, and nothing else changes.
            guard transfer > lastOffer else { return }
            lastOffer = transfer
            write(.decline(transfer: transfer, reason: .badOffer))
        case let .item(transfer, index, item):
            guard let t = incoming[transfer] else { return }
            if let reason = t.check.refusal(of: item, index: index) ?? completeCurrent(t) { return decline(t, reason) }
            begin(item, index: index, in: t)
        case let .data(transfer, item, bytes):
            guard let t = incoming[transfer] else { return }
            guard t.current == item, UInt64(bytes.count) <= t.size - t.got else { return decline(t, .badOffer) }
            t.got += UInt64(bytes.count)
            t.written += UInt64(bytes.count)
            if t.inline != nil {
                t.inline!.append(bytes)
            } else if let handle = t.handle {
                do { try handle.write(contentsOf: bytes) } catch { return decline(t, .noRoom) }
            }
        case let .done(transfer):
            guard let t = incoming[transfer] else { return }
            if let reason = completeCurrent(t) { return decline(t, reason) }
            guard t.check.isComplete else { return decline(t, .badOffer) }
            incoming[transfer] = nil
            emit(.received(ReceivedTransfer(transfer: transfer, kind: t.offer.kind, x: t.offer.x, y: t.offer.y,
                                            items: t.items, folder: t.folder)))
        case let .abandon(transfer):
            guard let t = incoming.removeValue(forKey: transfer) else { return }
            discard(t)
            emit(.incomingEnded(transfer: transfer))
        case let .decline(transfer, reason):
            if let t = outgoing.first(where: { $0.offer.transfer == transfer }) { finishOutgoing(t) }
            emit(.declined(transfer: transfer, reason: reason))
        case let .result(transfer, status):
            emit(.result(transfer: transfer, status: status))
        }
    }

    private func offered(_ offer: ClipSyncWire.Offer) {
        // Numbers only go up: an old or repeated one is ignored.
        guard offer.transfer > lastOffer else { return }
        lastOffer = offer.transfer
        if offer.kind == .clipboard {
            // A newer copy replaces one still coming.
            for (id, t) in incoming where t.offer.kind == .clipboard {
                incoming[id] = nil
                discard(t)
                emit(.incomingEnded(transfer: id))
            }
        }
        // Free space less what transfers already coming may still write.
        let committed = incoming.values.reduce(UInt64(0)) { $0 &+ ($1.offer.total - min($1.written, $1.offer.total)) }
        let room = self.room().map { $0 > committed ? $0 - committed : 0 }
        let reason: ClipSyncWire.DeclineReason? = if offer.kind == .drop && !acceptsDrops {
            .badOffer
        } else if incoming.count >= Self.maxOpenIncoming {
            .noRoom
        } else {
            ClipSyncWire.refusal(of: offer, room: room, maxItems: Self.maxDropItems)
        }
        if let reason {
            write(.decline(transfer: offer.transfer, reason: reason))
            return
        }
        incoming[offer.transfer] = Incoming(offer)
        emit(.incoming(transfer: offer.transfer, kind: offer.kind, total: offer.total, x: offer.x, y: offer.y))
    }

    /// Why the item being received isn't whole, or nil (also with none).
    private func completeCurrent(_ t: Incoming) -> ClipSyncWire.DeclineReason? {
        guard t.current != nil else { return nil }
        guard t.got == t.size else { return .badOffer }
        t.handle?.closeFile()
        t.handle = nil
        if let slot = t.slot, let inline = t.inline { t.items[slot].data = inline }
        t.inline = nil
        t.current = nil
        t.slot = nil
        return nil
    }

    private func begin(_ item: ClipSyncWire.Item, index: UInt32, in t: Incoming) {
        t.size = item.size
        t.got = 0
        t.current = index
        // Unknown: its bytes are counted and dropped.
        guard let format = item.format else { return }
        t.slot = t.items.count
        if format.isFile {
            guard let folder = folder(for: t) else { return decline(t, .failed) }
            let url = folder.appendingPathComponent(item.name, isDirectory: format == .folder)
            // Names are checked already; this is the last word on where a file may go.
            guard url.standardizedFileURL.path.hasPrefix(folder.standardizedFileURL.path + "/") else { return decline(t, .badOffer) }
            do {
                if format == .folder {
                    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
                } else {
                    guard FileManager.default.createFile(atPath: url.path, contents: nil) else { return decline(t, .failed) }
                    t.handle = try FileHandle(forWritingTo: url)
                }
            } catch {
                return decline(t, .failed)
            }
            t.items.append(ReceivedTransfer.Item(format: format, name: item.name, data: nil, url: url))
        } else {
            // Inline formats are held in memory, so they're held to the clipboard's sizes whatever the kind.
            let cap = format == .png ? ClipSyncWire.maxClipboardImage : ClipSyncWire.maxClipboardText
            guard item.size <= cap else { return decline(t, .tooLarge) }
            // Grown as bytes come, not reserved on the sender's word.
            t.inline = Data()
            t.items.append(ReceivedTransfer.Item(format: format, name: "", data: nil, url: nil))
        }
    }

    private func folder(for t: Incoming) -> URL? {
        if let folder = t.folder { return folder }
        let folder = staging.appendingPathComponent(UUID().uuidString, isDirectory: true)
        do { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) } catch { return nil }
        t.folder = folder
        return folder
    }

    private func decline(_ t: Incoming, _ reason: ClipSyncWire.DeclineReason) {
        incoming[t.offer.transfer] = nil
        discard(t)
        write(.decline(transfer: t.offer.transfer, reason: reason))
        emit(.incomingEnded(transfer: t.offer.transfer))
    }

    private func discard(_ t: Incoming) {
        t.handle?.closeFile()
        t.handle = nil
        if let folder = t.folder { try? FileManager.default.removeItem(at: folder) }
    }

    private func room() -> UInt64? {
        try? FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        guard let values = try? staging.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
              let free = values.volumeAvailableCapacityForImportantUsage, free > 0 else { return nil }
        // Leave some for everything else.
        let margin: Int64 = 1 << 30
        return UInt64(max(free - margin, 0))
    }

    // MARK: Ending

    private func end(_ error: Error?) {
        guard !closed else { return }
        closed = true
        for t in outgoing { t.handle?.closeFile() }
        outgoing.removeAll()
        for t in incoming.values { discard(t) }
        incoming.removeAll()
        stream.onTerminated = nil
        stream.cancel()
        emit(.closed(error))
    }

    private func emit(_ event: Event) {
        let onEvent = self.onEvent
        eventQueue.async { onEvent(event) }
    }
}
