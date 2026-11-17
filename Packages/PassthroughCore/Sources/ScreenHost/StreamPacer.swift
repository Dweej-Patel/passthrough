import Foundation

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
///
/// Times are seconds on any monotonic clock; nothing here reads one.
struct StreamPacer {
    static let minWindow = 2
    static let maxWindow = 16
    static let frameInterval: TimeInterval = 1.0 / 60
    /// The shortest trip is the minimum over this long, so a path that got slower (direct to relay) is learned again.
    static let minRTTSpan: TimeInterval = 10
    static let minBitRate = 400_000

    /// Lag behind the shortest trip (smoothed) that starts cutting, at least this or a quarter of the trip.
    static let lagToCut: TimeInterval = 0.04
    /// Under this lag the link has room: the bitrate may go up.
    static let lagToGrow: TimeInterval = 0.015
    static let growEvery: TimeInterval = 0.5
    static let growStep = 1.08

    private(set) var maxBitRate: Int
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
        let fit = Int((minRTT / Self.frameInterval).rounded(.up)) + 1
        return min(max(fit, Self.minWindow), Self.maxWindow)
    }

    /// The stream changed size: the same share of the new top bitrate.
    mutating func setMaxBitRate(_ rate: Int) {
        let rate = max(rate, Self.minBitRate)
        let share = Double(bitRate) / Double(maxBitRate)
        maxBitRate = rate
        bitRate = max(Self.minBitRate, min(rate, Int(Double(rate) * share)))
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
