import Foundation

/// The Mac's own screen stream (protocol/README.md, "Screen video"): after
/// `screenVideoReady` the connection carries messages of one type byte, a
/// 4-byte big-endian payload length and the payload, both ways. The Mac
/// sends HEVC or H.264 (its hardware encoder; HEVC when the phone decodes
/// it, for fewer bits at the same quality) and the phone acks each frame it has
/// shown, which is how the Mac paces what it sends to the round trip (as
/// many frames in flight as fit in it). The pointer isn't in the picture:
/// the Mac sends where it is and what it looks like, and the phone draws it.
public enum ScreenVideoWire {
    /// Largest payload either side accepts (a keyframe of a big screen fits easily).
    public static let maxPayload = 16 << 20
    /// Largest payloads the Mac takes from a phone (`Reader(from: .phone)`),
    /// so a phone cannot make it buffer 16 MiB of input: one `text` message
    /// (longer text goes in several, `textPieces`), one `clipboard`, and
    /// every fixed-size event.
    public static let maxTextPayload = 4 << 10
    public static let maxClipboardPayload = 64 << 10
    static let maxEventPayload = 64
    /// Text up to this many UTF-16 units the Mac types as key presses, which apps
    /// that read keys (Windows App's RDP, virtual machines, games) get right too.
    /// The phone pastes longer text through the clipboard; longer text that does
    /// come as `text` is typed as characters, at once.
    public static let typedAsKeys = 64
    /// A phone's voice (`voice`): 16-bit little-endian mono samples at `voiceSampleRate`,
    /// at most `maxVoicePayload` bytes a message (a quarter of a second; the phone sends 20 ms).
    public static let voiceSampleRate = 16_000
    public static let maxVoicePayload = 8 << 10

    /// Who wrote the bytes a `Reader` splits, which sets how large each payload may be.
    public enum Sender: Sendable { case mac, phone }

    public enum Message: Equatable, Sendable {
        // Mac → phone
        /// The stream's codec, size in pixels and parameter sets (H.264: SPS, PPS;
        /// HEVC: VPS, SPS, PPS); sent before every keyframe.
        case format(codec: Codec, width: Int, height: Int, parameterSets: [Data])
        /// One frame: NAL units after 4-byte lengths (AVCC, or HVCC for HEVC), numbered from 1.
        case frame(number: UInt32, keyframe: Bool, data: Data)
        /// The answer to `copy`.
        case copied(CopyResult)
        /// The answer to `curtain`: whether the Mac's displays are hidden now.
        case curtained(Bool)
        /// What the stream after this shows, sent with each new capture (a `hello`
        /// that changes what's captured, or the link changing its size): the Mac's
        /// own display, or one shaped like the phone. `mac` when the phone
        /// asked for `device` means the Mac couldn't make one.
        case fitted(Fit)
        /// The Mac's pointer at (`x`, `y`), each 0…65535 across the stream, or
        /// not on the streamed display (`visible` false). Sent when it moves.
        case cursor(x: UInt16, y: UInt16, visible: Bool)
        /// What the pointer looks like: a PNG drawn `width`×`height` stream
        /// pixels, its tip at (`hotX`, `hotY`) in them. Sent when it changes.
        case cursorShape(width: Int, height: Int, hotX: Int, hotY: Int, png: Data)
        /// The other devices viewing this Mac's screen now, by name; sent when that changes.
        case viewers([String])
        /// Another device took this view over (`useHere`): the stream ends after this.
        case movedAway(to: String)
        /// The answer to `microphone`, and again if that changes: whether the Mac takes the phone's voice now.
        case microphoneState(MicrophoneState)

        // Phone → Mac
        /// What the phone wants to see (`Hello`), first and again whenever that changes.
        case hello(Hello)
        /// Frame `number` is on the phone's screen.
        case ack(number: UInt32)
        /// The pointer at (`x`, `y`), each 0…65535 across the screen, with RFB-numbered `buttons` held.
        case pointer(x: UInt16, y: UInt16, buttons: UInt8)
        /// Scrolls by (`dx`, `dy`) of the stream's pixels at the pointer (the Mac turns them into its
        /// points, so content follows the fingers at any stream size); positive `dy` brings earlier content into view.
        case scroll(dx: Int16, dy: Int16)
        /// A key, by X keysym, pressed and released with `modifiers` (`Modifiers`) held.
        case key(keysym: UInt32, modifiers: UInt8)
        /// Text typed as it is, whatever the Mac's keyboard layout.
        case text(String)
        /// Puts text on the Mac's clipboard.
        case clipboard(String)
        /// The phone lost its place in the stream: send a keyframe.
        case keyframeRequest
        /// Press ⌘C on the Mac and answer with what it copied (`copied`).
        case copy
        /// Hide what the Mac's own displays show (black, to anyone at the Mac) while
        /// this stream goes on showing it, or show it again; answered with `curtained`.
        case curtain(Bool)
        /// End every other device's view of this Mac (they get `movedAway`): this one is used here now.
        case useHere
        /// A trackpad pinch or rotation at the pointer, as the Mac's own trackpad
        /// sends them: `value` is the change since the last one (magnification, or
        /// degrees counterclockwise), 0 on `began` and `ended`.
        case gesture(Gesture, phase: GesturePhase, value: Double)
        /// Be this Mac's microphone (the "Passthrough Microphone" input device), or stop;
        /// answered with `microphoneState`. Voice is sent only once that says `on`.
        case microphone(Bool)
        /// What the phone's microphone heard next (`voiceSampleRate`), played to that device as it comes.
        case voice(Data)
        /// The Fn (globe) key goes down, or comes up: held for as long as the phone's key is,
        /// as apps that listen for it held (push-to-talk dictation) need.
        case function(Bool)
    }

