import AVFoundation
import Foundation
import PassthroughCore

/// This device's microphone as the Mac takes it (`ScreenVideoWire.voice`: 16-bit mono
/// at `voiceSampleRate`), a piece every audio cycle (about 10 ms), while the screen
/// view has the microphone on. Recording stops other audio on the device.
final class PhoneVoiceCapture: @unchecked Sendable {
    enum Failure: Error { case noInput, noConverter }

    private let engine = AVAudioEngine()
    /// Converts off the audio thread, in order.
    private let queue = DispatchQueue(label: "\(PassthroughProtocol.identifier).screen-voice", qos: .userInteractive)
    private let onSamples: @Sendable (Data) -> Void
    private let onStopped: @Sendable () -> Void
    private var observers: [NSObjectProtocol] = []
    // On `queue`.
    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?
    private var wireFormat: AVAudioFormat?
    private var running = false

    /// `onSamples`: the next piece, on a queue of its own. `onStopped`: iOS took the
    /// microphone away (a call, another app, the input changed); on the main queue.
    init(onSamples: @escaping @Sendable (Data) -> Void, onStopped: @escaping @Sendable () -> Void) {
        self.onSamples = onSamples
        self.onStopped = onStopped
    }

    /// Asks for the microphone the first time; false if it's refused.
    static func requestPermission() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }

    func start() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .default)
        try? session.setPreferredIOBufferDuration(0.01)
        try session.setActive(true)
        let input = engine.inputNode
        let hardware = input.outputFormat(forBus: 0)
        guard hardware.sampleRate > 0, hardware.channelCount > 0,
              let mono = AVAudioFormat(standardFormatWithSampleRate: hardware.sampleRate, channels: 1),
              let wire = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Double(ScreenVideoWire.voiceSampleRate), channels: 1,
                                       interleaved: true) else {
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            throw Failure.noInput
        }
        guard let converter = AVAudioConverter(from: mono, to: wire) else {
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            throw Failure.noConverter
        }
        queue.sync {
            self.converter = converter
            inputFormat = mono
            wireFormat = wire
            running = true
        }
        // A sink gets every audio cycle as it happens; a tap would hand over a tenth of a second at a time.
        let sink = AVAudioSinkNode { [weak self] _, frames, buffers -> OSStatus in
            guard let self, frames > 0, let first = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: buffers)).first,
                  let data = first.mData else { return noErr }
            let count = min(Int(frames), Int(first.mDataByteSize) / MemoryLayout<Float>.size)
            let samples = Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: Float.self), count: count))
            self.queue.async { self.convert(samples) }
            return noErr
        }
        engine.attach(sink)
        engine.connect(input, to: sink, format: hardware)
        let center = NotificationCenter.default
        let ended: @Sendable (Notification) -> Void = { [weak self] _ in self?.lost() }
        observers = [
            center.addObserver(forName: AVAudioSession.interruptionNotification, object: session, queue: nil) { [weak self] note in
                let began = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt) == AVAudioSession.InterruptionType.began.rawValue
                if began { self?.lost() }
            },
            center.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil, using: ended),
            center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: session, queue: nil, using: ended),
        ]
        do {
            try engine.start()
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        let wasRunning = queue.sync { () -> Bool in
            defer { running = false; converter = nil }
            return running
        }
        guard wasRunning else { return }
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// iOS stopped the recording: the owner is told once, and stops it.
    private func lost() {
        guard queue.sync(execute: { running }) else { return }
        let onStopped = self.onStopped
        DispatchQueue.main.async { onStopped() }
    }

    /// On `queue`: one cycle's samples at the hardware's rate to the wire's.
    private func convert(_ samples: [Float]) {
        guard running, let converter, let inputFormat, let wireFormat, !samples.isEmpty,
              let input = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = input.floatChannelData?[0] else { return }
        samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: samples.count) }
        input.frameLength = AVAudioFrameCount(samples.count)
        let capacity = AVAudioFrameCount(Double(samples.count) * wireFormat.sampleRate / inputFormat.sampleRate) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: wireFormat, frameCapacity: capacity) else { return }
        var fed = false
        var error: NSError?
        // "No data now" after the one buffer: the converter keeps its place for the next cycle.
        converter.convert(to: output, error: &error) { _, status in
            if fed {
                status.pointee = .noDataNow
                return nil
            }
            fed = true
            status.pointee = .haveData
            return input
        }
        guard error == nil, output.frameLength > 0, let converted = output.int16ChannelData?[0] else { return }
        // Little-endian on every device this runs on, as the wire wants.
        onSamples(Data(bytes: converted, count: Int(output.frameLength) * MemoryLayout<Int16>.size))
    }
}
