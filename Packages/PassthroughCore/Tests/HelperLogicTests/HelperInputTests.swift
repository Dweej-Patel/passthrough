import Security
import XCTest
@testable import HelperLogic

final class XPCInputTests: XCTestCase {
    func testPortIsCheckedInsteadOfTrapping() throws {
        XCTAssertEqual(try XPCInput.port([:], "p", default: 17890), 17890, "absent: the default")
        XCTAssertEqual(try XPCInput.port(["p": 1080], "p", default: 17890), 1080)
        XCTAssertEqual(try XPCInput.port(["p": NSNumber(value: 65535)], "p", default: 1), 65535)
        for bad: Any in [70000, 0, -1, Int.max, "1080", 1080.5, NSNumber(value: 1e20)] {
            XCTAssertThrowsError(try XPCInput.port(["p": bad], "p", default: 1), "\(bad)") { error in
                XCTAssertEqual(error as? XPCInput.Invalid, XPCInput.Invalid("p"))
            }
        }
    }

    func testIntegerRange() {
        XCTAssertEqual(try XPCInput.integer(["m": 1500], "m", in: 576...65535, default: 8500), 1500)
        XCTAssertThrowsError(try XPCInput.integer(["m": 100], "m", in: 576...65535, default: 8500))
        XCTAssertThrowsError(try XPCInput.integer(["m": 1_000_000], "m", in: 576...65535, default: 8500))
    }

    func testBool() {
        XCTAssertEqual(try XPCInput.bool([:], "b", default: true), true)
        XCTAssertEqual(try XPCInput.bool(["b": false], "b", default: true), false)
        XCTAssertThrowsError(try XPCInput.bool(["b": "yes"], "b", default: true))
    }

    func testStringRefusesControlCharactersAndLength() {
        XCTAssertEqual(try XPCInput.string(["s": "alice"], "s", maxLength: 8, default: ""), "alice")
        XCTAssertThrowsError(try XPCInput.string(["s": "alice\npassword"], "s", maxLength: 64, default: ""), "a newline splits the stdin lines")
        XCTAssertThrowsError(try XPCInput.string(["s": "a\0b"], "s", maxLength: 64, allowNewlines: true, default: ""))
        XCTAssertThrowsError(try XPCInput.string(["s": "123456789"], "s", maxLength: 8, default: ""))
        XCTAssertEqual(try XPCInput.string(["s": "a\nb"], "s", maxLength: 8, allowNewlines: true, default: ""), "a\nb")
        XCTAssertThrowsError(try XPCInput.string(["s": 5], "s", maxLength: 8, default: ""))
    }

    func testIPAddresses() {
        XCTAssertEqual(try XPCInput.ipAddresses(["d": ["1.1.1.1", "2606:4700:4700::1111"]], "d", maxCount: 4, default: []),
                       ["1.1.1.1", "2606:4700:4700::1111"])
        XCTAssertThrowsError(try XPCInput.ipAddresses(["d": ["dns.example"]], "d", maxCount: 4, default: []))
        XCTAssertThrowsError(try XPCInput.ipAddresses(["d": ["1.1.1.1; rm"]], "d", maxCount: 4, default: []))
        XCTAssertThrowsError(try XPCInput.ipAddresses(["d": Array(repeating: "1.1.1.1", count: 5)], "d", maxCount: 4, default: []))
        XCTAssertThrowsError(try XPCInput.ipAddresses(["d": "1.1.1.1"], "d", maxCount: 4, default: []))
    }
}

final class CodeRequirementTests: XCTestCase {
    /// Both forms must compile: a requirement Security can't parse makes the
    /// helper refuse every client.
    func testRequirementsCompile() {
        for debuggable in [true, false] {
            let text = CodeRequirement.client(team: "ABCDE12345", identifier: "dev.example.passthrough", allowDebuggable: debuggable)
            var requirement: SecRequirement?
            XCTAssertEqual(SecRequirementCreateWithString(text as CFString, [], &requirement), errSecSuccess, text)
            XCTAssertNotNil(requirement)
        }
    }

    func testReleaseRequirementRefusesDebuggableClients() {
        let release = CodeRequirement.client(team: "ABCDE12345", identifier: "x", allowDebuggable: false)
        XCTAssertTrue(release.hasSuffix(" and !(entitlement[\"com.apple.security.get-task-allow\"] exists)"))
        XCTAssertTrue(release.contains("identifier \"x.mac\""))
        XCTAssertFalse(CodeRequirement.client(team: "ABCDE12345", identifier: "x", allowDebuggable: true).contains("get-task-allow"))
    }

    func testTeamValidation() {
        XCTAssertTrue(CodeRequirement.isValidTeam("ABCDE12345"))
        XCTAssertFalse(CodeRequirement.isValidTeam(""))
        XCTAssertFalse(CodeRequirement.isValidTeam("ABC\" or true or \""))
        XCTAssertFalse(CodeRequirement.isValidTeam("abcde12345"))
    }
}