    /// Whether the Mac takes a phone's voice.
    public enum MicrophoneState: UInt8, Equatable, Sendable {
        case off = 0
        /// The Mac's microphone device records what the phone sends.
        case on = 1
        /// The Mac has no "Passthrough Microphone" device: it is turned on in the Mac app's settings.
        case notInstalled = 2
        /// The device is there but couldn't be played to.
        case failed = 3
    }

    public enum Gesture: UInt8, Equatable, Sendable {
        case magnify = 0
        case rotate = 1
    }

    /// As macOS numbers a gesture's phases.
    public enum GesturePhase: UInt8, Equatable, Sendable {
        case began = 1
        case changed = 2
        case ended = 4
        case cancelled = 8
    }

    /// What a phone asks to see.
    public struct Hello: Equatable, Sendable {
        /// `mac`: the Mac's own display, fitted inside `width`×`height` pixels.
        /// `device`: a stream of exactly `width`×`height` pixels of a display made for the phone.
        public var width: Int
        public var height: Int
        public var fit: Fit
        /// What the phone decodes; the Mac picks one.
        public var codecs: Codecs
        /// Frames a second the phone shows at most (60, or 120 on ProMotion).
        public var fps: Int
        public var quality: Quality
        /// `device` only: the display's size against the stream's, in percent.
        /// 100: one Mac point to two of the phone's pixels. Under: bigger text
        /// (the picture is scaled up a little); over: more room (scaled down).
        public var space: Int

        public init(width: Int, height: Int, fit: Fit = .mac, codecs: Codecs = .h264, fps: Int = 60,
                    quality: Quality = .sharp, space: Int = 100) {
            self.width = width
            self.height = height
            self.fit = fit
            self.codecs = codecs
            self.fps = fps
            self.quality = quality
            self.space = space
        }
    }

    /// What matters most when the link can't carry it all.
    public enum Quality: UInt8, Equatable, Sendable {
        /// Crisp text: up to 60 frames a second, the size kept as long as it can be.
        case sharp = 0
        /// Crisp text at up to the phone's frame rate (120 on ProMotion).
        case smooth = 1
        /// Motion first: the phone's frame rate, a slightly smaller (softer) picture.
        case fast = 2
    }

    /// What a `copy` found. Only what that ⌘C put on the Mac's clipboard is
    /// sent: a clipboard that didn't change is `nothing`, never what was on
    /// it before (a password copied on the Mac, say).
    public enum CopyResult: Equatable, Sendable {
        case text(String)
        /// The clipboard didn't change: nothing was selected, or the app doesn't copy.
        case nothing
        /// Text longer than `maxClipboardPayload`.
        case tooLong
        /// Something that isn't text (an image, a file).
        case notText
    }

    public enum Codec: UInt8, Equatable, Sendable {
        case h264 = 0
        case hevc = 1
    }

