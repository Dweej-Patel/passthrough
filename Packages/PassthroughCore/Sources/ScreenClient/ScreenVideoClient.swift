import CoreMedia
import Foundation
import PassthroughCore

/// The phone's end of the Mac's own screen stream (protocol/README.md,
/// "Screen video"), over a stream the remote shell handed over after
/// `screenVideoReady`. It turns frames into sample buffers ready for a
/// display layer (which decodes in hardware), and sends input. Call `shown`
/// for every frame once it's on screen: the Mac waits for that before
/// sending more than a couple, which is what keeps the picture current.
public final class ScreenVideoClient: @unchecked Sendable {
    public enum Event: @unchecked Sendable {
        /// The stream's size in pixels (first, and again if it changes).
        case size(width: Int, height: Int)
        /// A frame to show, then pass `number` to `shown`.
        case frame(CMSampleBuffer, number: UInt32)
        /// The answer to `copySelection()`.
        case copied(ScreenVideoWire.CopyResult)
        /// The connection is over: nil when `close()` ended it.
        case closed(Error?)
    }

    public enum Failure: Error { case malformed, connectionLost }

    private let stream: any ByteStream
    private let queue = DispatchQueue(label: "\(PassthroughProtocol.identifier).screen-video-client")
    private let callbackQueue: DispatchQueue
    private let onEvent: (Event) -> Void
    private let maxSide: Int

    // On `queue`.
    private var reader = ScreenVideoWire.Reader()
    private var pending: Data
    private var format: CMVideoFormatDescription?
    private var parameterSets: (Data, Data)?
    private var size: (Int, Int)?
    /// `copySelection()` calls not yet answered: the Mac's copies are taken
    /// only as answers, so it can't put things on this phone's clipboard unasked.
    private var copiesAsked = 0
    /// After a keyframe request, frames are skipped until a keyframe arrives.
    private var awaitingKeyframe = true
    private var closed = false

    /// `maxSide`: the phone's longer side in pixels; the Mac sends no more than that.
    public init(stream: any ByteStream, initialBytes: Data = Data(), maxSide: Int, queue: DispatchQueue = .main,
                onEvent: @escaping (Event) -> Void) {
        self.stream = stream
        self.pending = initialBytes
        self.maxSide = maxSide
        self.callbackQueue = queue
        self.onEvent = onEvent
    }

    public func start() {
        queue.async { [self] in
            stream.onTerminated = { [weak self] _ in self?.queue.async { self?.finish(Failure.connectionLost) } }
            send(.hello(maxWidth: maxSide, maxHeight: maxSide))
            let initial = pending
            pending = Data()
            received(initial)
            receive()
        }
    }

    public func close() {
        queue.async { [self] in finish(nil) }
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
        case let .format(width, height, sps, pps):
            if parameterSets.map({ $0.0 != sps || $0.1 != pps }) ?? true {
                format = try Self.formatDescription(sps: sps, pps: pps)
                parameterSets = (sps, pps)
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
        default:
            break
        }
    }

    // MARK: H.264

    static func formatDescription(sps: Data, pps: Data) throws -> CMVideoFormatDescription {
        // Empty parameter sets have no base address to hand over.
        guard !sps.isEmpty, !pps.isEmpty else { throw Failure.malformed }
        var format: CMVideoFormatDescription?
        let status = sps.withUnsafeBytes { spsBytes in
            pps.withUnsafeBytes { ppsBytes in
                let pointers = [spsBytes.bindMemory(to: UInt8.self).baseAddress!, ppsBytes.bindMemory(to: UInt8.self).baseAddress!]
                let sizes = [sps.count, pps.count]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: nil, parameterSetCount: 2,
                                                                           parameterSetPointers: pointers, parameterSetSizes: sizes,
                                                                           nalUnitHeaderLength: 4, formatDescriptionOut: &format)
            }
        }
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
