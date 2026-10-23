#if os(macOS)
import CoreMedia
import Foundation
import PassthroughCore
import VideoToolbox

/// H.264 in the hardware encoder's low-latency mode: no frame reordering,
/// each frame out as soon as it's in, AVCC output (4-byte NAL lengths).
final class VideoEncoder {
    struct Encoded {
        var data: Data
        var keyframe: Bool
        /// The parameter sets, on keyframes.
        var sps: Data?
        var pps: Data?
    }

    enum Failure: Error { case create(OSStatus) }

    let width: Int
    let height: Int
    private var session: VTCompressionSession?

    init(width: Int, height: Int, bitRate: Int) throws {
        self.width = width
        self.height = height
        let specification = [kVTVideoEncoderSpecification_EnableLowLatencyRateControl: kCFBooleanTrue] as CFDictionary
        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(allocator: nil, width: Int32(width), height: Int32(height),
                                                codecType: kCMVideoCodecType_H264, encoderSpecification: specification,
                                                imageBufferAttributes: nil, compressedDataAllocator: nil,
                                                outputCallback: nil, refcon: nil, compressionSessionOut: &session)
        guard status == noErr, let session else { throw Failure.create(status) }
        let properties: [CFString: Any] = [
            kVTCompressionPropertyKey_RealTime: true,
            kVTCompressionPropertyKey_AllowFrameReordering: false,
            kVTCompressionPropertyKey_ProfileLevel: kVTProfileLevel_H264_ConstrainedHigh_AutoLevel,
            kVTCompressionPropertyKey_AverageBitRate: bitRate,
            kVTCompressionPropertyKey_ExpectedFrameRate: 60,
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

    func invalidate() {
        if let session { VTCompressionSessionInvalidate(session) }
        session = nil
    }

    /// Encodes one frame; `done` gets it (nil if the encoder dropped or failed it), on the encoder's thread.
    func encode(_ buffer: CVPixelBuffer, at time: CMTime, keyframe: Bool, done: @escaping (Encoded?) -> Void) {
        guard let session else { return done(nil) }
        // Once: a frame refused up front may or may not also reach the handler.
        let called = Locked(false)
        let finish: (Encoded?) -> Void = { encoded in if !called.exchange(true) { done(encoded) } }
        let options = keyframe ? [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue] as CFDictionary : nil
        let status = VTCompressionSessionEncodeFrame(session, imageBuffer: buffer, presentationTimeStamp: time,
                                                     duration: .invalid, frameProperties: options, infoFlagsOut: nil) { status, _, sample in
            guard status == noErr, let sample else { return finish(nil) }
            finish(Self.encoded(sample))
        }
        if status != noErr { finish(nil) }
    }

    static func encoded(_ sample: CMSampleBuffer) -> Encoded? {
        guard let block = sample.dataBuffer else { return nil }
        var data = Data(count: CMBlockBufferGetDataLength(block))
        let copied = data.withUnsafeMutableBytes { bytes in
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: bytes.count, destination: bytes.baseAddress!)
        }
        guard copied == noErr else { return nil }
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
        let keyframe = !(attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)
        var encoded = Encoded(data: data, keyframe: keyframe)
        if keyframe, let format = sample.formatDescription {
            encoded.sps = parameterSet(format, 0)
            encoded.pps = parameterSet(format, 1)
        }
        return encoded
    }

    private static func parameterSet(_ format: CMFormatDescription, _ index: Int) -> Data? {
        var pointer: UnsafePointer<UInt8>?
        var size = 0
        let status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: index, parameterSetPointerOut: &pointer,
                                                                        parameterSetSizeOut: &size, parameterSetCountOut: nil,
                                                                        nalUnitHeaderLengthOut: nil)
        guard status == noErr, let pointer else { return nil }
        return Data(bytes: pointer, count: size)
    }
}
#endif
