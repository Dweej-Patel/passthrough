import CoreGraphics
import CoreMedia
import Foundation
import ImageIO
import PassthroughCore
import VideoToolbox

/// The phone's end of the Mac's own screen stream (protocol/README.md,
/// "Screen video"), over a stream the remote shell handed over after
/// `screenVideoReady`. It turns frames into sample buffers ready for a
/// display layer (which decodes in hardware), and sends input. Call `shown`
/// for every frame once it's on screen: the Mac waits for that before
/// sending more than fit in the round trip, which is what keeps the picture
/// current. The pointer isn't in the frames: `cursor` and `cursorShape` say
/// where to draw it.
public final class ScreenVideoClient: @unchecked Sendable {
    /// What the phone asks to see (`ScreenVideoWire.Message.hello`).
    public struct Layout: Equatable, Sendable {
        public var width: Int
        public var height: Int
        public var fit: ScreenVideoWire.Fit
        public var fps: Int
        public var quality: ScreenVideoWire.Quality
        /// `device` only: the display's size against the stream's, in percent (`ScreenVideoWire.Hello.space`).
        public var space: Int
        public init(width: Int, height: Int, fit: ScreenVideoWire.Fit, fps: Int = 60, quality: ScreenVideoWire.Quality = .sharp,
                    space: Int = 100) {
            self.width = width
            self.height = height
            self.fit = fit
            self.fps = fps
            self.quality = quality
            self.space = space
        }
    }

    public enum Event: @unchecked Sendable {
        /// The stream's size in pixels (first, and again if it changes).
        case size(width: Int, height: Int)
        /// What the stream shows from now (the answer to each layout).
        case fitted(ScreenVideoWire.Fit)
        /// The Mac's pointer at (`x`, `y`), each 0…1 across the stream; or not on it.
        case cursor(x: Double, y: Double, visible: Bool)
        /// What the pointer looks like, `size` in stream pixels, its tip at `hotSpot` in them.
        case cursorShape(CGImage, size: CGSize, hotSpot: CGPoint)
        /// The other devices viewing this Mac's screen now, by name.
        case viewers([String])
        /// Another device took this view over; `closed` follows.
        case movedAway(to: String)
        /// A frame to show, then pass `number` to `shown`.
        case frame(CMSampleBuffer, number: UInt32)
        /// The answer to `copySelection()`.
        case copied(ScreenVideoWire.CopyResult)
        /// The answer to `curtain(_:)`: whether the Mac's displays are hidden now.
        case curtained(Bool)
        /// The connection is over: nil when `close()` ended it.
        case closed(Error?)
    }

    public enum Failure: Error { case malformed, connectionLost }

    private let stream: any ByteStream
    private let queue = DispatchQueue(label: "\(PassthroughProtocol.identifier).screen-video-client")
    private let callbackQueue: DispatchQueue
    private let onEvent: (Event) -> Void
    private var layout: Layout
    private let codecs: ScreenVideoWire.Codecs

    // On `queue`.
    private var reader = ScreenVideoWire.Reader()
    private var pending: Data
    private var format: CMVideoFormatDescription?
    private var parameterSets: (ScreenVideoWire.Codec, [Data])?
    private var size: (Int, Int)?
    /// `copySelection()` calls not yet answered: the Mac's copies are taken
    /// only as answers, so it can't put things on this phone's clipboard unasked.
    private var copiesAsked = 0
    /// After a keyframe request, frames are skipped until a keyframe arrives.
    private var awaitingKeyframe = true
    private var closed = false

