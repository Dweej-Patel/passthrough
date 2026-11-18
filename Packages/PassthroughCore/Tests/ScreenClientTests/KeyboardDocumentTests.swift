import XCTest
@testable import ScreenClient

final class KeyboardDocumentTests: XCTestCase {
    private let pad = KeyboardDocument.padding.utf16.count

    func testTypingAndDeleting() {
        var document = KeyboardDocument()
        XCTAssertEqual(document.length, pad)
        XCTAssertEqual(document.insert("hé"), [.text("hé")])
        XCTAssertEqual(document.insert("👍🏽"), [.text("👍🏽")])
        XCTAssertEqual(document.typed, "hé👍🏽")
        XCTAssertEqual(document.deleteBackward(), [.backspace(1)], "a whole emoji is one character")
        XCTAssertEqual(document.typed, "hé")
        XCTAssertEqual(document.deleteBackward(), [.backspace(1)])
        XCTAssertEqual(document.deleteBackward(), [.backspace(1)])
        XCTAssertEqual(document.typed, "")
        XCTAssertFalse(document.needsTidying)
    }

    /// Held delete: it goes on past what was typed, into the Mac's own text, for as long as it's held.
    func testDeleteGoesOnIntoThePadding() {
        var document = KeyboardDocument()
        _ = document.insert("a")
        for _ in 0..<300 { XCTAssertEqual(document.deleteBackward(), [.backspace(1)]) }
        XCTAssertEqual(document.length, pad - 299)
        XCTAssertTrue(document.needsTidying)
        document.tidy()
        XCTAssertEqual(document.length, pad)
        XCTAssertEqual(document.typed, "")
        XCTAssertFalse(document.needsTidying)
    }

    func testReplacingRetypesWhatFollowed() {
        var document = KeyboardDocument()
        _ = document.insert("teh cat")
        // "teh" → "the": back to its start, then the word and what followed it.
        XCTAssertEqual(document.replace(NSRange(location: pad, length: 3), with: "the"), [.backspace(7), .text("the cat")])
        XCTAssertEqual(document.typed, "the cat")
        // Two spaces → ". " at the end.
        _ = document.insert(" ")
        XCTAssertEqual(document.replace(NSRange(location: document.length - 1, length: 1), with: ". "), [.backspace(1), .text(". ")])
        XCTAssertEqual(document.typed, "the cat. ")
        // Delete by word: a range at the end with nothing in its place.
        XCTAssertEqual(document.replace(NSRange(location: pad + 4, length: 5), with: ""), [.backspace(5)])
        XCTAssertEqual(document.typed, "the ")
        // By word into the padding: its short words.
        _ = document.replace(NSRange(location: pad, length: 4), with: "")
        XCTAssertEqual(document.replace(NSRange(location: pad - 2, length: 2), with: ""), [.backspace(2)])
        XCTAssertEqual(document.typed, "")
    }

    func testAHugeDeletionIsCutShort() {
        var document = KeyboardDocument()
        _ = document.insert("abc")
        XCTAssertEqual(document.replace(NSRange(location: 0, length: document.length), with: ""), [.backspace(KeyboardDocument.maxBackspaces)])
        XCTAssertEqual(document.length, 0)
        XCTAssertEqual(document.deleteBackward(), [.backspace(1)], "still deletes with nothing left")
        document.tidy()
        XCTAssertEqual(document.length, pad)
        // Cut short, what followed isn't typed again.
        _ = document.insert(String(repeating: "y", count: 200) + " end")
        XCTAssertEqual(document.replace(NSRange(location: pad, length: 1), with: "Y"), [.backspace(KeyboardDocument.maxBackspaces), .text("Y")])
    }

    /// Text being composed (an input method's candidate, a dictation not settled) reaches the Mac only when it's final.
    func testMarkedTextIsTypedOnceFinal() {
        var document = KeyboardDocument()
        _ = document.insert("a")
        document.setMarked("ni")
        XCTAssertEqual(document.markedRange, NSRange(location: pad + 1, length: 2))
        XCTAssertEqual(document.typed, "a")
        document.setMarked("nih")
        XCTAssertEqual(document.deleteBackward(), [], "deleting what's composed stays here")
        XCTAssertEqual(document.markedRange, NSRange(location: pad + 1, length: 2))
        XCTAssertEqual(document.replace(NSRange(location: pad + 1, length: 2), with: "你"), [])
        XCTAssertEqual(document.unmark(), [.text("你")])
        XCTAssertNil(document.markedRange)
        XCTAssertEqual(document.typed, "a你")
        // Typing replaces what's composed; composing nothing ends it.
        document.setMarked("ha")
        XCTAssertEqual(document.insert("好"), [.text("好")])
        XCTAssertEqual(document.typed, "a你好")
        document.setMarked("x")
        document.setMarked(nil)
        XCTAssertNil(document.markedRange)
        XCTAssertEqual(document.unmark(), [])
        XCTAssertEqual(document.typed, "a你好")
        // A change reaching back before what's composed drops it and edits what's on the Mac.
        document.setMarked("zz")
        XCTAssertEqual(document.replace(NSRange(location: pad + 2, length: 3), with: "!"), [.backspace(1), .text("!")])
        XCTAssertEqual(document.typed, "a你!")
    }

    func testForgettingAndTidying() {
        var document = KeyboardDocument()
        _ = document.insert(String(repeating: "word ", count: 200))
        XCTAssertTrue(document.needsTidying)
        document.setMarked("m")
        XCTAssertFalse(document.needsTidying, "not while composing")
        _ = document.unmark()
        document.tidy()
        XCTAssertEqual(document.length, pad + KeyboardDocument.typedLimit / 2)
        XCTAssertTrue(document.typed.hasSuffix("word m"))
        document.forget()
        XCTAssertEqual(document, KeyboardDocument())
        // Ranges outside it are held to it.
        XCTAssertEqual(document.substring(NSRange(location: pad - 2, length: 50)), "x ")
        XCTAssertEqual(document.replace(NSRange(location: pad + 10, length: 5), with: "q"), [.text("q")])
    }
}
