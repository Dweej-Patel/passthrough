import Foundation

/// What the device's keyboard takes for the text it is editing, while it types on
/// a Mac's screen. The keyboard needs a document to work as it does elsewhere: with
/// only "a key was pressed" to go by, iOS doesn't repeat a held delete, and offers no
/// dictation. So the screen view is a text input whose document is this: what was
/// typed lately, with the caret always at its end, and every change the keyboard
/// makes to it comes out as what to type on the Mac (`Edit`).
///
/// The Mac's real text isn't known, so before what was typed there is always some
/// `padding`: text that stands for whatever is in front of the Mac's caret, so
/// delete has something to delete (and goes on repeating) however much the Mac has.
/// Deleting into it deletes on the Mac just the same.
///
/// Text the keyboard is still composing (marked: a Chinese or Japanese candidate, a
/// dictation not yet settled) is kept here and typed on the Mac only once it's final.
///
/// Offsets and lengths are UTF-16 units, as the keyboard counts.
public struct KeyboardDocument: Equatable, Sendable {
    public enum Edit: Equatable, Sendable {
        /// Delete this many characters before the Mac's caret.
        case backspace(Int)
        case text(String)
    }

    /// Short words, so the keyboard's delete-by-word (a long hold) takes a few characters at a time.
    public static let padding = String(repeating: "x ", count: 512)
    /// What was typed is kept this long at most (`tidy`).
    public static let typedLimit = 512
    /// The most one change may delete on the Mac. The keyboard never asks for more in
    /// earnest; a change that would is cut short rather than wipe what's on the Mac.
    public static let maxBackspaces = 128

    private var content = KeyboardDocument.padding
    private var paddingLength = KeyboardDocument.padding.utf16.count
    private var markedLength = 0

    public init() {}

    public var length: Int { content.utf16.count }
    /// What the keyboard is composing, at the end; nil when nothing is.
    public var markedRange: NSRange? { markedLength > 0 ? NSRange(location: length - markedLength, length: markedLength) : nil }
    /// What was typed (and is on the Mac), after the padding and before anything marked.
    public var typed: String { substring(NSRange(location: paddingLength, length: length - paddingLength - markedLength)) }

    public func substring(_ range: NSRange) -> String {
        let range = clamped(range)
        return (content as NSString).substring(with: range)
    }

    /// The keyboard typed `text`: it replaces anything marked.
    public mutating func insert(_ text: String) -> [Edit] {
        dropMarked()
        content += text
        return text.isEmpty ? [] : [.text(text)]
    }

    /// The keyboard's delete: the character before the caret.
    public mutating func deleteBackward() -> [Edit] {
        guard length > 0 else { return [.backspace(1)] }
        let last = (content as NSString).rangeOfComposedCharacterSequence(at: length - 1)
        return replace(last, with: "")
    }

    /// The keyboard replaced `range` with `text` (a correction, a dictation revised,
    /// delete by word). On the Mac: back to where the range starts, then `text` and
    /// whatever followed the range again.
    public mutating func replace(_ range: NSRange, with text: String) -> [Edit] {
        var range = clamped(range)
        // Composing: the change stays here until it's final, unless it reaches back into what's on the Mac.
        if let marked = markedRange {
            if range.location >= marked.location {
                content = (content as NSString).replacingCharacters(in: range, with: text)
                markedLength += text.utf16.count - range.length
                return []
            }
            dropMarked()
            range = clamped(range)
        }
        let source = content as NSString
        let removed = source.substring(from: range.location)
        let kept = source.substring(from: range.location + range.length)
        content = source.replacingCharacters(in: range, with: text)
        paddingLength = min(paddingLength, range.location)
        var edits: [Edit] = []
        let backspaces = min(removed.count, Self.maxBackspaces)
        if backspaces > 0 { edits.append(.backspace(backspaces)) }
        // Cut short: what followed the range isn't typed again over text that was never deleted.
        let retyped = removed.count > Self.maxBackspaces ? text : text + kept
        if !retyped.isEmpty { edits.append(.text(retyped)) }
        return edits
    }

    /// The keyboard is composing `text` (nil or empty: nothing any more), in place of what it was composing.
    public mutating func setMarked(_ text: String?) {
        dropMarked()
        let text = text ?? ""
        content += text
        markedLength = text.utf16.count
    }

    /// What was being composed is final: typed on the Mac.
    public mutating func unmark() -> [Edit] {
        guard let marked = markedRange else { return [] }
        let text = substring(marked)
        markedLength = 0
        return [.text(text)]
    }

    /// The Mac's caret may be somewhere else now (a click, an arrow key, a shortcut):
    /// what was typed is forgotten, so no later correction reaches back for it.
    public mutating func forget() {
        self = KeyboardDocument()
    }

    /// Deleting used some padding up, or a lot has been typed.
    public var needsTidying: Bool {
        markedLength == 0 && (paddingLength < Self.padding.utf16.count || length - paddingLength > Self.typedLimit)
    }

    /// Full padding again, and only the end of what was typed. Every offset changes:
    /// the keyboard must be told the text changed around it.
    public mutating func tidy() {
        guard needsTidying else { return }
        var kept = Substring(typed)
        while kept.utf16.count > Self.typedLimit / 2 { kept = kept.dropFirst() }
        content = Self.padding + kept
        paddingLength = Self.padding.utf16.count
    }

    private mutating func dropMarked() {
        guard let marked = markedRange else { return }
        content = (content as NSString).replacingCharacters(in: marked, with: "")
        markedLength = 0
    }

    private func clamped(_ range: NSRange) -> NSRange {
        let start = min(max(range.location, 0), length)
        let end = min(max(range.location + range.length, start), length)
        return NSRange(location: start, length: end - start)
    }
}
