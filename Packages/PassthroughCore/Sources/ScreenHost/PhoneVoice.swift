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
