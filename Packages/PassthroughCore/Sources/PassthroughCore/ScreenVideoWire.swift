import Foundation

/// The Mac's own screen stream (protocol/README.md, "Screen video"): after
/// `screenVideoReady` the connection carries messages of one type byte, a
/// 4-byte big-endian payload length and the payload, both ways. The Mac
/// sends H.264 (its hardware encoder) and the phone acks each frame it has
/// shown, which is how the Mac keeps at most a couple of frames in flight.
public enum ScreenVideoWire {
    /// Largest payload either side accepts (a keyframe of a big screen fits easily).
    public static let maxPayload = 16 << 20

    public enum Message: Equatable, Sendable {
        // Mac → phone
        /// The stream's size in pixels and its H.264 parameter sets; sent before every keyframe.
        case format(width: Int, height: Int, sps: Data, pps: Data)
        /// One frame: AVCC NAL units (4-byte lengths), numbered from 1.
        case frame(number: UInt32, keyframe: Bool, data: Data)

        // Phone → Mac
        /// The phone's largest useful size in pixels; the Mac fits the stream inside it.
        case hello(maxWidth: Int, maxHeight: Int)
        /// Frame `number` is on the phone's screen.
        case ack(number: UInt32)
        /// The pointer at (`x`, `y`), each 0…65535 across the screen, with RFB-numbered `buttons` held.
        case pointer(x: UInt16, y: UInt16, buttons: UInt8)
        /// Scrolls by (`dx`, `dy`) of the Mac's points at the pointer; positive `dy` brings earlier content into view.
        case scroll(dx: Int16, dy: Int16)
        /// A key, by X keysym, pressed and released with `modifiers` (`Modifiers`) held.
        case key(keysym: UInt32, modifiers: UInt8)
        /// Text typed as it is, whatever the Mac's keyboard layout.
        case text(String)
        /// Puts text on the Mac's clipboard.
        case clipboard(String)
        /// The phone lost its place in the stream: send a keyframe.
        case keyframeRequest
    }

