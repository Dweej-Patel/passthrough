import Foundation

/// Clipboard sync between computers (protocol/README.md, "Clipboard sync"):
/// after `clipSyncReady` the connection carries messages of one type byte, a
/// 4-byte big-endian payload length and the payload, both ways, the same in
/// each direction. A copy or a drop is a transfer: an `offer` naming its
/// items, their bytes as `data` in order, then `done`.
public enum ClipSyncWire {
    public static let version: UInt8 = 1
    /// Largest payload either side takes; a larger one ends the connection.
    public static let maxPayload = (1 << 20) + 64
    /// Most bytes in one `data` message.
    public static let maxChunk = 256 << 10
    public static let maxItems = 10_000
    public static let maxNameBytes = 1024
    public static let maxNamePartBytes = 255
    /// Clipboard transfers only: text, RTF and HTML each, PNG, files and folders in all.
    public static let maxClipboardText: UInt64 = 16 << 20
    public static let maxClipboardImage: UInt64 = 64 << 20
    public static let maxClipboardFiles: UInt64 = 500_000_000

    public enum Kind: UInt8, Sendable { case clipboard = 0, drop = 1 }

    public enum Format: UInt8, Sendable, CaseIterable {
        case text = 1, rtf = 2, html = 3, png = 4
        case file = 16, folder = 17

        public var isFile: Bool { self == .file || self == .folder }
    }

    public enum DeclineReason: UInt8, Sendable {
        case tooLarge = 1, noRoom = 2, syncOff = 3, badOffer = 4, failed = 5
    }

    public enum ResultStatus: UInt8, Sendable {
        case placed = 0, savedToDownloads = 1, failed = 2
    }

    /// One item of an offer. `format` nil: one this side doesn't know (its bytes are skipped).
    public struct Item: Equatable, Sendable {
        public var format: Format?
        public var rawFormat: UInt8
        public var size: UInt64
        /// The relative path, for files and folders; empty otherwise.
        public var name: String

        public init(format: Format, size: UInt64, name: String = "") {
            self.format = format
            self.rawFormat = format.rawValue
            self.size = size
            self.name = name
        }

        init(rawFormat: UInt8, size: UInt64, name: String) {
            self.format = Format(rawValue: rawFormat)
            self.rawFormat = rawFormat
            self.size = size
            self.name = name
        }
    }

    /// A transfer's header: its items follow, each as `item` just before its `data`.
    public struct Offer: Equatable, Sendable {
        public var transfer: UInt32
        public var kind: Kind
        /// For drops: where, 0…65535 across the stream (as `ScreenVideoWire`'s pointer).
        public var x: UInt16
        public var y: UInt16
        public var count: UInt32
        public var total: UInt64

        public init(transfer: UInt32, kind: Kind, x: UInt16 = 0, y: UInt16 = 0, count: UInt32, total: UInt64) {
            self.transfer = transfer
            self.kind = kind
            self.x = x
            self.y = y
            self.count = count
            self.total = total
        }
    }

    public enum Message: Equatable, Sendable {
        case hello(version: UInt8)
        case offer(Offer)
        /// Item `index` (from 0) of a transfer, sent just before its `data`.
        case item(transfer: UInt32, index: UInt32, Item)
        case data(transfer: UInt32, item: UInt32, bytes: Data)
        case done(transfer: UInt32)
        case abandon(transfer: UInt32)
        case decline(transfer: UInt32, reason: DeclineReason)
        case result(transfer: UInt32, status: ResultStatus)
        /// An offer of a kind this side doesn't know: declined (4), nothing else changes.
        case unknownOffer(transfer: UInt32)
        /// A type this side doesn't know, or a payload it can't read: skipped.
        case unknown(type: UInt8)
    }

    enum MessageType: UInt8 {
        case hello = 1, offer = 2, data = 3, done = 4, abandon = 5, decline = 6, result = 7, item = 8
    }

    public enum WireError: Error, Equatable {
        case payloadTooLarge
    }

    // MARK: Encoding

    public static func encode(_ message: Message) -> Data {
        var p = Data()
        let type: MessageType
        switch message {
        case let .hello(version):
            type = .hello
            p.append(version)
            p.append(0)
        case let .offer(offer):
            type = .offer
            p.appendBE(offer.transfer)
            p.append(offer.kind.rawValue)
            p.appendBE(offer.x)
            p.appendBE(offer.y)
            p.appendBE(offer.count)
            p.appendBE(offer.total)
        case let .item(transfer, index, item):
            type = .item
            let name = Data(item.name.utf8).prefix(Int(UInt16.max))
            p.appendBE(transfer)
            p.appendBE(index)
            p.append(item.rawFormat)
            p.appendBE(item.size)
            p.appendBE(UInt16(name.count))
            p.append(name)
        case let .data(transfer, item, bytes):
            type = .data
            p.appendBE(transfer)
            p.appendBE(item)
            p.append(bytes)
        case let .done(transfer):
            type = .done
            p.appendBE(transfer)
        case let .abandon(transfer):
            type = .abandon
            p.appendBE(transfer)
        case let .decline(transfer, reason):
            type = .decline
            p.appendBE(transfer)
            p.append(reason.rawValue)
        case let .result(transfer, status):
            type = .result
            p.appendBE(transfer)
            p.append(status.rawValue)
        case .unknown, .unknownOffer:
            return Data()
        }
        var out = Data([type.rawValue])
        out.appendBE(UInt32(p.count))
        out.append(p)
        return out
    }

