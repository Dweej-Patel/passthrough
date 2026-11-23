#if canImport(AppKit)
import AppKit
import PassthroughCore

/// A viewer window's side of clipboard sync with the computer it shows: this
/// Mac's copies go there, that computer's land here, and files dropped on the
/// window are sent to be dropped there. `onStatus` gets a line to show for a
/// while (nil clears it), on the main thread.
@MainActor
public final class ClipSyncViewer {
    private let hostName: String
    private let onStatus: (String?) -> Void
    private var session: ClipSyncSession?
    private var watch: UUID?
    private let staging: URL
    private var clipboardFolders: [URL] = []
    /// Drops on their way, by transfer: how many items, for what's said when they land.
    private var drops: [UInt32: Int] = [:]
    private var clearStatus: DispatchWorkItem?

    public init(hostName: String, onStatus: @escaping (String?) -> Void) {
        self.hostName = hostName
        self.onStatus = onStatus
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        staging = caches.appendingPathComponent("Passthrough/Received/viewer-\(UUID().uuidString)", isDirectory: true)
    }

    public var isActive: Bool { session != nil }

    /// Syncs over `stream` (after `clipSyncReady`) until `stop()`.
    public func start(stream: any ByteStream, initialBytes: Data, ended: @escaping () -> Void) {
        stop()
        let session = ClipSyncSession(stream: stream, initialBytes: initialBytes, staging: staging) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event, ended: ended) }
        }
        self.session = session
        session.start()
        watch = ClipboardWatcher.shared.watch { [weak self] snapshot in self?.copied(snapshot, announce: true) }
        // What's on this Mac's clipboard now goes over once, unless it's files (an upload nobody asked for).
        ClipboardWatcher.shared.current { [weak self] snapshot in
            guard case let .payload(payload) = snapshot, !payload.hasFiles else { return }
            self?.copied(snapshot, announce: false)
        }
    }

    public func stop() {
        session?.close()
        session = nil
        if let watch { ClipboardWatcher.shared.unwatch(watch) }
        watch = nil
        drops = [:]
        try? FileManager.default.removeItem(at: staging)
        clipboardFolders = []
    }

    /// Files dropped on the window at (`x`, `y`), each 0…65535 across the stream.
    public func drop(_ urls: [URL], x: UInt16, y: UInt16) {
        guard let session else { return status("Clipboard sync isn't on, so files can't go to \(hostName).") }
        switch ClipPayload.files(urls) {
        case let .success(payload) where !payload.items.isEmpty:
            let id = session.send(payload, kind: .drop, x: x, y: y)
            let count = urls.count
            drops[id] = count
            status("Sending \(Self.files(count, payload.total)) to \(hostName)…", hold: true)
        default:
            status("Those files couldn't be read.")
        }
    }

    private func copied(_ snapshot: MacClipboard.Snapshot, announce: Bool) {
        switch snapshot {
        case let .payload(payload):
            session?.send(payload, kind: .clipboard)
            if announce, payload.hasFiles, payload.total > 20 << 20 {
                status("Copying \(Self.size(payload.total)) to \(hostName)…", hold: true)
            }
        case .tooLarge:
            if announce { status("Too large to sync (over 500 MB). Drag it onto the window instead.") }
        case .nothing:
            break
        }
    }

    private func handle(_ event: ClipSyncSession.Event, ended: @escaping () -> Void) {
        switch event {
        case let .received(transfer):
            switch transfer.kind {
            case .clipboard:
                ClipboardWatcher.shared.wrote(changeCount: MacClipboard.write(transfer))
                session?.result(transfer.transfer, .placed)
                if let folder = transfer.folder {
                    clipboardFolders.append(folder)
                    while clipboardFolders.count > 3 { try? FileManager.default.removeItem(at: clipboardFolders.removeFirst()) }
                    status("Copied \(Self.files(transfer.topLevel.count, nil)) from \(hostName).")
                }
            case .drop:
                // A host doesn't drop on its viewer.
                session?.result(transfer.transfer, .failed)
                if let folder = transfer.folder { try? FileManager.default.removeItem(at: folder) }
            }
        case let .incoming(_, kind, total) where kind == .clipboard && total > 20 << 20:
            status("Copying \(Self.size(total)) from \(hostName)…", hold: true)
        case let .sent(transfer):
            if let count = drops[transfer] { status("Dropping \(Self.files(count, nil)) on \(hostName)…", hold: true) }
        case let .result(transfer, result):
            guard let count = drops.removeValue(forKey: transfer) else { return }
            switch result {
            case .placed: status("Dropped \(Self.files(count, nil)) on \(hostName).")
            case .savedToDownloads: status("Nothing there took \(count == 1 ? "it" : "them"), so \(count == 1 ? "it's" : "they're") in \(hostName)'s Downloads.")
            case .failed: status("\(hostName) couldn't take \(count == 1 ? "that file" : "those files").")
            }
        case let .declined(transfer, reason):
            let what = drops.removeValue(forKey: transfer).map { Self.files($0, nil) } ?? "That copy"
            switch reason {
            case .tooLarge: status("\(what.prefix(1).uppercased() + what.dropFirst()) is too large for \(hostName).")
            case .noRoom: status("\(hostName) hasn't room for \(what.lowercased()).")
            case .syncOff: status("\(hostName) has clipboard sync turned off.")
            case .badOffer, .failed: status("\(what.prefix(1).uppercased() + what.dropFirst()) couldn't go to \(hostName).")
            }
        case .closed:
            session = nil
            if let watch { ClipboardWatcher.shared.unwatch(watch) }
            watch = nil
            ended()
        default:
            break
        }
    }

    private func status(_ text: String, hold: Bool = false) {
        clearStatus?.cancel()
        onStatus(text)
        guard !hold else { return }
        let clear = DispatchWorkItem { [weak self] in self?.onStatus(nil) }
        clearStatus = clear
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: clear)
    }

    static func files(_ count: Int, _ bytes: UInt64?) -> String {
        let n = count == 1 ? "1 item" : "\(count) items"
        guard let bytes, bytes > 0 else { return n }
        return "\(n) (\(size(bytes)))"
    }

    static func size(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file)
    }
}
#endif
