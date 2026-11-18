import AVFoundation
import Foundation
import PassthroughCore

/// The audio session for the screen view: what this device records for the Mac
/// (`PhoneVoiceCapture`) and plays of the Mac's (`MacSoundPlayer`). One place, since
/// there is one session: changing it stops whatever runs, so the screen model stops
/// both, sets it here, and starts what is on again.
enum ScreenAudioSession {
    static func apply(recording: Bool, playing: Bool) throws {
        let session = AVAudioSession.sharedInstance()
        guard recording || playing else {
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            return
        }
        if recording {
            // Alongside whatever else has the audio (music, another app's own recording), not instead of
            // it: a session that must interrupt the others is refused while one of them outranks it.
            try session.setCategory(.playAndRecord, mode: .default, options: [.mixWithOthers, .defaultToSpeaker, .allowBluetooth, .allowBluetoothA2DP])
            try? session.setPreferredIOBufferDuration(0.01)
            try session.setActive(true)
            return
        }
        // The Mac's sound alone: as music is, heard with the silent switch on, in place of other audio.
        do {
            try session.setCategory(.playback, mode: .default)
            try session.setActive(true)
        } catch {
            // Something outranks it (a call): alongside, then.
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
        }
    }
}

/// Plays the Mac's sound as it comes (`ScreenVideoWire.soundPacket`, decoded by
/// `MacSound.Decoder`), through a small buffer: it starts once 80 ms wait, and when
/// more than 400 ms wait (the link stalled, then caught up) the oldest go, so the
/// sound stays close to the picture. The audio session is the screen model's to set.
final class MacSoundPlayer: @unchecked Sendable {
    enum Failure: Error { case noDecoder }

    /// What the audio thread and the decoding queue share: interleaved stereo.
    private final class Shared: @unchecked Sendable {
        private let lock = NSLock()
        private var buffer = VoiceBuffer(target: Int(MacSound.sampleRate) * MacSound.channels * 80 / 1000,
                                         limit: Int(MacSound.sampleRate) * MacSound.channels * 400 / 1000)
        private var scratch = [Float](repeating: 0, count: 8192 * MacSound.channels)

        func push(_ samples: UnsafeBufferPointer<Float>) { lock.withLock { buffer.push(samples) } }

        /// The next `frames` frames into `left` and `right` (the same pointer for one channel).
        func pull(frames: Int, left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>) {
            lock.withLock {
                let frames = min(frames, scratch.count / MacSound.channels)
                scratch.withUnsafeMutableBufferPointer { scratch in
                    buffer.pull(into: UnsafeMutableBufferPointer(rebasing: scratch[0..<(frames * MacSound.channels)]))
                    for frame in 0..<frames {
                        left[frame] = scratch[frame * 2]
                        right[frame] = scratch[frame * 2 + 1]
                    }
                }
            }
        }

        func clear() { lock.withLock { buffer.clear() } }
    }

    private let engine = AVAudioEngine()
    private let queue = DispatchQueue(label: "\(PassthroughProtocol.identifier).screen-sound", qos: .userInteractive)
    private let shared = Shared()
    private var observer: NSObjectProtocol?
    // On `queue`.
    private var decoder: MacSound.Decoder?
    private var interleaved = [Float](repeating: 0, count: MacSound.framesPerPacket * 4 * MacSound.channels)

    func start() throws {
        guard let decoder = MacSound.Decoder() else { throw Failure.noDecoder }
        queue.sync { self.decoder = decoder }
        let source = AVAudioSourceNode(format: decoder.format) { [shared] _, _, frames, buffers -> OSStatus in
            let list = UnsafeMutableAudioBufferListPointer(buffers)
            guard let left = list.first?.mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            let right = list.count > 1 ? list[1].mData?.assumingMemoryBound(to: Float.self) ?? left : left
            shared.pull(frames: Int(frames), left: left, right: right)
            return noErr
        }
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: decoder.format)
        // Headphones in or out: the engine stops, and goes on with the new output.
        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            guard let self, self.observer != nil else { return }
            try? self.engine.start()
        }
        try engine.start()
    }

    /// The next packet of the Mac's sound.
    func play(_ packet: Data) {
        queue.async { [self] in
            guard let decoder, let sound = decoder.decode(packet), let channels = sound.floatChannelData else { return }
            let frames = min(Int(sound.frameLength), interleaved.count / MacSound.channels)
            let left = channels[0], right = sound.format.channelCount > 1 ? channels[1] : channels[0]
            for frame in 0..<frames {
                interleaved[frame * 2] = left[frame]
                interleaved[frame * 2 + 1] = right[frame]
            }
            interleaved.withUnsafeBufferPointer { shared.push(UnsafeBufferPointer(rebasing: $0[0..<(frames * MacSound.channels)])) }
        }
    }

    func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        engine.stop()
        queue.sync { decoder = nil }
        shared.clear()
    }
}