    /// What this device decodes in hardware: HEVC where it can, H.264 always.
    public static var decodableCodecs: ScreenVideoWire.Codecs {
        VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC) ? [.h264, .hevc] : .h264
    }

    /// `layout`: what to show first; `relayout` changes it. `codecs`: what to offer the Mac.
    public init(stream: any ByteStream, initialBytes: Data = Data(), layout: Layout, codecs: ScreenVideoWire.Codecs = decodableCodecs,
                queue: DispatchQueue = .main, onEvent: @escaping (Event) -> Void) {
        self.stream = stream
        self.pending = initialBytes
        self.layout = layout
        self.codecs = codecs
        self.callbackQueue = queue
        self.onEvent = onEvent
    }

    /// The Mac's own display, at most `maxSide` pixels on its longer side.
    public convenience init(stream: any ByteStream, initialBytes: Data = Data(), maxSide: Int, queue: DispatchQueue = .main,
                            onEvent: @escaping (Event) -> Void) {
        self.init(stream: stream, initialBytes: initialBytes, layout: Layout(width: maxSide, height: maxSide, fit: .mac),
                  queue: queue, onEvent: onEvent)
    }

    public func start() {
        queue.async { [self] in
            stream.onTerminated = { [weak self] _ in self?.queue.async { self?.finish(Failure.connectionLost) } }
            send(.hello(hello(layout)))
            let initial = pending
            pending = Data()
            received(initial)
            receive()
        }
    }

    public func close() {
        queue.async { [self] in finish(nil) }
    }

    /// Asks for something else to be shown (the phone turned, or the user chose
    /// another fit); the Mac answers with `fitted`, then a new `size` if it changed.
    public func relayout(_ new: Layout) {
        queue.async { [self] in
            guard !closed, new != layout else { return }
            layout = new
            send(.hello(hello(new)))
        }
    }

    private func hello(_ layout: Layout) -> ScreenVideoWire.Hello {
        .init(width: layout.width, height: layout.height, fit: layout.fit, codecs: codecs, fps: layout.fps, quality: layout.quality,
              space: layout.space)
    }

    /// This device is used here now: the Mac ends every other device's view of its screen.
    public func useHere() { send(.useHere) }

    /// A trackpad pinch (`value`: the magnification since the last) or rotation (degrees
    /// counterclockwise since the last) at the Mac's pointer.
    public func gesture(_ gesture: ScreenVideoWire.Gesture, phase: ScreenVideoWire.GesturePhase, value: Double) {
        send(.gesture(gesture, phase: phase, value: value))
    }

    // MARK: Input

    /// The pointer at (`x`, `y`), each 0…1 across the screen, with `buttons` held.
    public func pointer(x: Double, y: Double, buttons: RFBClient.Buttons) {
        let scale = { (v: Double) in UInt16(clamping: Int((max(0, min(v, 1)) * 65535).rounded())) }
        send(.pointer(x: scale(x), y: scale(y), buttons: buttons.rawValue & 0b111))
    }

    /// Scrolls by (`dx`, `dy`) of the Mac's points; positive `dy` brings earlier content into view.
    public func scroll(dx: Int, dy: Int) {
        guard dx != 0 || dy != 0 else { return }
        send(.scroll(dx: Int16(clamping: dx), dy: Int16(clamping: dy)))
    }

    public func key(_ keysym: UInt32, modifiers: ScreenVideoWire.Modifiers) {
        send(.key(keysym: keysym, modifiers: modifiers.rawValue))
    }

    /// Typed as is; a long paste goes in pieces the Mac accepts (`ScreenVideoWire.maxTextPayload`).
    public func text(_ text: String) {
        for piece in ScreenVideoWire.textPieces(text) { send(.text(piece)) }
    }

    /// Puts `text` on the Mac's clipboard; false (nothing sent) when it is
    /// longer than the Mac takes (`ScreenVideoWire.maxClipboardPayload`).
    @discardableResult
    public func clipboard(_ text: String) -> Bool {
        guard text.utf8.count <= ScreenVideoWire.maxClipboardPayload else { return false }
        send(.clipboard(text))
        return true
    }

    /// Presses ⌘C on the Mac; what it copied comes back as `copied`.
    public func copySelection() {
        queue.async { [self] in
            guard !closed else { return }
            copiesAsked += 1
            send(.copy)
        }
    }

    /// Hides what the Mac's own displays show (this stream still shows it), or
    /// shows it again; the Mac answers with `curtained`. A Mac that predates it doesn't answer.
    public func curtain(_ hidden: Bool) { send(.curtain(hidden)) }

    /// Frame `number` is on screen.
    public func shown(_ number: UInt32) { send(.ack(number: number)) }

    /// The display couldn't use what it got (it failed, or the app was in the background): start again from a keyframe.
    public func requestKeyframe() {
        queue.async { [self] in
            awaitingKeyframe = true
            send(.keyframeRequest)
        }
    }

    // MARK: Reading

    private func receive() {
        stream.receive(maximumLength: 256 * 1024) { [weak self] data, complete, error in
            guard let self else { return }
            self.queue.async {
                guard !self.closed else { return }
                if let data, !data.isEmpty { self.received(data) }
                if complete || error != nil { return self.finish(Failure.connectionLost) }
                if !self.closed { self.receive() }
            }
        }
    }

    private func received(_ data: Data) {
        guard !data.isEmpty else { return }
        do {
            for message in try reader.append(data) {
                guard !closed else { return }
                try handle(message)
            }
        } catch {
            finish(Failure.malformed)
        }
    }

    private func handle(_ message: ScreenVideoWire.Message) throws {
        switch message {
        case let .format(codec, width, height, sets):
            if parameterSets.map({ $0.0 != codec || $0.1 != sets }) ?? true {
                format = try Self.formatDescription(codec: codec, parameterSets: sets)
                parameterSets = (codec, sets)
            }
            if size.map({ $0 != (width, height) }) ?? true {
                size = (width, height)
                emit(.size(width: width, height: height))
            }
        case let .frame(number, keyframe, data):
            guard let format else { return send(.ack(number: number)) }
            if awaitingKeyframe {
                // Without the frames before it, a delta frame can't be shown; still let the Mac send on.
                guard keyframe else { return send(.ack(number: number)) }
                awaitingKeyframe = false
            }
            emit(.frame(try Self.sampleBuffer(data, format: format, number: number), number: number))
        case let .copied(result):
            guard copiesAsked > 0 else { return }
            copiesAsked -= 1
            emit(.copied(result))
        case let .curtained(hidden):
            emit(.curtained(hidden))
        case let .fitted(fit):
            emit(.fitted(fit))
        case let .viewers(names):
            emit(.viewers(names))
        case let .movedAway(name):
            emit(.movedAway(to: name))
        case let .cursor(x, y, visible):
            emit(.cursor(x: Double(x) / 65535, y: Double(y) / 65535, visible: visible))
        case let .cursorShape(width, height, hotX, hotY, png):
            // A shape that doesn't decode is skipped: the pointer keeps the last one.
            guard width > 0, height > 0, let source = CGImageSourceCreateWithData(png as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return }
            emit(.cursorShape(image, size: CGSize(width: width, height: height), hotSpot: CGPoint(x: hotX, y: hotY)))
        default:
            break
        }
    }

    // MARK: H.264 and HEVC

    /// H.264 takes its SPS and PPS; HEVC its VPS, SPS and PPS.
    static func formatDescription(codec: ScreenVideoWire.Codec, parameterSets sets: [Data]) throws -> CMVideoFormatDescription {
        // Empty parameter sets have no base address to hand over.
        guard sets.count == (codec == .hevc ? 3 : 2), sets.allSatisfy({ !$0.isEmpty }) else { throw Failure.malformed }
        // Copied out, so every pointer stays valid for the call.
        let copies = sets.map { set -> UnsafeMutablePointer<UInt8> in
            let pointer = UnsafeMutablePointer<UInt8>.allocate(capacity: set.count)
            set.copyBytes(to: pointer, count: set.count)
            return pointer
        }
        defer { copies.forEach { $0.deallocate() } }
        let pointers = copies.map { UnsafePointer($0) }
        let sizes = sets.map(\.count)
        var format: CMVideoFormatDescription?
        let status = codec == .hevc
            ? CMVideoFormatDescriptionCreateFromHEVCParameterSets(allocator: nil, parameterSetCount: sets.count, parameterSetPointers: pointers,
                                                                  parameterSetSizes: sizes, nalUnitHeaderLength: 4, extensions: nil,
                                                                  formatDescriptionOut: &format)
            : CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: nil, parameterSetCount: sets.count, parameterSetPointers: pointers,
                                                                  parameterSetSizes: sizes, nalUnitHeaderLength: 4, formatDescriptionOut: &format)
        guard status == noErr, let format else { throw Failure.malformed }
        return format
    }

    /// One frame's AVCC data as a sample buffer the display shows as soon as it has it.
    static func sampleBuffer(_ data: Data, format: CMVideoFormatDescription, number: UInt32) throws -> CMSampleBuffer {
        // An empty frame is nothing to show, and has no base address to copy from.
        guard !data.isEmpty else { throw Failure.malformed }
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: data.count, blockAllocator: nil,
                                                 customBlockSource: nil, offsetToData: 0, dataLength: data.count, flags: 0,
                                                 blockBufferOut: &block) == noErr, let block,
              data.withUnsafeBytes({ CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0,
                                                                     dataLength: data.count) }) == noErr else { throw Failure.malformed }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: CMTime(value: CMTimeValue(number), timescale: 60),
                                        decodeTimeStamp: .invalid)
        var sizes = [data.count]
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: 1,
                                        sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1,
                                        sampleSizeArray: &sizes, sampleBufferOut: &sample) == noErr, let sample else { throw Failure.malformed }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true), CFArrayGetCount(attachments) > 0 {
            let first = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(first, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return sample
    }

    // MARK: Plumbing

    private func send(_ message: ScreenVideoWire.Message) {
        let data = ScreenVideoWire.encode(message)
        queue.async { [self] in
            guard !closed else { return }
            stream.send(data, isComplete: false) { _ in }
        }
    }

    private func finish(_ error: Error?) {
        guard !closed else { return }
        closed = true
        stream.onTerminated = nil
        stream.cancel()
        emit(.closed(error))
    }

    private func emit(_ event: Event) {
        let onEvent = self.onEvent
        callbackQueue.async { onEvent(event) }
    }
}
