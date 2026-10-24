import XCTest
@testable import PassthroughCore

final class TerminalPasteTests: XCTestCase {
    /// A paste can't end the bracketed paste early and run what follows.
    func testCannotEndABracketedPaste() {
        let paste = TerminalPaste("echo hi\u{1B}[201~rm -rf ~\n")
        XCTAssertEqual(paste.text, "echo hi[201~rm -rf ~\n")
        let bytes = paste.bytes(bracketed: true)
        XCTAssertEqual(bytes, Array("\u{1B}[200~echo hi[201~rm -rf ~\n\u{1B}[201~".utf8))
        XCTAssertEqual(bytes.filter { $0 == 0x1B }.count, 2, "only the markers' escapes")
    }

    /// Control characters, DEL and C1 controls (8-bit CSI among them) are dropped; tabs and text stay.
    func testDropsControls() {
        XCTAssertEqual(TerminalPaste("a\u{03}b\u{04}\u{08}c\u{7F}\td\u{9B}31m\u{85}é👋").text, "abc\td31mé👋")
        XCTAssertEqual(TerminalPaste("\u{1B}]52;c;aGk=\u{07}").text, "]52;c;aGk=", "no OSC of its own")
    }

    /// Every kind of line break is one; outside a bracketed paste each goes as Return.
    func testLineBreaks() {
        let paste = TerminalPaste("one\r\ntwo\nthree\rfour")
        XCTAssertEqual(paste.text, "one\ntwo\nthree\nfour")
        XCTAssertEqual(paste.lineBreaks, 3)
        XCTAssertEqual(paste.bytes(bracketed: false), Array("one\rtwo\rthree\rfour".utf8))
        XCTAssertEqual(TerminalPaste("ls -la").lineBreaks, 0)
        XCTAssertEqual(TerminalPaste("ls -la\n").lineBreaks, 1, "a trailing line break runs it too")
        XCTAssertEqual(TerminalPaste("\r\n\r\n").lineBreaks, 2)
    }

    func testNothingLeft() {
        XCTAssertTrue(TerminalPaste("\u{1B}\u{03}").text.isEmpty)
    }
}
