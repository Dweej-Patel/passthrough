import UIKit
import PassthroughCore
import ScreenClient

/// The screen view as a text input, so the device's keyboard works on it as it does
/// anywhere else: a held delete repeats, and dictation is offered. The text the
/// keyboard edits is a `KeyboardDocument` (what was typed lately, the caret always at
/// its end), and what the keyboard does to it is typed on the Mac. Nothing of it is
/// drawn: the Mac's screen shows the text.

final class ScreenTextPosition: UITextPosition {
    let offset: Int
    init(_ offset: Int) { self.offset = offset }
}

final class ScreenTextRange: UITextRange {
    let range: NSRange
    init(_ range: NSRange) { self.range = range }
    override var start: UITextPosition { ScreenTextPosition(range.location) }
    override var end: UITextPosition { ScreenTextPosition(range.location + range.length) }
    override var isEmpty: Bool { range.length == 0 }
}

extension ScreenCanvasView {
    // MARK: Typing

    func insertText(_ text: String) {
        send(document.insert(text), modifiers: takeModifiers())
    }

    func deleteBackward() {
        send(document.deleteBackward(), modifiers: takeModifiers())
    }

    /// Types the keyboard's change on the Mac; held modifiers go with its first key.
    private func send(_ edits: [KeyboardDocument.Edit], modifiers: [UInt32] = []) {
        var modifiers = modifiers
        for edit in edits {
            switch edit {
            case let .backspace(count):
                for _ in 0..<count {
                    onKey?(RFBKeys.backspace, modifiers)
                    modifiers = []
                }
            case let .text(text):
                onText?(text, modifiers)
                modifiers = []
            }
        }
        tidyLater()
    }

    /// Once typing pauses: the document back to its usual shape (the keyboard is told its text changed).
    private func tidyLater() {
        tidyWork?.cancel()
        guard document.needsTidying else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.document.needsTidying else { return }
            self.inputDelegate?.textWillChange(self)
            self.document.tidy()
            self.inputDelegate?.textDidChange(self)
        }
        tidyWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    /// The Mac's caret may have moved (a click, an arrow, a shortcut, a paste): what
    /// was typed is forgotten, so nothing the keyboard does later reaches back for it.
    func forgetTyped() {
        guard document != KeyboardDocument() else { return }
        tidyWork?.cancel()
        inputDelegate?.textWillChange(self)
        document.forget()
        inputDelegate?.textDidChange(self)
    }

    // MARK: The document, as the keyboard reads it

    private var caret: Int { document.length }

    private func offset(_ position: UITextPosition) -> Int {
        min(max((position as? ScreenTextPosition)?.offset ?? caret, 0), document.length)
    }

    func text(in range: UITextRange) -> String? {
        guard let range = range as? ScreenTextRange else { return nil }
        return document.substring(range.range)
    }

    func replace(_ range: UITextRange, withText text: String) {
        guard let range = range as? ScreenTextRange else { return }
        send(document.replace(range.range, with: text))
    }

    /// Always the end: there is no caret here to move (the Mac has it).
    var selectedTextRange: UITextRange? {
        get { ScreenTextRange(NSRange(location: caret, length: 0)) }
        set {}
    }

    var markedTextRange: UITextRange? { document.markedRange.map(ScreenTextRange.init) }

    var markedTextStyle: [NSAttributedString.Key: Any]? {
        get { nil }
        set {}
    }

    func setMarkedText(_ markedText: String?, selectedRange: NSRange) {
        document.setMarked(markedText)
    }

    func unmarkText() {
        send(document.unmark())
    }

    var beginningOfDocument: UITextPosition { ScreenTextPosition(0) }
    var endOfDocument: UITextPosition { ScreenTextPosition(document.length) }

    func textRange(from fromPosition: UITextPosition, to toPosition: UITextPosition) -> UITextRange? {
        let start = offset(fromPosition), end = offset(toPosition)
        return ScreenTextRange(NSRange(location: min(start, end), length: abs(end - start)))
    }

    func position(from position: UITextPosition, offset: Int) -> UITextPosition? {
        let target = self.offset(position) + offset
        return (0...document.length).contains(target) ? ScreenTextPosition(target) : nil
    }

    func position(from position: UITextPosition, in direction: UITextLayoutDirection, offset: Int) -> UITextPosition? {
        self.position(from: position, offset: direction == .left || direction == .up ? -offset : offset)
    }

    func compare(_ position: UITextPosition, to other: UITextPosition) -> ComparisonResult {
        let a = offset(position), b = offset(other)
        return a < b ? .orderedAscending : (a > b ? .orderedDescending : .orderedSame)
    }

    func offset(from: UITextPosition, to toPosition: UITextPosition) -> Int {
        offset(toPosition) - offset(from)
    }

    func position(within range: UITextRange, farthestIn direction: UITextLayoutDirection) -> UITextPosition? {
        direction == .left || direction == .up ? range.start : range.end
    }

    func characterRange(byExtending position: UITextPosition, in direction: UITextLayoutDirection) -> UITextRange? {
        let at = offset(position)
        return direction == .left || direction == .up
            ? ScreenTextRange(NSRange(location: 0, length: at))
            : ScreenTextRange(NSRange(location: at, length: document.length - at))
    }

    func baseWritingDirection(for position: UITextPosition, in direction: UITextStorageDirection) -> NSWritingDirection { .natural }
    func setBaseWritingDirection(_ writingDirection: NSWritingDirection, for range: UITextRange) {}

    // MARK: Where the text is (nowhere: the bottom edge, so nothing the keyboard shows covers the screen)

    private var caretPlace: CGRect { CGRect(x: bounds.midX, y: bounds.maxY - 1, width: 1, height: 1) }

    func firstRect(for range: UITextRange) -> CGRect { caretPlace }
    func caretRect(for position: UITextPosition) -> CGRect { caretPlace }
    func selectionRects(for range: UITextRange) -> [UITextSelectionRect] { [] }
    func closestPosition(to point: CGPoint) -> UITextPosition? { endOfDocument }
    func closestPosition(to point: CGPoint, within range: UITextRange) -> UITextPosition? { range.end }
    func characterRange(at point: CGPoint) -> UITextRange? { nil }
}
