import PassthroughCore
import ScreenClient
import XCTest
@testable import RemoteDesktop

final class WindowsShortcutTests: XCTestCase {
    private typealias K = WindowsKeymap
    private let delete = WindowsKeymap.Scancode(0x53, extended: true)
    private let left = WindowsKeymap.Scancode(0x4B, extended: true)
    private let right = WindowsKeymap.Scancode(0x4D, extended: true)

    private func chord(_ modifiers: [WindowsKeymap.Scancode], _ key: WindowsKeymap.Scancode) -> [WindowsKeymap.Stroke] {
        modifiers.map { .key($0, down: true) } + [.key(key, down: true), .key(key, down: false)] + modifiers.reversed().map { .key($0, down: false) }
    }

    func testTheWindowsMenu() {
        XCTAssertEqual(WindowsShortcut.ctrlAltDel.strokes, chord([K.control, K.alt], delete))
        XCTAssertEqual(WindowsShortcut.start.strokes, chord([], K.windows))
        XCTAssertEqual(WindowsShortcut.taskView.strokes, chord([K.windows], K.tab))
        XCTAssertEqual(WindowsShortcut.altTab.strokes, chord([K.alt], K.tab))
        XCTAssertEqual(WindowsShortcut.showDesktop.strokes, chord([K.windows], K.Scancode(0x20)))   // D
        XCTAssertEqual(WindowsShortcut.closeWindow.strokes, chord([K.alt], K.Scancode(0x3E)))       // F4
        XCTAssertEqual(WindowsShortcut.delete.strokes, chord([], delete))
    }

    func testFunctionKeys() {
        for number in 1...10 {
            XCTAssertEqual(WindowsShortcut.function(number).strokes, chord([], K.Scancode(0x3B + UInt8(number - 1))))
        }
        XCTAssertEqual(WindowsShortcut.function(11).strokes, chord([], K.Scancode(0x57)))
        XCTAssertEqual(WindowsShortcut.function(12).strokes, chord([], K.Scancode(0x58)))
    }

    func testVirtualDesktops() {
        XCTAssertEqual(WindowsShortcut.nextDesktop.strokes, chord([K.control, K.windows], right))
        XCTAssertEqual(WindowsShortcut.previousDesktop.strokes, chord([K.control, K.windows], left))
    }

    /// Copy is Control + Insert (Control + C would stop a program in a console); paste is Shift + Insert.
    func testCopyAndPasteUseInsert() {
        XCTAssertEqual(WindowsShortcut.copy.strokes, chord([K.control], K.insert))
        XCTAssertEqual(WindowsShortcut.paste.strokes, chord([K.shift], K.insert))
        XCTAssertFalse(WindowsShortcut.copy.strokes.contains(.key(K.Scancode(0x2E), down: true)))   // C
    }

    func testEveryShortcutIsScanCodesOnly() {
        let all: [WindowsShortcut] = [.ctrlAltDel, .start, .taskView, .altTab, .showDesktop, .closeWindow, .delete, .nextDesktop,
                                      .previousDesktop, .copy, .paste] + (1...12).map { .function($0) }
        for shortcut in all {
            XCTAssertFalse(shortcut.strokes.isEmpty, "\(shortcut)")
            for stroke in shortcut.strokes {
                if case .unicode = stroke { XCTFail("\(shortcut) sends a Unicode event") }
            }
        }
    }

    func testCommandIsControlUnlessTheUserChoseTheWindowsKey() {
        XCTAssertEqual(WindowsShortcut.modifiers([.command], commandIsWindows: false), [.command])
        XCTAssertEqual(K.modifierScancodes(WindowsShortcut.modifiers([.command], commandIsWindows: false)), [K.control])
        XCTAssertEqual(WindowsShortcut.modifiers([.command, .shift], commandIsWindows: true), [.windows, .shift])
        XCTAssertEqual(K.modifierScancodes(WindowsShortcut.modifiers([.command], commandIsWindows: true)), [K.windows])
        // Without ⌘ nothing changes either way.
        XCTAssertEqual(WindowsShortcut.modifiers([.control, .option], commandIsWindows: true), [.control, .option])
        // ⌘C with the default is Control + C at its US position.
        XCTAssertEqual(K.strokes(for: 0x63, modifiers: WindowsShortcut.modifiers([.command], commandIsWindows: false)),
                       chord([K.control], K.Scancode(0x2E)))
    }
}

final class RDPClipboardTests: XCTestCase {
    func testCopyTakesTextThePCOffersWithinTheWindow() {
        var clipboard = RDPClipboard()
        clipboard.copyAsked(now: 100)
        XCTAssertEqual(clipboard.changed(hasText: true, now: 100.3), .fetch)
        XCTAssertEqual(clipboard.fetched(.text("hello"), now: 100.5), .copied(.text("hello")))
        // The window closed with the fetch: its deadline says nothing more.
        XCTAssertNil(clipboard.copyDeadline(now: 103))
    }