    // MARK: Decoding

    /// Splits bytes as they arrive into messages.
    public struct Reader: Sendable {
        private var buffer = Data()
        public init() {}

        public mutating func append(_ data: Data) throws -> [Message] {
            buffer.append(data)
            var out: [Message] = []
            while buffer.count >= 5 {
                let start = buffer.startIndex
                let type = buffer[start]
                let length = Int(buffer.readBE32(at: start + 1))
                guard length <= ClipSyncWire.maxPayload else { throw WireError.payloadTooLarge }
                guard buffer.count >= 5 + length else { break }
                let payload = Data(buffer[(start + 5)..<(start + 5 + length)])
                buffer.removeFirst(5 + length)
                out.append(ClipSyncWire.decode(type: type, payload: payload))
            }
            // Keep the buffer's indices small.
            if buffer.isEmpty { buffer = Data() }
            return out
        }
    }

    static func decode(type raw: UInt8, payload p: Data) -> Message {
        guard let type = MessageType(rawValue: raw) else { return .unknown(type: raw) }
        var r = ByteReader(p)
        switch type {
        case .hello:
            guard let v = r.u8() else { return .unknown(type: raw) }
            return .hello(version: v)
        case .offer:
            guard let transfer = r.u32(), let kindRaw = r.u8(), let x = r.u16(), let y = r.u16(),
                  let count = r.u32(), let total = r.u64() else { return .unknown(type: raw) }
            guard let kind = Kind(rawValue: kindRaw) else { return .unknownOffer(transfer: transfer) }
            return .offer(Offer(transfer: transfer, kind: kind, x: x, y: y, count: count, total: total))
        case .item:
            guard let transfer = r.u32(), let index = r.u32(), let format = r.u8(), let size = r.u64(),
                  let nameLength = r.u16(), let nameBytes = r.bytes(Int(nameLength)) else { return .unknown(type: raw) }
            // Not UTF-8: a name no check passes.
            let name = String(data: nameBytes, encoding: .utf8) ?? "\u{0}"
            return .item(transfer: transfer, index: index, Item(rawFormat: format, size: size, name: name))
        case .data:
            guard let transfer = r.u32(), let item = r.u32() else { return .unknown(type: raw) }
            return .data(transfer: transfer, item: item, bytes: r.rest())
        case .done:
            guard let t = r.u32() else { return .unknown(type: raw) }
            return .done(transfer: t)
        case .abandon:
            guard let t = r.u32() else { return .unknown(type: raw) }
            return .abandon(transfer: t)
        case .decline:
            guard let t = r.u32(), let reason = r.u8() else { return .unknown(type: raw) }
            return .decline(transfer: t, reason: DeclineReason(rawValue: reason) ?? .failed)
        case .result:
            guard let t = r.u32(), let status = r.u8() else { return .unknown(type: raw) }
            return .result(transfer: t, status: ResultStatus(rawValue: status) ?? .failed)
        }
    }

    // MARK: Checks

    /// Whether `name` is a relative path this side will make: parts separated
    /// by the `/` code point (whatever follows it: a combining mark after `/`
    /// makes one Swift `Character` but is still a separator to the file
    /// system), none empty, `.` or `..`, none with NUL, `\`, `:` or control
    /// characters, each at most 255 UTF-8 bytes and all at most 1024.
    public static func isValidName(_ name: String) -> Bool {
        let bytes = name.utf8
        guard !bytes.isEmpty, bytes.count <= maxNameBytes else { return false }
        for part in parts(of: name) {
            let s = String(Substring(part))
            guard !part.isEmpty, s.utf8.count <= maxNamePartBytes, s != ".", s != ".." else { return false }
            for scalar in part {
                let v = scalar.value
                if v < 0x20 || v == 0x7F || (0x80...0x9F).contains(v) || scalar == "\\" || scalar == ":" { return false }
            }
        }
        return true
    }

    /// A name's parts, split on the `/` code point.
    static func parts(of name: String) -> [Substring.UnicodeScalarView] {
        name.unicodeScalars[...].split(separator: "/", omittingEmptySubsequences: false)
    }

    /// The folder a name is in (code-point split, as `isValidName`), or nil at the top.
    public static func parent(of name: String) -> String? {
        guard let slash = name.unicodeScalars.lastIndex(of: "/") else { return nil }
        return String(name.unicodeScalars[..<slash])
    }