    /// The codecs a phone decodes.
    public struct Codecs: OptionSet, Equatable, Sendable {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }
        public static let h264 = Codecs(rawValue: 1)
        public static let hevc = Codecs(rawValue: 2)
    }

    /// Which display the stream shows.
    public enum Fit: UInt8, Equatable, Sendable {
        /// The Mac's own (main) display, as it is.
        case mac = 0
        /// A display the Mac makes in the phone's shape and size, which its own displays mirror while it lasts.
        case device = 1
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
        case format = 1, frame = 2, copied = 3, curtained = 4, fitted = 5, cursor = 6, cursorShape = 7, viewers = 8, movedAway = 9
        case hello = 16, ack = 17, pointer = 18, scroll = 19, key = 20, text = 21, clipboard = 22, keyframeRequest = 23, copy = 24, curtain = 25
        case useHere = 26, gesture = 27, microphone = 28, voice = 29, function = 30
        case microphoneState = 10
    }

    public enum Failure: Error, Equatable { case tooLarge, malformed }

    public static func encode(_ message: Message) -> Data {
        var payload = Data()
        let kind: Kind
        switch message {
        case let .format(codec, width, height, parameterSets):
            kind = .format
            payload.append(codec.rawValue)
            payload.append(u16: width); payload.append(u16: height)
            payload.append(UInt8(clamping: parameterSets.count))
            for set in parameterSets.prefix(255) { payload.append(u16: set.count); payload.append(set) }
        case let .frame(number, keyframe, data):
            kind = .frame
            payload.append(u32: number); payload.append(keyframe ? 1 : 0); payload.append(data)
        case let .copied(result):
            kind = .copied
            switch result {
            case let .text(text): payload.append(0); payload.append(Data(text.utf8))
            case .nothing: payload.append(1)
            case .tooLong: payload.append(2)
            case .notText: payload.append(3)
            }
        case let .hello(hello):
            kind = .hello
            payload.append(u16: hello.width); payload.append(u16: hello.height); payload.append(hello.fit.rawValue)
            payload.append(hello.codecs.rawValue); payload.append(UInt8(clamping: hello.fps)); payload.append(hello.quality.rawValue)
            payload.append(UInt8(clamping: hello.space))
        case let .viewers(names):
            kind = .viewers
            let kept = names.prefix(16).map { Data(String($0.prefix(64)).utf8.prefix(255)) }
            payload.append(UInt8(kept.count))
            for name in kept { payload.append(UInt8(name.count)); payload.append(name) }
        case let .movedAway(name):
            kind = .movedAway
            payload.append(Data(String(name.prefix(64)).utf8))
        case .useHere:
            kind = .useHere
        case let .gesture(gesture, phase, value):
            kind = .gesture
            payload.append(gesture.rawValue); payload.append(phase.rawValue)
            // Ten-thousandths: plenty for a step of a pinch, and room for a whole turn.
            payload.append(u32: UInt32(bitPattern: Int32(clamping: Int((value * 10_000).rounded()))))
        case let .fitted(fit):
            kind = .fitted
            payload.append(fit.rawValue)
        case let .cursor(x, y, visible):
            kind = .cursor
            payload.append(u16: Int(x)); payload.append(u16: Int(y)); payload.append(visible ? 1 : 0)
        case let .cursorShape(width, height, hotX, hotY, png):
            kind = .cursorShape
            payload.append(u16: width); payload.append(u16: height); payload.append(u16: hotX); payload.append(u16: hotY)
            payload.append(png)
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
        case .copy:
            kind = .copy
        case let .curtained(hidden):
            kind = .curtained
            payload.append(hidden ? 1 : 0)
        case let .curtain(hidden):
            kind = .curtain
            payload.append(hidden ? 1 : 0)
        case let .microphone(on):
            kind = .microphone
            payload.append(on ? 1 : 0)
        case let .voice(samples):
            kind = .voice
            payload.append(samples)
        case let .function(down):
            kind = .function
            payload.append(down ? 1 : 0)
        case let .microphoneState(state):
            kind = .microphoneState
            payload.append(state.rawValue)
        }
        var out = Data([kind.rawValue])
        out.append(u32: UInt32(payload.count))
        out.append(payload)
        return out
    }

    /// `text` split into pieces of at most `maxBytes` of UTF-8 each, on
    /// character boundaries (a single character longer than that, on scalar
    /// boundaries), so a long paste still fits `maxTextPayload` per message.
    public static func textPieces(_ text: String, maxBytes: Int = maxTextPayload) -> [String] {
        guard text.utf8.count > maxBytes else { return text.isEmpty ? [] : [text] }
        var pieces: [String] = [], piece = "", pieceBytes = 0
        func add(_ part: String, _ bytes: Int) {
            if pieceBytes + bytes > maxBytes, !piece.isEmpty { pieces.append(piece); piece = ""; pieceBytes = 0 }
            piece += part
            pieceBytes += bytes
        }
        for character in text {
            let bytes = character.utf8.count
            if bytes <= maxBytes {
                add(String(character), bytes)
            } else {
                for scalar in character.unicodeScalars { add(String(scalar), String(scalar).utf8.count) }
            }
        }
        if !piece.isEmpty { pieces.append(piece) }
        return pieces
    }

    /// The most a payload of message type `type` from `sender` may be.
    static func maxPayload(of type: UInt8, from sender: Sender) -> Int {
        // What the Mac copied is held to what a phone may paste (and a status byte).
        guard sender == .phone else { return Kind(rawValue: type) == .copied ? maxClipboardPayload + 1 : maxPayload }
        switch Kind(rawValue: type) {
        case .text: return maxTextPayload
        case .clipboard: return maxClipboardPayload
        case .voice: return maxVoicePayload
        case .some: return maxEventPayload
        // A type added later: skipped, but not buffered without bound either.
        case nil: return maxClipboardPayload
        }
    }

    /// Splits a byte stream into messages. Unknown types are skipped, so
    /// either side can add some later.
    public struct Reader: Sendable {
        private var buffer = Data()
        private let sender: Sender
        /// `sender`: the side that writes the stream; a phone's messages have smaller limits.
        public init(from sender: Sender = .mac) { self.sender = sender }

        /// The messages complete so far; throws on a payload over its type's
        /// limit (`maxPayload(of:from:)`), checked before it is buffered, or one that doesn't parse.
        public mutating func append(_ data: Data) throws -> [Message] {
            buffer.append(data)
            var messages: [Message] = []
            var offset = buffer.startIndex
            while buffer.endIndex - offset >= 5 {
                let length = Int(buffer.u32(at: offset + 1))
                guard length <= ScreenVideoWire.maxPayload(of: buffer[offset], from: sender) else { throw Failure.tooLarge }
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
            guard let codec = Codec(rawValue: p[b]) else { throw Failure.malformed }
            var offset = 6, sets: [Data] = []
            for _ in 0..<Int(p[b + 5]) {
                try need(offset + 2)
                let length = Int(p.u16(at: b + offset))
                try need(offset + 2 + length)
                sets.append(p.subdata(in: (b + offset + 2)..<(b + offset + 2 + length)))
                offset += 2 + length
            }
            return .format(codec: codec, width: Int(p.u16(at: b + 1)), height: Int(p.u16(at: b + 3)), parameterSets: sets)
        case .frame:
            try need(5)
            return .frame(number: p.u32(at: b), keyframe: p[b + 4] & 1 != 0, data: p.subdata(in: (b + 5)..<p.endIndex))
        case .hello:
            try need(9)
            // A fit or quality added later reads as the first; H.264 is always decodable.
            return .hello(Hello(width: Int(p.u16(at: b)), height: Int(p.u16(at: b + 2)), fit: Fit(rawValue: p[b + 4]) ?? .mac,
                                codecs: Codecs(rawValue: p[b + 5]).union(.h264), fps: min(max(Int(p[b + 6]), 15), 120),
                                quality: Quality(rawValue: p[b + 7]) ?? .sharp, space: min(max(Int(p[b + 8]), 50), 200)))
        case .viewers:
            try need(1)
            var names: [String] = [], offset = 1
            for _ in 0..<Int(p[b]) {
                try need(offset + 1)
                let length = Int(p[b + offset])
                try need(offset + 1 + length)
                names.append(String(decoding: p.subdata(in: (b + offset + 1)..<(b + offset + 1 + length)), as: UTF8.self))
                offset += 1 + length
            }
            return .viewers(names)
        case .movedAway:
            return .movedAway(to: String(decoding: p, as: UTF8.self))
        case .useHere:
            return .useHere
        case .gesture:
            try need(6)
            guard let gesture = Gesture(rawValue: p[b]), let phase = GesturePhase(rawValue: p[b + 1]) else { throw Failure.malformed }
            return .gesture(gesture, phase: phase, value: Double(Int32(bitPattern: p.u32(at: b + 2))) / 10_000)
        case .fitted:
            try need(1)
            return .fitted(Fit(rawValue: p[b]) ?? .mac)
        case .cursor:
            try need(5)
            return .cursor(x: p.u16(at: b), y: p.u16(at: b + 2), visible: p[b + 4] & 1 != 0)
        case .cursorShape:
            try need(8)
            return .cursorShape(width: Int(p.u16(at: b)), height: Int(p.u16(at: b + 2)), hotX: Int(p.u16(at: b + 4)),
                                hotY: Int(p.u16(at: b + 6)), png: p.subdata(in: (b + 8)..<p.endIndex))
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
        case .copied:
            try need(1)
            switch p[b] {
            case 0: return .copied(.text(String(decoding: p.dropFirst(), as: UTF8.self)))
            case 2: return .copied(.tooLong)
            case 3: return .copied(.notText)
            // A status added later reads as nothing copied.
            default: return .copied(.nothing)
            }
        case .keyframeRequest:
            return .keyframeRequest
        case .copy:
            return .copy
        case .curtained:
            try need(1)
            return .curtained(p[b] == 1)
        case .curtain:
            try need(1)
            return .curtain(p[b] == 1)
        case .microphone:
            try need(1)
            return .microphone(p[b] == 1)
        case .function:
            try need(1)
            return .function(p[b] == 1)
        case .voice:
            // Whole samples only.
            return .voice(p.count % 2 == 0 ? p : p.dropLast())
        case .microphoneState:
            try need(1)
            // A state added later reads as not taking the voice.
            return .microphoneState(MicrophoneState(rawValue: p[b]) ?? .failed)
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
