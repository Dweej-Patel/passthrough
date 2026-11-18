import AVFoundation
import Foundation

/// The Mac's sound on its way to a phone viewing its screen (protocol/README.md,
/// "Screen video", `sound`): AAC-LC at 48 kHz stereo, a packet (1024 frames,
/// 21 ms) a message, with nothing around it. Both ends are here, so they agree.
public enum MacSound {
    public static let sampleRate = 48_000.0
    public static let channels = 2
    public static let framesPerPacket = 1024
    /// Plenty for speech and fine for music; a tenth of what the samples take raw.
    public static let bitRate = 128_000

    /// What goes over the wire.
    public static var compressedFormat: AVAudioFormat? {
        var description = AudioStreamBasicDescription(mSampleRate: sampleRate, mFormatID: kAudioFormatMPEG4AAC, mFormatFlags: 0,
                                                      mBytesPerPacket: 0, mFramesPerPacket: UInt32(framesPerPacket), mBytesPerFrame: 0,
                                                      mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 0, mReserved: 0)
        return AVAudioFormat(streamDescription: &description)
    }

    /// What a decoder gives: 32-bit float, a buffer per channel.
    public static var playbackFormat: AVAudioFormat? {
        AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: AVAudioChannelCount(channels))
    }

    /// The Mac's side. Not thread-safe.
    public final class Encoder {
        private let compressed: AVAudioFormat
        private var converter: AVAudioConverter?
        private var source: AVAudioFormat?

        public init?() {
            guard let compressed = MacSound.compressedFormat else { return nil }
            self.compressed = compressed
        }

        /// The packets `buffer` completed (none, one or a few: a packet is 1024 frames,
        /// whatever the buffers' size). Sound in any PCM format; a change of it starts over.
        public func encode(_ buffer: AVAudioPCMBuffer) -> [Data] {
            guard buffer.frameLength > 0 else { return [] }
            if converter == nil || source != buffer.format {
                converter = AVAudioConverter(from: buffer.format, to: compressed)
                converter?.bitRate = MacSound.bitRate
                source = buffer.format
            }
            guard let converter else { return [] }
            let output = AVAudioCompressedBuffer(format: compressed, packetCapacity: 16,
                                                 maximumPacketSize: max(converter.maximumOutputPacketSize, 1024))
            var fed = false
            var error: NSError?
            // "No data now" after the one buffer: the encoder keeps what's left for the next.
            converter.convert(to: output, error: &error) { _, status in
                if fed {
                    status.pointee = .noDataNow
                    return nil
                }
                fed = true
                status.pointee = .haveData
                return buffer
            }
            guard error == nil, output.packetCount > 0, let descriptions = output.packetDescriptions else { return [] }
            return (0..<Int(output.packetCount)).compactMap { index in
                let packet = descriptions[index]
                let start = Int(packet.mStartOffset), size = Int(packet.mDataByteSize)
                guard size > 0, start >= 0, start + size <= Int(output.byteLength) else { return nil }
                return Data(bytes: output.data.advanced(by: start), count: size)
            }
        }
    }

    /// The phone's side. Not thread-safe.
    public final class Decoder {
        private let compressed: AVAudioFormat
        public let format: AVAudioFormat
        private let converter: AVAudioConverter

        public init?() {
            guard let compressed = MacSound.compressedFormat, let format = MacSound.playbackFormat,
                  let converter = AVAudioConverter(from: compressed, to: format) else { return nil }
            self.compressed = compressed
            self.format = format
            self.converter = converter
        }

        /// One packet's sound (`format`); nil if it isn't one. The first packets give less, or
        /// nothing: the decoder needs a couple to get going.
        public func decode(_ packet: Data) -> AVAudioPCMBuffer? {
            guard !packet.isEmpty, packet.count <= 16 << 10,
                  let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(MacSound.framesPerPacket * 4)) else { return nil }
            let input = AVAudioCompressedBuffer(format: compressed, packetCapacity: 1, maximumPacketSize: packet.count)
            packet.withUnsafeBytes { input.data.copyMemory(from: $0.baseAddress!, byteCount: packet.count) }
            input.byteLength = UInt32(packet.count)
            input.packetCount = 1
            input.packetDescriptions?.pointee = AudioStreamPacketDescription(mStartOffset: 0, mVariableFramesInPacket: 0,
                                                                              mDataByteSize: UInt32(packet.count))
            var fed = false
            var error: NSError?
            converter.convert(to: output, error: &error) { _, status in
                if fed {
                    status.pointee = .noDataNow
                    return nil
                }
                fed = true
                status.pointee = .haveData
                return input
            }
            return error == nil && output.frameLength > 0 ? output : nil
        }
    }
}