    /// Most items in a drop either side takes.
    public static let maxDropItems: UInt32 = 50_000

    /// Why a transfer's header can't be taken, or nil. `room`: bytes free where files go.
    public static func refusal(of offer: Offer, room: UInt64? = nil, maxItems itemCap: UInt32 = maxDropItems) -> DeclineReason? {
        let cap = offer.kind == .clipboard ? UInt32(maxItems) : itemCap
        guard offer.count > 0 else { return .badOffer }
        guard offer.count <= cap else { return .tooLarge }
        if offer.kind == .clipboard, offer.total > maxClipboardFiles + 2 * maxClipboardText + maxClipboardImage { return .tooLarge }
        if let room, offer.total > room { return .noRoom }
        return nil
    }

    /// Checks a transfer's items as they come (`item`), and at `done` that
    /// they were all there: in order, sizes within the total, files only or
    /// none, each name once (as any case-insensitive file system sees them),
    /// every folder before what's in it, within the clipboard's limits.
    public struct ItemCheck: Sendable {
        public let offer: Offer
        public private(set) var next: UInt32 = 0
        public private(set) var sum: UInt64 = 0
        private var hasFiles = false
        private var hasOther = false
        private var formats = Set<UInt8>()
        private var names = Set<String>()
        private var folders = Set<String>()

        public init(_ offer: Offer) { self.offer = offer }

        /// Why `item`, announced as `index`, can't be taken, or nil.
        public mutating func refusal(of item: Item, index: UInt32) -> DeclineReason? {
            guard index == next, index < offer.count else { return .badOffer }
            let (total, overflow) = sum.addingReportingOverflow(item.size)
            guard !overflow, total <= offer.total else { return .badOffer }
            if let format = item.format {
                if format.isFile {
                    guard !hasOther, ClipSyncWire.isValidName(item.name) else { return .badOffer }
                    let key = item.name.precomposedStringWithCanonicalMapping.lowercased()
                    if let parent = ClipSyncWire.parent(of: key), !folders.contains(parent) { return .badOffer }
                    guard !names.contains(key) else { return .badOffer }
                    if format == .folder {
                        guard item.size == 0 else { return .badOffer }
                        folders.insert(key)
                    }
                    names.insert(key)
                    hasFiles = true
                } else {
                    guard !hasFiles, item.name.isEmpty, formats.insert(format.rawValue).inserted else { return .badOffer }
                    hasOther = true
                }
                if offer.kind == .clipboard {
                    switch format {
                    case .text, .rtf, .html: if item.size > maxClipboardText { return .tooLarge }
                    case .png: if item.size > maxClipboardImage { return .tooLarge }
                    case .file, .folder: if total > maxClipboardFiles { return .tooLarge }
                    }
                }
            }
            next += 1
            sum = total
            return nil
        }

        /// At `done`: every item announced, and the sizes exactly the total.
        public var isComplete: Bool { next == offer.count && sum == offer.total }
    }
}

// MARK: - Bytes

struct ByteReader {
    private let data: Data
    private var offset: Int

    init(_ data: Data) {
        self.data = data
        self.offset = data.startIndex
    }

    mutating func u8() -> UInt8? {
        guard offset < data.endIndex else { return nil }
        defer { offset += 1 }
        return data[offset]
    }

    mutating func u16() -> UInt16? {
        guard let b = bytes(2) else { return nil }
        return UInt16(b[b.startIndex]) << 8 | UInt16(b[b.startIndex + 1])
    }

    mutating func u32() -> UInt32? {
        guard let b = bytes(4) else { return nil }
        return b.reduce(0) { $0 << 8 | UInt32($1) }
    }

    mutating func u64() -> UInt64? {
        guard let b = bytes(8) else { return nil }
        return b.reduce(0) { $0 << 8 | UInt64($1) }
    }

    mutating func bytes(_ n: Int) -> Data? {
        guard n >= 0, data.endIndex - offset >= n else { return nil }
        defer { offset += n }
        return data[offset..<(offset + n)]
    }

    mutating func rest() -> Data {
        defer { offset = data.endIndex }
        return Data(data[offset...])
    }
}

extension Data {
    mutating func appendBE(_ v: UInt16) { append(contentsOf: [UInt8(v >> 8), UInt8(v & 0xFF)]) }
    mutating func appendBE(_ v: UInt32) { append(contentsOf: (0..<4).reversed().map { UInt8((v >> ($0 * 8)) & 0xFF) }) }
    mutating func appendBE(_ v: UInt64) { append(contentsOf: (0..<8).reversed().map { UInt8((v >> (UInt64($0) * 8)) & 0xFF) }) }

    func readBE32(at i: Index) -> UInt32 {
        UInt32(self[i]) << 24 | UInt32(self[i + 1]) << 16 | UInt32(self[i + 2]) << 8 | UInt32(self[i + 3])
    }
}
