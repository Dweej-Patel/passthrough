import XCTest
@testable import PassthroughCore

final class UTF8RepairTests: XCTestCase {
    private let mark: [UInt8] = [0xEF, 0xBF, 0xBD]

    func testValidTextPassesThroughUnchanged() {
        var repair = UTF8Repair()
        let text = "~/co/ner \u{E0B0} ❯ é 日本 😀 \u{1B}[33m"
        XCTAssertEqual(repair.repair(Data(text.utf8)), Array(text.utf8))
    }

    /// The prompt that showed the bug: a valid character, then two stray continuation bytes.
    func testEachStrayByteBecomesOneReplacement() {
        var repair = UTF8Repair()
        let input: [UInt8] = [0x24, 0xE2, 0x83, 0xA7, 0x83, 0x81, 0x32]
        XCTAssertEqual(repair.repair(Data(input)), [0x24, 0xE2, 0x83, 0xA7] + mark + mark + [0x32])
    }

    func testACharacterSplitAcrossChunksIsHeldThenPassed() {
        var repair = UTF8Repair()
        let bytes = Array("😀".utf8)
        XCTAssertEqual(repair.repair(Data([0x61] + bytes[0..<2])), [0x61])
        XCTAssertEqual(repair.repair(Data(bytes[2...] + [0x62])), bytes + [0x62])
    }

    func testAnUnfinishedCharacterFollowedByTextIsReplacedByteByByte() {
        var repair = UTF8Repair()
        XCTAssertEqual(repair.repair(Data([0xE2, 0x83])), [])
        XCTAssertEqual(repair.repair(Data([0x41])), mark + mark + [0x41])
    }

    func testOverlongSurrogateAndOutOfRangeAreReplaced() {
        var repair = UTF8Repair()
        XCTAssertEqual(repair.repair(Data([0xC0, 0xAF])), mark + mark)
        XCTAssertEqual(repair.repair(Data([0xED, 0xA0, 0x80])), mark + mark + mark)
        XCTAssertEqual(repair.repair(Data([0xF5, 0x41])), mark + [0x41])
    }

    /// A raw C1 byte (here 8-bit CSI) is not a control in a UTF-8 stream.
    func testRawC1ByteIsReplacedNotLeftAsAControl() {
        var repair = UTF8Repair()
        XCTAssertEqual(repair.repair(Data([0x9B, 0x32, 0x4A])), mark + [0x32, 0x4A])
    }

    func testResetDropsAHeldPartialCharacter() {
        var repair = UTF8Repair()
        _ = repair.repair(Data([0xE2, 0x83]))
        repair.reset()
        XCTAssertEqual(repair.repair(Data([0x41])), [0x41])
    }
}
