import Foundation
import PassthroughCore

/// How fast the screen stream may go, learned from the phone's acks (each one
/// says a frame is on its screen). Two things follow from them:
///
/// - **Frames in flight** (`window`): as many as fit in the shortest round
///   trip seen lately, so a far-away phone still gets up to 60 frames a
///   second rather than two per round trip. Sized from the *shortest* trip,
///   not the latest, so frames queued on a slow link don't widen it further.
/// - **Bitrate** (`bitRate`): while acks come back no later than the
///   shortest trip allows, it creeps up to `maxBitRate`; once they lag behind
///   it (a queue is building somewhere on the way) it is cut, more the worse
///   the lag. Keyframes are big and expected to take longer, so they don't count.
/// - **Size** (`scale`): once the bitrate is too low for the stream's size for
///   a while, it is captured smaller (each side ¾, then ½), which looks
///   better than a blurry full size and makes keyframes, the one thing the
///   bitrate doesn't hold back, smaller in proportion; back up once the
///   bitrate would do the bigger size justice. `maxBitRate` stays the full size's.
///
/// Times are seconds on any monotonic clock; nothing here reads one.
struct StreamPacer {
    static let minWindow = 2
    static let maxWindow = 24
    /// The time between frames at the phone's frame rate (`setProfile`).
    private(set) var frameInterval: TimeInterval = 1.0 / 60
    /// The shortest trip is the minimum over this long, so a path that got slower (direct to relay) is learned again.
    static let minRTTSpan: TimeInterval = 10
    static let minBitRate = 400_000

    /// Lag behind the shortest trip (smoothed) that starts cutting, at least this or a quarter of the trip.
    static let lagToCut: TimeInterval = 0.04
    /// Under this lag the link has room: the bitrate may go up.
    static let lagToGrow: TimeInterval = 0.015
    static let growEvery: TimeInterval = 0.5
    static let growStep = 1.08

    /// What the phone's quality choice means here.
    struct Profile: Equatable {
        /// Each side's share of the full size it may be captured at, largest first.
        var scales: [Double]
        /// Smaller when the bitrate is under this share of what the current size takes, for `shrinkAfter`.
        var shrinkBelow: Double

        static func of(_ quality: ScreenVideoWire.Quality) -> Profile {
            switch quality {
            // Text first: the size goes only when the picture would be very blurry.
            case .sharp: Profile(scales: [1, 0.75, 0.5], shrinkBelow: 0.2)
            case .smooth: Profile(scales: [1, 0.75, 0.5], shrinkBelow: 0.35)
            // Motion first: a little smaller from the start, and smaller sooner.
            case .fast: Profile(scales: [0.75, 0.5], shrinkBelow: 0.5)
            }
        }
    }

    private(set) var profile = Profile.of(.sharp)
    static let shrinkAfter: TimeInterval = 2
    /// Bigger when it is at least this share of what the next size up takes, for `growAfter`.
    static let growAbove = 0.7
    static let growAfter: TimeInterval = 5
    /// Each change of size is a new capture and a keyframe: not more often than this.
    static let rescaleGap: TimeInterval = 5

    private(set) var maxBitRate: Int
    /// The share of the full size (each side) to capture at, from `scales`.
    private(set) var scale = 1.0
    private var lowSince: TimeInterval?
    private var highSince: TimeInterval?
    private var lastRescale = -TimeInterval.infinity
    private(set) var bitRate: Int
    /// The shortest round trip of the last `minRTTSpan`; nil before the first ack.
    private(set) var minRTT: TimeInterval?
    /// How far acks lag behind `minRTT`, smoothed.
    private(set) var lag: TimeInterval = 0

    private var sent: [UInt32: (time: TimeInterval, keyframe: Bool)] = [:]
    /// Round trips of the last `minRTTSpan` (and always the latest one).
    private var trips: [(time: TimeInterval, rtt: TimeInterval)] = []
    private var lastCut: TimeInterval = -.infinity
    private var lastGrow: TimeInterval = -.infinity
    private var smoothedRTT: TimeInterval?

