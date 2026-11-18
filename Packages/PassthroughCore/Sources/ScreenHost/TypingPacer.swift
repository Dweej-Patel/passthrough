#if os(macOS)
import Foundation

/// Paces a phone's typing into the Mac: text is posted a character event at a
/// time, synchronously, so a phone sending text as fast as it can would keep
/// the streamer (and the apps receiving it) busy without end. Typing and
/// short pastes go through at once (`burst`); more waits its turn at `rate`
/// UTF-8 bytes a second, with the keys that came after it kept behind it, and
/// past `limit` bytes or `itemLimit` items (keys or texts) waiting the rest
/// is dropped. A paste's clipboard waits its turn too, so the ⌘V behind it
/// pastes it and not one sent after. Not thread-safe: the streamer's queue owns it.
struct TypingPacer {
    enum Item: Equatable {
        case text(String)
        case key(keysym: UInt32, modifiers: UInt8)
        /// Put on the Mac's clipboard: costs nothing to post, but its bytes count while it waits.
        case clipboard(String)
    }

    /// 8 KiB of UTF-8 a second (some 8 000 plain characters, 400 events),
    /// and typing or a paste of up to 8 KiB at once.
    static let rate: Double = 8192
    static let burst: Double = 8192
    static let limit = 256 << 10
    /// Keys cost no bytes, so they are counted: a phone sending keys behind
    /// text that waits could otherwise queue them without end.
    static let itemLimit = 4096
    /// How long a clipboard waits behind a shortcut (the ⌘V of the paste before it, usually): the
    /// app handles that ⌘V a moment after it's posted, and must find its own text on the clipboard.
    static let pasteSettle: TimeInterval = 0.15

    private let rate: Double
    private let burst: Double
    private let limit: Int
    private let itemLimit: Int
    private var tokens: Double
    private var refilledAt: TimeInterval
    /// Items still to go are `waiting[next...]`: taking one moves `next`
    /// on, and the spent front is cut off once it is most of the array, so
    /// draining costs O(1) per item however long the queue.
    private var waiting: [Item] = []
    private var next = 0
    private var waitingBytes = 0
    /// A clipboard isn't taken before this (`pasteSettle` after the last shortcut).
    private var clipboardNotBefore: TimeInterval = 0

    init(rate: Double = TypingPacer.rate, burst: Double = TypingPacer.burst, limit: Int = TypingPacer.limit,
         itemLimit: Int = TypingPacer.itemLimit, now: TimeInterval) {
        self.rate = rate
        self.burst = burst
        self.limit = limit
        self.itemLimit = itemLimit
        tokens = burst
        refilledAt = now
    }

    var isEmpty: Bool { next == waiting.count }
    /// Items waiting.
    var count: Int { waiting.count - next }

    /// Queues `item`; false (and dropped) when too much is waiting already.
    mutating func push(_ item: Item) -> Bool {
        guard count < itemLimit else { return false }
        if let bytes = item.waitingBytes {
            guard waitingBytes + bytes <= limit else { return false }
            waitingBytes += bytes
        }
        waiting.append(item)
        return true
    }

    private mutating func popFirst() -> Item {
        let item = waiting[next]
        next += 1
        if next == waiting.count {
            waiting.removeAll(keepingCapacity: true)
            next = 0
        } else if next >= 64, next * 2 >= waiting.count {
            waiting.removeFirst(next)
            next = 0
        }
        return item
    }

    /// What may be posted now, in order: keys cost nothing, text its UTF-8
    /// bytes. Text longer than what is left is split on a character boundary.
    mutating func take(now: TimeInterval) -> [Item] {
        tokens = min(burst, tokens + max(0, now - refilledAt) * rate)
        refilledAt = now
        var out: [Item] = []
        while next < waiting.count {
            guard case let .text(text) = waiting[next] else {
                if case .clipboard = waiting[next], now < clipboardNotBefore { break }
                if case let .key(_, modifiers) = waiting[next], modifiers != 0 { clipboardNotBefore = now + Self.pasteSettle }
                waitingBytes -= waiting[next].waitingBytes ?? 0
                out.append(popFirst())
                continue
            }
            let bytes = text.utf8.count
            if Double(bytes) <= tokens {
                tokens -= Double(bytes)
                waitingBytes -= bytes
                out.append(popFirst())
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
                waiting[next] = .text(String(text.dropFirst(head.count)))
            }
            break
        }
        return out
    }

    /// How long until the next piece can go (a kilobyte, or what is left of
    /// the text waiting first), while something waits.
    var nextDelay: TimeInterval? {
        guard next < waiting.count else { return nil }
        if case .clipboard = waiting[next] { return max(0, clipboardNotBefore - refilledAt) }
        guard case let .text(text) = waiting[next] else { return 0 }
        let needed = min(burst, Double(min(text.utf8.count, 1024)))
        return max(0.01, (needed - tokens) / rate)
    }
}

private extension TypingPacer.Item {
    /// What it holds against `limit` while it waits.
    var waitingBytes: Int? {
        switch self {
        case let .text(text), let .clipboard(text): text.utf8.count
        case .key: nil
        }
    }
}
#endif
