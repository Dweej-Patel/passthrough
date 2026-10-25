import XCTest
@testable import ShellHost

final class ShellQuestionTests: XCTestCase {
    private func find(_ text: String) -> String? { ShellQuestion.find(in: Data(text.utf8)) }

    /// A permission prompt drawn with cursor moves and colours, with a menu of choices under the question.
    func testAPromptAboveItsChoices() {
        let esc = "\u{1B}["
        let screen = "\(esc)2J\(esc)H\(esc)38;5;174m╭────────────╮\(esc)0m\(esc)2;1H│ Edit file \(esc)1mHomeView.swift\(esc)0m │"
            + "\(esc)4;1H Do you want to make this edit to HomeView.swift?"
            + "\(esc)5;1H\(esc)36m❯ 1. Yes\(esc)0m\(esc)6;1H  2. Yes, and don't ask again this session"
            + "\(esc)7;1H  3. No, and tell Claude what to do differently (esc)\(esc)8;1H\u{1B}]0;claude\u{07}"
        XCTAssertEqual(find(screen), "Do you want to make this edit to HomeView.swift?")
    }

    func testChoicesAndPasswordPrompts() {
        XCTAssertEqual(find("Removing 3 files\r\nProceed? [y/N] "), "Proceed? [y/N]")
        XCTAssertEqual(find("Overwrite config (y/n)"), "Overwrite config (y/n)")
        XCTAssertEqual(find("$ sudo pmset -g\r\nPassword:"), "Password:")
        XCTAssertEqual(find("[sudo] password for dev: "), "[sudo] password for dev:")
    }

    func testOrdinaryOutputIsNoQuestion() {
        XCTAssertNil(find("$ ls\r\nREADME.md  Package.swift\r\n$ "))
        XCTAssertNil(find("build finished in 34s\r\n"))
        XCTAssertNil(find("?\r\n"), "a lone question mark")
        XCTAssertNil(find("GET /search?q=x\r\n"), "a URL is not a question")
        XCTAssertNil(find(""))
    }

    /// Only the last lines count: a question long scrolled away is not what it waits on.
    func testAQuestionScrolledFarAwayIsIgnored() {
        let lines = ["Continue with the update?"] + (1...20).map { "compiling module \($0)" }
        XCTAssertNil(find(lines.joined(separator: "\r\n")))
    }

    func testLongQuestionsAreShortened() {
        let question = "Do you want to " + String(repeating: "really ", count: 30) + "continue?"
        let found = try? XCTUnwrap(find(question))
        XCTAssertEqual(found?.count, ShellQuestion.maxLength)
        XCTAssertEqual(found?.last, "…")
    }
}
