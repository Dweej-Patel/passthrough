#if os(macOS)
import Foundation

/// Paces a phone's typing into the Mac: text is posted a character event at a
/// time, synchronously, so a phone sending text as fast as it can would keep
/// the streamer (and the apps receiving it) busy without end. Typing and
/// short pastes go through at once (`burst`); more waits its turn at `rate`
/// UTF-8 bytes a second, with the keys that came after it kept behind it, and
/// past `limit` bytes waiting the rest is dropped. Not thread-safe: the
/// streamer's queue owns it.
struct TypingPacer {
    enum Item: Equatable {
        case text(String)
        case key(keysym: UInt32, modifiers: UInt8)
    }

    /// 8 KiB of UTF-8 a second (some 8 000 plain characters, 400 events),
    /// and typing or a paste of up to 8 KiB at once.
    static let rate: Double = 8192
    static let burst: Double = 8192
    static let limit = 256 << 10

    private let rate: Double
    private let burst: Double
    private let limit: Int
    private var tokens: Double
    private var refilledAt: TimeInterval
    private var waiting: [Item] = []
    private var waitingBytes = 0

    init(rate: Double = TypingPacer.rate, burst: Double = TypingPacer.burst, limit: Int = TypingPacer.limit, now: TimeInterval) {
        self.rate = rate
        self.burst = burst
        self.limit = limit
        tokens = burst
        refilledAt = now
    }

    var isEmpty: Bool { waiting.isEmpty }

    /// Queues `item`; false (and dropped) when too much text is waiting already.
    mutating func push(_ item: Item) -> Bool {
        if case let .text(text) = item {
            guard waitingBytes + text.utf8.count <= limit else { return false }
            waitingBytes += text.utf8.count
        }
        waiting.append(item)
        return true
    }

    /// What may be posted now, in order: keys cost nothing, text its UTF-8
    /// bytes. Text longer than what is left is split on a character boundary.
    mutating func take(now: TimeInterval) -> [Item] {
        tokens = min(burst, tokens + max(0, now - refilledAt) * rate)
        refilledAt = now
        var out: [Item] = []
        while let first = waiting.first {
            guard case let .text(text) = first else {
                out.append(waiting.removeFirst())
                continue
            }
            let bytes = text.utf8.count
            if Double(bytes) <= tokens {
                tokens -= Double(bytes)
                waitingBytes -= bytes
                out.append(waiting.removeFirst())
                continue
            }
            // Whole characters that fit; at least one once the bucket is full, so a huge one can't stall it.
            var head = "", used = 0
            for character in text {
                let size = character.utf8.count
                guard Double(used + size) <= tokens || (head.isEmpty && tokens >= burst) else { break }
                head.append(character)
                used += size
            }
            if !head.isEmpty {
                tokens -= Double(used)
                waitingBytes -= used
                out.append(.text(head))
                waiting[0] = .text(String(text.dropFirst(head.count)))
            }
            break
        }
        return out
    }

    /// How long until the next piece can go (a kilobyte, or what is left of
    /// the text waiting first), while something waits.
    var nextDelay: TimeInterval? {
        guard let first = waiting.first else { return nil }
        guard case let .text(text) = first else { return 0 }
        let needed = min(burst, Double(min(text.utf8.count, 1024)))
        return max(0.01, (needed - tokens) / rate)
    }
}
#endif