    func testAnOfferNobodyAskedForIsNeverFetched() {
        var clipboard = RDPClipboard()
        XCTAssertNil(clipboard.changed(hasText: true, now: 50))
        clipboard.copyAsked(now: 100)
        // After the window.
        XCTAssertNil(clipboard.changed(hasText: true, now: 102.5))
        // And an answer nobody asked for is dropped.
        XCTAssertNil(clipboard.fetched(.text("pushed"), now: 102.6))
    }

    func testOneCopyFetchesOnce() {
        var clipboard = RDPClipboard()
        clipboard.copyAsked(now: 100)
        XCTAssertEqual(clipboard.changed(hasText: true, now: 100.1), .fetch)
        // A second change in the same window isn't fetched again.
        XCTAssertNil(clipboard.changed(hasText: true, now: 100.2))
        XCTAssertEqual(clipboard.fetched(.text("a"), now: 100.3), .copied(.text("a")))
        XCTAssertNil(clipboard.fetched(.text("b"), now: 100.4))
    }

    func testAnAnswerAfterTheFetchWaitIsDropped() {
        var clipboard = RDPClipboard()
        clipboard.copyAsked(now: 100)
        XCTAssertEqual(clipboard.changed(hasText: true, now: 100.5), .fetch)
        // The PC holds its answer back: the wait ends with nothing copied...
        XCTAssertNil(clipboard.fetchDeadline(now: 103))
        XCTAssertEqual(clipboard.fetchDeadline(now: 103.5), .copied(.nothing))
        // ...and the answer it sends later, when it chooses, is dropped.
        XCTAssertNil(clipboard.fetched(.text("swapped"), now: 400))
        // Same if the deadline hasn't run yet but the answer is late.
        clipboard.copyAsked(now: 500)
        XCTAssertEqual(clipboard.changed(hasText: true, now: 500.1), .fetch)
        XCTAssertNil(clipboard.fetched(.text("late"), now: 503.2))
        XCTAssertEqual(clipboard.fetchDeadline(now: 503.2), .copied(.nothing))
    }

    func testNothingSelectedAndNotText() {
        var clipboard = RDPClipboard()
        clipboard.copyAsked(now: 100)
        XCTAssertNil(clipboard.copyDeadline(now: 101))
        XCTAssertEqual(clipboard.copyDeadline(now: 102), .copied(.nothing))
        XCTAssertNil(clipboard.copyDeadline(now: 103))
        clipboard.copyAsked(now: 200)
        XCTAssertEqual(clipboard.changed(hasText: false, now: 200.5), .copied(.notText))
        XCTAssertNil(clipboard.copyDeadline(now: 203))
        clipboard.copyAsked(now: 300)
        XCTAssertEqual(clipboard.changed(hasText: true, now: 300.5), .fetch)
        XCTAssertEqual(clipboard.fetched(.tooLong, now: 301), .copied(.tooLong))
    }

    func testPasteGoesOnceWhenThePCTookTheOfferOrAfterAMoment() {
        var clipboard = RDPClipboard()
        let first = clipboard.pasteAsked(units: 5)
        XCTAssertEqual(first, 1)
        XCTAssertEqual(clipboard.pasteReady(), .paste)   // the PC's acknowledgement
        XCTAssertNil(clipboard.pasteReady())             // the timer after it
        XCTAssertNil(clipboard.pasteReady())
    }

    func testAnOfferLastsItsLifetimeAndANewerOneOutlivesTheOlder() {
        var clipboard = RDPClipboard()
        let first = clipboard.pasteAsked(units: 5)!
        _ = clipboard.pasteReady()
        let second = clipboard.pasteAsked(units: 7)!
        XCTAssertNotEqual(first, second)
        // The first offer's expiry doesn't withdraw the second.
        XCTAssertNil(clipboard.offerExpired(first))
        XCTAssertEqual(clipboard.offerExpired(second), .withdraw)
        XCTAssertNil(clipboard.offerExpired(second))
        // Withdrawn before the PC took it: no paste follows.
        XCTAssertNil(clipboard.pasteReady())
    }

    func testSizeCaps() {
        var clipboard = RDPClipboard()
        XCTAssertNil(clipboard.pasteAsked(units: 0))
        XCTAssertNil(clipboard.pasteAsked(units: RDPClipboard.maxUnits + 1))
        XCTAssertNotNil(clipboard.pasteAsked(units: RDPClipboard.maxUnits))
        // With its terminator, the most is exactly 1 MiB.
        XCTAssertEqual((RDPClipboard.maxUnits + 1) * 2, 1 << 20)
    }

    func testLineEnds() {
        XCTAssertEqual(RDPClipboard.windowsText("a\nb"), Array("a\r\nb".utf16))
        XCTAssertEqual(RDPClipboard.windowsText("a\r\nb\n"), Array("a\r\nb\r\n".utf16))
        XCTAssertEqual(RDPClipboard.deviceText(Array("a\r\nb\r\n".utf16)), "a\nb\n")
        XCTAssertEqual(RDPClipboard.deviceText(Array("😀 é".utf16)), "😀 é")
    }
}
