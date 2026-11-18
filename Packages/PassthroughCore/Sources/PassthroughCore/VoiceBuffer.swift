import Foundation

/// Sound between the network, which delivers it in bursts, and the device that
/// plays it, which takes it at a steady rate: a phone's voice on the Mac, the
/// Mac's sound on a phone. Playing starts once `target`
/// samples wait, so a late packet finds some still there; if they run out it
/// waits for `target` again. More than `limit` waiting (the link stalled, then
/// caught up) and the oldest go, back down to `target`: what is heard
/// stays close to what was just said (or played). Samples are counted one by one: for
/// stereo, interleaved, with `target` and `limit` even. Not thread-safe.
public struct VoiceBuffer {
    public let target: Int
    public let limit: Int
    private var samples: [Float]
    private var head = 0
    public private(set) var count = 0
    private var playing = false

    /// 60 ms before it plays, a quarter of a second at most, at the wire's rate.
    public init(target: Int = ScreenVideoWire.voiceSampleRate * 60 / 1000, limit: Int = ScreenVideoWire.voiceSampleRate / 4) {
        self.target = target
        self.limit = max(limit, target)
        samples = [Float](repeating: 0, count: self.limit * 2)
    }

    public mutating func push(_ new: UnsafeBufferPointer<Float>) {
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
    public mutating func pull(into out: UnsafeMutableBufferPointer<Float>) {
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

    public mutating func clear() {
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
