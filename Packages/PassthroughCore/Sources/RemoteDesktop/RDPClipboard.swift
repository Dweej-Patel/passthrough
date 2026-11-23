import Foundation
import ScreenClient

/// The rules for a PC's clipboard, apart from the channel that carries it:
/// text only, and only on a tap.
///
/// Copy: the PC is sent Control + Insert and a short window opens. If the PC's
/// clipboard changes within it and holds text, that text is fetched; a change
/// at any other time is never fetched, and its answer is taken only within
/// `fetchWait`, so the PC cannot push its clipboard here.
///
/// Paste: the text is offered to the PC, Shift + Insert goes once the PC has
/// taken the offer (or after a moment), and the offer is withdrawn soon after:
/// until then the PC may ask for it any number of times (its clipboard history
/// asks too); after, it is refused.
public struct RDPClipboard: Sendable {
    /// How long after Copy the PC's clipboard may change and still be taken.
    public static let copyWindow: TimeInterval = 2
    /// How long the PC has to answer a fetch; a later answer is dropped.
    public static let fetchWait: TimeInterval = 3
    /// How long Shift + Insert waits for the PC to take the offer.
    public static let pasteWait: TimeInterval = 0.5
    /// How long pasted text stays on offer.
    public static let offerLifetime: TimeInterval = 10
    /// The most text either way: 1 MiB of UTF-16, its terminator included.
    public static let maxUnits = (1 << 20) / 2 - 1

    public enum Effect: Equatable, Sendable {
        /// Ask the PC for its clipboard's text.
        case fetch
        case copied(ScreenCopyResult)
        /// Send Shift + Insert.
        case paste
        /// Tell the PC this side has nothing any more.
        case withdraw
    }

    private var copyUntil: TimeInterval?
    private var fetchUntil: TimeInterval?
    private var pasteWaiting = false
    /// Counts offers, so an older offer's expiry doesn't withdraw a newer one.
    public private(set) var offer = 0
    private var offered = false

    public init() {}

    // MARK: Copy

    /// Copy was tapped at `now` (Control + Insert is sent by the caller).
    public mutating func copyAsked(now: TimeInterval) {
        copyUntil = now + Self.copyWindow
        fetchUntil = nil
    }

    /// The PC's clipboard changed.
    public mutating func changed(hasText: Bool, now: TimeInterval) -> Effect? {
        // The PC owns its clipboard again: an offer still standing is no longer this side's to withdraw (that would
        // empty what was just copied there).
        offered = false
        guard let until = copyUntil, now <= until else { return nil }
        copyUntil = nil
        guard hasText else { return .copied(.notText) }
        fetchUntil = now + Self.fetchWait
        return .fetch
    }

    /// The copy window ran out.
    public mutating func copyDeadline(now: TimeInterval) -> Effect? {
        guard let until = copyUntil, now >= until else { return nil }
        copyUntil = nil
        return .copied(.nothing)
    }

    /// The PC answered a fetch. An answer nobody asked for, or one after `fetchWait`, is dropped.
    public mutating func fetched(_ result: ScreenCopyResult, now: TimeInterval) -> Effect? {
        guard let until = fetchUntil, now <= until else { return nil }
        fetchUntil = nil
        return .copied(result)
    }

    /// `fetchWait` passed since the fetch: if the PC still hasn't answered, nothing was copied.
    public mutating func fetchDeadline(now: TimeInterval) -> Effect? {
        guard let until = fetchUntil, now >= until else { return nil }
        fetchUntil = nil
        return .copied(.nothing)
    }

    // MARK: Paste

    /// Paste was tapped with `units` UTF-16 units. Nil: too long, nothing is offered. Else the offer's number (offer the text to the PC).
    public mutating func pasteAsked(units: Int) -> Int? {
        guard units > 0, units <= Self.maxUnits else { return nil }
        offer += 1
        offered = true
        pasteWaiting = true
        return offer
    }

    /// The PC took the offer, or `pasteWait` passed: whichever comes first sends the paste.
    public mutating func pasteReady() -> Effect? {
        guard pasteWaiting else { return nil }
        pasteWaiting = false
        return .paste
    }

    /// `offerLifetime` passed since offer `number` was made.
    public mutating func offerExpired(_ number: Int) -> Effect? {
        guard offered, number == offer else { return nil }
        offered = false
        pasteWaiting = false
        return .withdraw
    }

    // MARK: Text

    /// Windows' line ends: every line break becomes CR LF.
    public static func windowsText(_ text: String) -> [UInt16] {
        var units: [UInt16] = []
        units.reserveCapacity(text.utf16.count)
        var previous: UInt16 = 0
        for unit in text.utf16 {
            if unit == 0x0A, previous != 0x0D { units.append(0x0D) }
            units.append(unit)
            previous = unit
        }
        return units
    }

    /// This device's line ends: CR LF becomes a line break.
    public static func deviceText(_ units: [UInt16]) -> String {
        String(decoding: units, as: UTF16.self).replacingOccurrences(of: "\r\n", with: "\n")
    }
}
