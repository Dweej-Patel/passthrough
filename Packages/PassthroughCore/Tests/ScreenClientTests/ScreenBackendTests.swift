import Foundation
import XCTest
import PassthroughCore
@testable import ScreenClient

/// The seam between the screen view and what shows the screen: the neutral
/// types keep the Mac's wire values, and each client's endings map one to one.
final class ScreenBackendTests: XCTestCase {
    func testButtonsKeepTheirWireValues() {
        XCTAssertEqual(ScreenButtons.left.rawValue, RFBClient.Buttons.left.rawValue)
        XCTAssertEqual(ScreenButtons.middle.rawValue, RFBClient.Buttons.middle.rawValue)
        XCTAssertEqual(ScreenButtons.right.rawValue, RFBClient.Buttons.right.rawValue)
        let both: ScreenButtons = [.left, .right]
        XCTAssertEqual(RFBClient.Buttons(both).rawValue, 5)
    }

    func testModifierMaskValues() {
        XCTAssertEqual(MacStreamBackend.mask(.command), .command)
        XCTAssertEqual(MacStreamBackend.mask(.shift), .shift)
        XCTAssertEqual(MacStreamBackend.mask(.option), .option)
        XCTAssertEqual(MacStreamBackend.mask(.control), .control)
        // The Mac has no Windows key: it is left out, the rest kept.
        XCTAssertEqual(MacStreamBackend.mask([.windows, .shift]).rawValue, ScreenVideoWire.Modifiers.shift.rawValue)
    }

    func testModifiersFromKeysyms() {
        XCTAssertEqual(ScreenModifiers(keysyms: [RFBKeys.command, RFBKeys.shift]), [.command, .shift])
        XCTAssertEqual(ScreenModifiers(keysyms: [RFBKeys.alt, RFBKeys.windows]), [.option, .windows])
        XCTAssertEqual(ScreenModifiers(keysyms: [0x61]), [])
    }

    /// Held modifiers are pressed in one order, whatever order they were tapped in.
    func testRFBModifierOrderIsFixed() {
        XCTAssertEqual(ScreenModifiers(keysyms: [RFBKeys.command, RFBKeys.shift, RFBKeys.option, RFBKeys.control]).keysyms,
                       [RFBKeys.control, RFBKeys.option, RFBKeys.shift, RFBKeys.command])
    }

    func testFailureMapping() {
        XCTAssertEqual(ScreenSharingBackend.end(for: nil), .closedHere)
        XCTAssertEqual(ScreenSharingBackend.end(for: .loginFailed(nil)), .signIn(.wrongPassword))
        XCTAssertEqual(ScreenSharingBackend.end(for: .loginFailed("no")), .signIn(.wrongPassword))
        XCTAssertEqual(ScreenSharingBackend.end(for: .noLoginOffered), .identityMismatch)
        XCTAssertEqual(ScreenSharingBackend.end(for: .unsupportedServer), .unsupported("Screen Sharing"))
        XCTAssertEqual(ScreenSharingBackend.end(for: .protocolError("x")), .protocolError("x"))
        XCTAssertEqual(ScreenSharingBackend.end(for: .connectionLost), .connectionLost)
    }

    func testCopyResultMapping() {
        XCTAssertEqual(MacStreamBackend.copyResult(.text("a")), .text("a"))
        XCTAssertEqual(MacStreamBackend.copyResult(.nothing), .nothing)
        XCTAssertEqual(MacStreamBackend.copyResult(.tooLong), .tooLong)
        XCTAssertEqual(MacStreamBackend.copyResult(.notText), .notText)
    }

    func testLoginNeverPrintsItsPassword() {
        let login = ScreenLogin(username: "me", password: "hunter2")
        XCTAssertFalse(String(describing: login).contains("hunter2"))
        XCTAssertFalse(String(reflecting: login).contains("hunter2"))
        var dumped = ""
        dump(login, to: &dumped)
        XCTAssertFalse(dumped.contains("hunter2"))
        XCTAssertTrue(dumped.contains("me"))
    }
}