    init(maxBitRate: Int) {
        self.maxBitRate = max(maxBitRate, Self.minBitRate)
        bitRate = self.maxBitRate
    }

    /// Frames that may be sent and not yet acked.
    var window: Int {
        guard let minRTT else { return Self.minWindow }
        let fit = Int((minRTT / frameInterval).rounded(.up)) + 1
        return min(max(fit, Self.minWindow), Self.maxWindow)
    }

    /// The phone's quality choice and frame rate; the scale moves into the profile's if it isn't one of them.
    mutating func setProfile(_ profile: Profile, fps: Int) {
        self.profile = profile
        frameInterval = 1 / Double(min(max(fps, 15), 120))
        if !profile.scales.contains(scale) {
            scale = profile.scales.first(where: { $0 <= scale }) ?? profile.scales[0]
        }
        lowSince = nil
        highSince = nil
    }

    /// The stream changed size: the same share of the new top bitrate.
    mutating func setMaxBitRate(_ rate: Int) {
        let rate = max(rate, Self.minBitRate)
        let share = Double(bitRate) / Double(maxBitRate)
        maxBitRate = rate
        bitRate = max(Self.minBitRate, min(rate, Int(Double(rate) * share)))
    }

    /// After an ack: a new `scale` to capture at, when the bitrate has been out
    /// of step with the size long enough; nil to stay.
    mutating func rescale(at now: TimeInterval) -> Double? {
        let scales = profile.scales
        guard let index = scales.firstIndex(of: scale) else { return nil }
        func share(_ scale: Double) -> Double { Double(bitRate) / (Double(maxBitRate) * scale * scale) }
        if index + 1 < scales.count, share(scale) < profile.shrinkBelow {
            highSince = nil
            let since = lowSince ?? now
            lowSince = since
            guard now - since >= Self.shrinkAfter, now - lastRescale >= Self.rescaleGap else { return nil }
            return changeScale(to: scales[index + 1], at: now)
        }
        lowSince = nil
        if index > 0, share(scales[index - 1]) >= Self.growAbove {
            let since = highSince ?? now
            highSince = since
            guard now - since >= Self.growAfter, now - lastRescale >= Self.rescaleGap else { return nil }
            return changeScale(to: scales[index - 1], at: now)
        }
        highSince = nil
        return nil
    }

    private mutating func changeScale(to new: Double, at now: TimeInterval) -> Double {
        scale = new
        lastRescale = now
        lowSince = nil
        highSince = nil
        return new
    }

    mutating func sent(_ number: UInt32, keyframe: Bool, at now: TimeInterval) {
        sent[number] = (now, keyframe)
    }

    /// Frame `number` is on the phone's screen (and every one before it is
    /// done with). True when `bitRate` changed.
    @discardableResult
    mutating func acked(_ number: UInt32, at now: TimeInterval) -> Bool {
        let frame = sent[number]
        sent = sent.filter { $0.key > number }
        guard let frame else { return false }
        let rtt = max(0, now - frame.time)
        trips.append((now, rtt))
        trips.removeAll { now - $0.time > Self.minRTTSpan }
        minRTT = trips.map(\.rtt).min()
        smoothedRTT = smoothedRTT.map { $0 * 0.875 + rtt * 0.125 } ?? rtt
        guard !frame.keyframe, let minRTT else { return false }
        lag = lag * 0.75 + (rtt - minRTT) * 0.25

        let before = bitRate
        if lag > max(Self.lagToCut, minRTT / 4) {
            // Once a round trip: what was sent before the last cut still arrives late.
            if now - lastCut >= max(0.25, smoothedRTT ?? 0) {
                let cut = lag > 0.25 ? 0.6 : lag > 0.1 ? 0.75 : 0.87
                bitRate = max(Self.minBitRate, Int(Double(bitRate) * cut))
                lastCut = now
                lastGrow = now
            }
        } else if lag < Self.lagToGrow, now - lastGrow >= Self.growEvery, now - lastCut >= 1 {
            bitRate = min(maxBitRate, Int(Double(bitRate) * Self.growStep))
            lastGrow = now
        }
        return bitRate != before
    }
}
