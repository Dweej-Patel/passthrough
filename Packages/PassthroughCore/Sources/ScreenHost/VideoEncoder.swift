#if os(macOS)
import CoreMedia
import Foundation
import PassthroughCore
import VideoToolbox

/// HEVC or H.264 in the hardware encoder's low-latency mode: no frame
/// reordering, each frame out as soon as it's in, NAL units after 4-byte
/// lengths. HEVC is a little sharper for the same bits (on scrolling text at
/// 6 Mb/s, about 1.3 dB) and as quick to encode.
final class VideoEncoder {
    struct Encoded {
        var data: Data
        var keyframe: Bool
        /// The parameter sets, on keyframes (H.264: SPS, PPS; HEVC: VPS, SPS, PPS).
        var parameterSets: [Data] = []
    }

    enum Failure: Error { case create(OSStatus) }

    /// What became of a frame.
    enum Outcome {
        case encoded(Encoded)
        /// The encoder chose to skip it (no error): an unchanged frame, or one over a
        /// low bitrate's budget. Low-latency mode does this routinely; nothing is wrong.
        case dropped
        /// An error: the encoder may have died (it can after sleep).
        case failed
    }

    let codec: ScreenVideoWire.Codec
    let width: Int
    let height: Int
    private var session: VTCompressionSession?

    init(codec: ScreenVideoWire.Codec = .h264, width: Int, height: Int, bitRate: Int, fps: Int = 60) throws {
        self.codec = codec
        self.width = width
        self.height = height
        let specification = [kVTVideoEncoderSpecification_EnableLowLatencyRateControl: kCFBooleanTrue] as CFDictionary
        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(allocator: nil, width: Int32(width), height: Int32(height),
                                                codecType: codec == .hevc ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264,
                                                encoderSpecification: specification,
                                                imageBufferAttributes: nil, compressedDataAllocator: nil,
                                                outputCallback: nil, refcon: nil, compressionSessionOut: &session)
        guard status == noErr, let session else { throw Failure.create(status) }
        let properties: [CFString: Any] = [
            kVTCompressionPropertyKey_RealTime: true,
            kVTCompressionPropertyKey_AllowFrameReordering: false,
            kVTCompressionPropertyKey_ProfileLevel: codec == .hevc ? kVTProfileLevel_HEVC_Main_AutoLevel
                : kVTProfileLevel_H264_ConstrainedHigh_AutoLevel,
            kVTCompressionPropertyKey_AverageBitRate: bitRate,
            kVTCompressionPropertyKey_ExpectedFrameRate: fps,
            // Keyframes only when asked (start, or a phone that lost its place): they cost.
            kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration: 3600,
            kVTCompressionPropertyKey_ColorPrimaries: kCVImageBufferColorPrimaries_ITU_R_709_2,
            kVTCompressionPropertyKey_TransferFunction: kCVImageBufferTransferFunction_ITU_R_709_2,
            kVTCompressionPropertyKey_YCbCrMatrix: kCVImageBufferYCbCrMatrix_ITU_R_709_2,
        ]
        for (key, value) in properties {
            VTSessionSetProperty(session, key: key, value: value as CFTypeRef)
        }
        VTCompressionSessionPrepareToEncodeFrames(session)
        self.session = session
    }

    deinit { invalidate() }

    /// Changes the bitrate from the next frame on (the pacer's, as the link allows).
    /// (Low-latency mode takes `DataRateLimits` but doesn't hold keyframes to it,
    /// so it isn't set: a smaller capture is what makes them smaller.)
    func setBitRate(_ bitRate: Int) {
        guard let session else { return }
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: bitRate as CFNumber)
    }

    func invalidate() {
        if let session { VTCompressionSessionInvalidate(session) }
        session = nil
    }

    /// Encodes one frame; `done` gets it (nil if the encoder dropped or failed it), on the encoder's thread.
    func encode(_ buffer: CVPixelBuffer, at time: CMTime, keyframe: Bool, done: @escaping (Outcome) -> Void) {
        guard let session else { return done(.failed) }
        // Once: a frame refused up front may or may not also reach the handler.
        let called = Locked(false)
        let finish: (Outcome) -> Void = { outcome in if !called.exchange(true) { done(outcome) } }
        let options = keyframe ? [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue] as CFDictionary : nil
        let codec = self.codec
        let status = VTCompressionSessionEncodeFrame(session, imageBuffer: buffer, presentationTimeStamp: time,
                                                     duration: .invalid, frameProperties: options, infoFlagsOut: nil) { status, _, sample in
            guard status == noErr else { return finish(.failed) }
            guard let sample else { return finish(.dropped) }
            finish(Self.encoded(sample, codec: codec).map { .encoded($0) } ?? .failed)
        }
        if status != noErr { finish(.failed) }
    }

    static func encoded(_ sample: CMSampleBuffer, codec: ScreenVideoWire.Codec) -> Encoded? {
        guard let block = sample.dataBuffer else { return nil }
        var data = Data(count: CMBlockBufferGetDataLength(block))
        let copied = data.withUnsafeMutableBytes { bytes in
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: bytes.count, destination: bytes.baseAddress!)
        }
        guard copied == noErr else { return nil }
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
        let keyframe = !(attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)
        var encoded = Encoded(data: data, keyframe: keyframe)
        if keyframe, let format = sample.formatDescription { encoded.parameterSets = parameterSets(format, codec: codec) }
        return encoded
    }

    /// All of the format's parameter sets, in order; empty if they can't be read.
    static func parameterSets(_ format: CMFormatDescription, codec: ScreenVideoWire.Codec) -> [Data] {
        func set(_ index: Int, _ count: UnsafeMutablePointer<Int>?) -> Data? {
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            let status = codec == .hevc
                ? CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(format, parameterSetIndex: index, parameterSetPointerOut: &pointer,
                                                                    parameterSetSizeOut: &size, parameterSetCountOut: count,
                                                                    nalUnitHeaderLengthOut: nil)
                : CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: index, parameterSetPointerOut: &pointer,
                                                                    parameterSetSizeOut: &size, parameterSetCountOut: count,
                                                                    nalUnitHeaderLengthOut: nil)
            guard status == noErr, let pointer else { return nil }
            return Data(bytes: pointer, count: size)
        }
        var count = 0
        guard let first = set(0, &count) else { return [] }
        var sets = [first]
        for index in 1..<max(count, 1) {
            guard let next = set(index, nil) else { return [] }
            sets.append(next)
        }
        return sets
    }
}
#endif
