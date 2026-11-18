#if os(macOS)
import AVFoundation
import CoreMedia
import Foundation
import PassthroughCore
import ScreenCaptureKit

/// Where the streamer gets the Mac's sound: `MacSoundCapture`, or packets a test makes.
/// One capture each: once stopped, it isn't started again.
protocol SoundSource: AnyObject, Sendable {
    /// Starts handing over the Mac's sound as `MacSound` packets (on a queue of its own);
    /// false if it can't. `stopped` runs if it ends by itself.
    func start(packet: @escaping @Sendable (Data) -> Void, stopped: @escaping @Sendable () -> Void) async -> Bool
    func stop()
}

/// What the Mac's apps play, through ScreenCaptureKit (the Screen Recording permission
/// the screen's own capture has), whatever the Mac's volume is, and without this app's
/// own sound: a phone's voice, played to the microphone device, isn't sent back to it.
/// A stream of its own, apart from the picture's, which starts over with every change
/// of size; its picture is a pixel a second, and ignored. Nothing is sent while the Mac
/// is silent.
final class MacSoundCapture: NSObject, SoundSource, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    /// Silent buffers (about 20 ms each) before sending stops: the tail of a sound isn't cut.
    static let silentBuffersSent = 25

    private let queue = DispatchQueue(label: "\(PassthroughProtocol.identifier).screen-video.sound", qos: .userInitiated)
    private let lock = NSLock()
    private var stream: SCStream?
    private var stopped = false
    private var onStopped: (@Sendable () -> Void)?
    // On `queue`.
    private var onPacket: (@Sendable (Data) -> Void)?
    private let encoder = MacSound.Encoder()
    private var silentBuffers = 0

    func start(packet: @escaping @Sendable (Data) -> Void, stopped: @escaping @Sendable () -> Void) async -> Bool {
        guard encoder != nil else { return false }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) ?? content.displays.first else { return false }
            let configuration = SCStreamConfiguration()
            configuration.capturesAudio = true
            configuration.sampleRate = Int(MacSound.sampleRate)
            configuration.channelCount = MacSound.channels
            configuration.excludesCurrentProcessAudio = true
            configuration.width = 2
            configuration.height = 2
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
            configuration.showsCursor = false
            let stream = SCStream(filter: SCContentFilter(display: display, excludingWindows: []), configuration: configuration, delegate: self)
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
            // Not used; without an output for it the stream complains about every frame.
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
            queue.sync { onPacket = packet }
            try await stream.startCapture()
            // Stopped while it started: nobody else will stop what just did.
            let abandoned = lock.withLock { () -> Bool in
                if self.stopped { return true }
                self.stream = stream
                self.onStopped = stopped
                return false
            }
            if abandoned {
                try? await stream.stopCapture()
                return false
            }
            return true
        } catch {
            ptLog(.warning, "screen: couldn't capture the Mac's sound: \(error)")
            return false
        }
    }

    func stop() {
        let stream = lock.withLock { () -> SCStream? in
            stopped = true
            onStopped = nil
            defer { self.stream = nil }
            return self.stream
        }
        queue.async { self.onPacket = nil }
        stream?.stopCapture { _ in }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        let onStopped = lock.withLock { () -> (@Sendable () -> Void)? in
            defer { self.onStopped = nil; self.stream = nil }
            return stopped ? nil : self.onStopped
        }
        onStopped?()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, let onPacket, let encoder, sampleBuffer.isValid, sampleBuffer.numSamples > 0,
              let description = sampleBuffer.formatDescription else { return }
        let format = AVAudioFormat(cmAudioFormatDescription: description)
        let frames = AVAudioFrameCount(sampleBuffer.numSamples)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return }
        buffer.frameLength = frames
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sampleBuffer, at: 0, frameCount: Int32(frames),
                                                           into: buffer.mutableAudioBufferList) == noErr else { return }
        silentBuffers = Self.isSilent(buffer) ? silentBuffers + 1 : 0
        guard silentBuffers <= Self.silentBuffersSent else { return }
        for packet in encoder.encode(buffer) { onPacket(packet) }
    }

    /// Nothing but zeros (what the Mac hands over while no app plays).
    static func isSilent(_ buffer: AVAudioPCMBuffer) -> Bool {
        guard let channels = buffer.floatChannelData else { return false }
        for channel in 0..<Int(buffer.format.channelCount) {
            let samples = UnsafeBufferPointer(start: channels[channel], count: Int(buffer.frameLength))
            if samples.contains(where: { $0 != 0 }) { return false }
        }
        return true
    }
}
#endif