    public struct Modifiers: OptionSet, Sendable {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }
        public static let command = Modifiers(rawValue: 1)
        public static let shift = Modifiers(rawValue: 2)
        public static let option = Modifiers(rawValue: 4)
        public static let control = Modifiers(rawValue: 8)
    }

    enum Kind: UInt8 {
        case format = 1, frame = 2
        case hello = 16, ack = 17, pointer = 18, scroll = 19, key = 20, text = 21, clipboard = 22, keyframeRequest = 23
    }

    public enum Failure: Error, Equatable { case tooLarge, malformed }

    public static func encode(_ message: Message) -> Data {
        var payload = Data()
        let kind: Kind
        switch message {
        case let .format(width, height, sps, pps):
            kind = .format
            payload.append(u16: width); payload.append(u16: height)
            payload.append(u16: sps.count); payload.append(sps)
            payload.append(u16: pps.count); payload.append(pps)
        case let .frame(number, keyframe, data):
            kind = .frame
            payload.append(u32: number); payload.append(keyframe ? 1 : 0); payload.append(data)
        case let .hello(maxWidth, maxHeight):
            kind = .hello
            payload.append(u16: maxWidth); payload.append(u16: maxHeight)
        case let .ack(number):
            kind = .ack
            payload.append(u32: number)
        case let .pointer(x, y, buttons):
            kind = .pointer
            payload.append(u16: Int(x)); payload.append(u16: Int(y)); payload.append(buttons)
        case let .scroll(dx, dy):
            kind = .scroll
            payload.append(u16: Int(UInt16(bitPattern: dx))); payload.append(u16: Int(UInt16(bitPattern: dy)))
        case let .key(keysym, modifiers):
            kind = .key
            payload.append(u32: keysym); payload.append(modifiers)
        case let .text(text):
            kind = .text
            payload.append(Data(text.utf8))
        case let .clipboard(text):
            kind = .clipboard
            payload.append(Data(text.utf8))
        case .keyframeRequest:
            kind = .keyframeRequest
        }
        var out = Data([kind.rawValue])
        out.append(u32: UInt32(payload.count))
        out.append(payload)
        return out
    }

    /// Splits a byte stream into messages. Unknown types are skipped, so
    /// either side can add some later.
    public struct Reader: Sendable {
        private var buffer = Data()
        public init() {}

        /// The messages complete so far; throws on a payload over `maxPayload` or one that doesn't parse.
        public mutating func append(_ data: Data) throws -> [Message] {
            buffer.append(data)
            var messages: [Message] = []
            var offset = buffer.startIndex
            while buffer.endIndex - offset >= 5 {
                let length = Int(buffer.u32(at: offset + 1))
                guard length <= ScreenVideoWire.maxPayload else { throw Failure.tooLarge }
                guard buffer.endIndex - offset >= 5 + length else { break }
                let type = buffer[offset]
                let payload = buffer.subdata(in: (offset + 5)..<(offset + 5 + length))
                offset += 5 + length
                if let kind = Kind(rawValue: type) { messages.append(try ScreenVideoWire.decode(kind, payload)) }
            }
            buffer.removeSubrange(buffer.startIndex..<offset)
            return messages
        }
    }

    static func decode(_ kind: Kind, _ p: Data) throws -> Message {
        let b = p.startIndex
        func need(_ count: Int) throws { if p.count < count { throw Failure.malformed } }
        switch kind {
        case .format:
            try need(6)
            let spsLength = Int(p.u16(at: b + 4))
            try need(6 + spsLength + 2)
            let ppsLength = Int(p.u16(at: b + 6 + spsLength))
            try need(8 + spsLength + ppsLength)
            return .format(width: Int(p.u16(at: b)), height: Int(p.u16(at: b + 2)),
                           sps: p.subdata(in: (b + 6)..<(b + 6 + spsLength)),
                           pps: p.subdata(in: (b + 8 + spsLength)..<(b + 8 + spsLength + ppsLength)))
        case .frame:
            try need(5)
            return .frame(number: p.u32(at: b), keyframe: p[b + 4] & 1 != 0, data: p.subdata(in: (b + 5)..<p.endIndex))
        case .hello:
            try need(4)
            return .hello(maxWidth: Int(p.u16(at: b)), maxHeight: Int(p.u16(at: b + 2)))
        case .ack:
            try need(4)
            return .ack(number: p.u32(at: b))
        case .pointer:
            try need(5)
            return .pointer(x: p.u16(at: b), y: p.u16(at: b + 2), buttons: p[b + 4])
        case .scroll:
            try need(4)
            return .scroll(dx: Int16(bitPattern: p.u16(at: b)), dy: Int16(bitPattern: p.u16(at: b + 2)))
        case .key:
            try need(5)
            return .key(keysym: p.u32(at: b), modifiers: p[b + 4])
        case .text:
            return .text(String(decoding: p, as: UTF8.self))
        case .clipboard:
            return .clipboard(String(decoding: p, as: UTF8.self))
        case .keyframeRequest:
            return .keyframeRequest
        }
    }
}

private extension Data {
    mutating func append(u16 value: Int) {
        let v = UInt16(clamping: value)
        append(contentsOf: [UInt8(v >> 8), UInt8(v & 0xFF)])
    }

    mutating func append(u32 value: UInt32) {
        append(contentsOf: [UInt8(value >> 24), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)])
    }

    func u16(at index: Int) -> UInt16 { UInt16(self[index]) << 8 | UInt16(self[index + 1]) }

    func u32(at index: Int) -> UInt32 {
        UInt32(self[index]) << 24 | UInt32(self[index + 1]) << 16 | UInt32(self[index + 2]) << 8 | UInt32(self[index + 3])
    }
}
