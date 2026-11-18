import AVFoundation
import XCTest
@testable import PassthroughCore

final class MacSoundTests: XCTestCase {
    /// A tone through the encoder and the decoder comes out a tone: as long, as loud, the same pitch.
    func testATonesRoundTrip() throws {
        let encoder = try XCTUnwrap(MacSound.Encoder()), decoder = try XCTUnwrap(MacSound.Decoder())
        let source = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        var packets: [Data] = [], phase = 0.0
        // Two seconds in buffers of 960 frames (what a capture hands over), not the codec's 1024.
        for _ in 0..<100 {
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: source, frameCapacity: 960))
            buffer.frameLength = 960
            for frame in 0..<960 {
                let sample = Float(sin(phase)) * 0.5
                buffer.floatChannelData![0][frame] = sample
                buffer.floatChannelData![1][frame] = sample
                phase += 2 * .pi * 1000 / 48_000
            }
            packets += encoder.encode(buffer)
        }
        XCTAssertGreaterThan(packets.count, 85)
        XCTAssertLessThan(packets.map(\.count).max() ?? 0, 2048, "a packet fits a message easily")
        let bytesASecond = packets.reduce(0) { $0 + $1.count } / 2
        XCTAssertLessThan(bytesASecond, 24_000, "about 128 kb/s")
        var left: [Float] = []
        for packet in packets {
            guard let sound = decoder.decode(packet) else { continue }
            XCTAssertEqual(sound.format.channelCount, 2)
            left += UnsafeBufferPointer(start: sound.floatChannelData![0], count: Int(sound.frameLength))
        }
        XCTAssertGreaterThan(left.count, 48_000 * 2 - 6 * 1024, "nearly all of it, less what the codec holds back")
        // Past the start, where the codec fades in.
        let steady = Array(left[9600..<(left.count - 4800)])
        let rms = (steady.reduce(0) { $0 + $1 * $1 } / Float(steady.count)).squareRoot()
        XCTAssertEqual(Double(rms), 0.5 / 2.0.squareRoot(), accuracy: 0.03)
        let crossings = zip(steady, steady.dropFirst()).filter { $0 < 0 && $1 >= 0 }.count
        XCTAssertEqual(Double(crossings) / (Double(steady.count) / 48_000), 1000, accuracy: 5)
    }

    func testWhatIsntAPacketIsRefused() throws {
        let decoder = try XCTUnwrap(MacSound.Decoder())
        XCTAssertNil(decoder.decode(Data()))
        XCTAssertNil(decoder.decode(Data(count: 64 << 10)))
        _ = decoder.decode(Data(repeating: 0xA5, count: 300))   // garbage: no crash, whatever it gives
    }
}
