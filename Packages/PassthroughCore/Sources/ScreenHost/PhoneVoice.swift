#if os(macOS)
import AVFoundation
import CoreAudio
import Foundation
import PassthroughCore

/// The "Passthrough Microphone" input device (macOS/Microphone, a Core Audio
/// plug-in the root helper installs): it records what is played to it.
public enum VirtualMicrophone {
    /// The driver's `kDeviceUID`.
    public static let deviceUID = "PassthroughMicrophone"

    /// The device, if the Mac has it now.
    public static var deviceID: AudioDeviceID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var uid = deviceUID as CFString
        var device = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = withUnsafePointer(to: &uid) {
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, UInt32(MemoryLayout<CFString>.size), $0, &size, &device)
        }
        return status == noErr && device != kAudioObjectUnknown ? device : nil
    }

    public static var isInstalled: Bool { deviceID != nil }
}

/// Where a phone's voice goes (`ScreenVideoStreamer`).
protocol VoiceSink: AnyObject {
    /// Starts taking voice; anything but `on` and nothing is played. May take a moment.
    func start() -> ScreenVideoWire.MicrophoneState
    /// The next samples (`ScreenVideoWire.voice`).
    func play(_ samples: Data)
    func stop()
}

/// A phone's voice between the network, which delivers it in bursts, and the
/// device, which takes it at a steady rate. Playing starts once `target`
/// samples wait, so a late packet finds some still there; if they run out it
/// waits for `target` again. More than `limit` waiting (the link stalled, then
/// caught up) and the oldest go, back down to `target`: what the Mac hears
/// stays close to what was just said. Not thread-safe.
struct VoiceBuffer {
    let target: Int
    let limit: Int
    private var samples: [Float]
    private var head = 0
    private(set) var count = 0
    private var playing = false

    /// 60 ms before it plays, a quarter of a second at most, at the wire's rate.
    init(target: Int = ScreenVideoWire.voiceSampleRate * 60 / 1000, limit: Int = ScreenVideoWire.voiceSampleRate / 4) {
        self.target = target
        self.limit = max(limit, target)
        samples = [Float](repeating: 0, count: self.limit * 2)
    }

    mutating func push(_ new: UnsafeBufferPointer<Float>) {
        // More than fits at once: only its end could ever be played.
        let new = new.count > samples.count ? UnsafeBufferPointer(rebasing: new[(new.count - samples.count)...]) : new
        let overflow = count + new.count - samples.count
        if overflow > 0 { drop(overflow) }
        var tail = (head + count) % samples.count
        for sample in new {
            samples[tail] = sample
            tail = tail + 1 == samples.count ? 0 : tail + 1
        }
        count += new.count
        if count > limit { drop(count - target) }
    }

    /// The next `out.count` samples; silence while it waits for `target`, and for what's missing.
    mutating func pull(into out: UnsafeMutableBufferPointer<Float>) {
        if !playing {
            guard count >= target else { return out.update(repeating: 0) }
            playing = true
        }
        let taken = min(count, out.count)
        for index in 0..<taken {
            out[index] = samples[head]
            head = head + 1 == samples.count ? 0 : head + 1
        }
        count -= taken
        if taken < out.count {
            for index in taken..<out.count { out[index] = 0 }
            playing = false
        }
    }

    mutating func clear() {
        head = 0
        count = 0
        playing = false
    }

    private mutating func drop(_ dropped: Int) {
        let dropped = min(dropped, count)
        head = (head + dropped) % samples.count
        count -= dropped
    }
}

/// Plays a phone's voice to the "Passthrough Microphone" device, which records
/// it for whatever listens to that microphone. Only that device: never the
/// Mac's speakers (without the device there is nothing to start).
final class PhoneVoicePlayer: VoiceSink, @unchecked Sendable {
    /// What the device's render thread and the stream's queue share.
    private final class Shared: @unchecked Sendable {
        private let lock = NSLock()
        private var buffer = VoiceBuffer()

        func push(_ samples: UnsafeBufferPointer<Float>) { lock.withLock { buffer.push(samples) } }
        func pull(into out: UnsafeMutableBufferPointer<Float>) { lock.withLock { buffer.pull(into: out) } }
        func clear() { lock.withLock { buffer.clear() } }
    }

    private let lock = NSLock()
    private let shared = Shared()
    private var engine: AVAudioEngine?

    func start() -> ScreenVideoWire.MicrophoneState {
        lock.withLock {
            if engine != nil { return .on }
            guard var device = VirtualMicrophone.deviceID else { return .notInstalled }
            let engine = AVAudioEngine()
            // The device before anything is connected: the mixer takes the output's format then.
            guard let unit = engine.outputNode.audioUnit,
                  AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &device,
                                       UInt32(MemoryLayout<AudioDeviceID>.size)) == noErr,
                  let format = AVAudioFormat(standardFormatWithSampleRate: Double(ScreenVideoWire.voiceSampleRate), channels: 1) else {
                ptLog(.warning, "screen: couldn't play to the Passthrough Microphone device")
                return .failed
            }
            shared.clear()
            let source = AVAudioSourceNode(format: format) { [shared] _, _, frames, buffers -> OSStatus in
                for buffer in UnsafeMutableAudioBufferListPointer(buffers) {
                    guard let data = buffer.mData else { continue }
                    let samples = UnsafeMutableBufferPointer(start: data.assumingMemoryBound(to: Float.self),
                                                             count: min(Int(frames), Int(buffer.mDataByteSize) / MemoryLayout<Float>.size))
                    shared.pull(into: samples)
                }
                return noErr
            }
            engine.attach(source)
            engine.connect(source, to: engine.mainMixerNode, format: format)
            do {
                try engine.start()
            } catch {
                ptLog(.warning, "screen: couldn't start the Passthrough Microphone: \(error)")
                return .failed
            }
            self.engine = engine
            return .on
        }
    }

    func play(_ samples: Data) {
        let count = samples.count / 2
        guard count > 0 else { return }
        var floats = [Float](repeating: 0, count: count)
        samples.withUnsafeBytes { raw in
            for index in 0..<count {
                let sample = Int16(littleEndian: raw.loadUnaligned(fromByteOffset: index * 2, as: Int16.self))
                floats[index] = Float(sample) / 32768
            }
        }
        floats.withUnsafeBufferPointer { shared.push($0) }
    }

    func stop() {
        lock.withLock {
            engine?.stop()
            engine = nil
        }
        shared.clear()
    }
}
#endif
