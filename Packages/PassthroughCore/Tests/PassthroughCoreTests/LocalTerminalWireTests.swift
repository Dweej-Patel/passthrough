import XCTest
@testable import PassthroughCore

final class LocalTerminalWireTests: XCTestCase {
    func testFramesRoundTripHoweverTheBytesArrive() throws {
        let hello = LocalTerminalWire.Hello(mode: .hook, cols: 120, rows: 40, directory: "/tmp", environment: ["TERM": "xterm-256color"])
        let stream = LocalTerminalWire.encode(.hello, json: hello)
            + LocalTerminalWire.encode(.input, Data("ls\r".utf8))
            + LocalTerminalWire.encode(.replayed)
            + LocalTerminalWire.encodeResize(cols: 100, rows: 30)
        for step in [1, 3, 7, stream.count] {
            var parser = LocalTerminalWire.Parser()
            var frames: [LocalTerminalWire.Frame] = []
            var offset = 0
            while offset < stream.count {
                let end = min(offset + step, stream.count)
                frames += try parser.append(stream.subdata(in: offset..<end))
                offset = end
            }
            XCTAssertEqual(frames.map(\.kind), [.hello, .input, .replayed, .resize], "in pieces of \(step)")
            XCTAssertEqual(LocalTerminalWire.decode(LocalTerminalWire.Hello.self, from: frames[0]), hello)
            XCTAssertEqual(frames[1].payload, Data("ls\r".utf8))
            XCTAssertTrue(frames[2].payload.isEmpty)
            let size = try XCTUnwrap(LocalTerminalWire.decodeResize(frames[3].payload))
            XCTAssertEqual(size.cols, 100)
            XCTAssertEqual(size.rows, 30)
        }
    }

    func testAnUnknownKindIsSkippedAndTheNextFrameStillRead() throws {
        var parser = LocalTerminalWire.Parser()
        let unknown = Data([200, 0, 0, 0, 2, 9, 9])
        let frames = try parser.append(unknown + LocalTerminalWire.encode(.output, Data("ok".utf8)))
        XCTAssertEqual(frames, [LocalTerminalWire.Frame(.output, Data("ok".utf8))])
    }

    func testAPayloadOverTheLimitIsRefused() {
        var parser = LocalTerminalWire.Parser()
        let length = UInt32(LocalTerminalWire.maxPayload + 1).bigEndian
        var header = Data([LocalTerminalWire.Kind.output.rawValue])
        withUnsafeBytes(of: length) { header.append(contentsOf: $0) }
        XCTAssertThrowsError(try parser.append(header)) { XCTAssertEqual($0 as? LocalTerminalWire.WireError, .tooLong) }
    }

    func testResizeClampsAndRejectsOtherLengths() {
        let frame = LocalTerminalWire.encodeResize(cols: 0, rows: 100_000)
        let size = LocalTerminalWire.decodeResize(frame.dropFirst(5))
        XCTAssertEqual(size?.cols, 1)
        XCTAssertEqual(size?.rows, Int(UInt16.max))
        XCTAssertNil(LocalTerminalWire.decodeResize(Data([0, 80, 0])))
    }

    /// A phone that knows nothing of `origin` still reads the list, and a
    /// session a phone opened is sent exactly as before.
    func testSessionOriginIsOnlySentForTheMacsOwnTerminals() throws {
        let phone = ShellSessionInfo(id: "A", title: "zsh", startedAt: 1, lastOutputAt: 2, running: true)
        let mac = ShellSessionInfo(id: "B", title: "zsh", startedAt: 1, lastOutputAt: 2, running: true, origin: ShellSessionInfo.originMac)
        let phoneJSON = String(decoding: try JSONEncoder().encode(phone), as: UTF8.self)
        XCTAssertFalse(phoneJSON.contains("origin"), phoneJSON)
        XCTAssertFalse(phone.isOnMac)
        let decoded = try JSONDecoder().decode(ShellSessionInfo.self, from: JSONEncoder().encode(mac))
        XCTAssertEqual(decoded, mac)
        XCTAssertTrue(decoded.isOnMac)
        let old = #"{"id":"C","title":"zsh","startedAt":1,"lastOutputAt":2,"running":true}"#
        XCTAssertNil(try JSONDecoder().decode(ShellSessionInfo.self, from: Data(old.utf8)).origin)
    }

    // MARK: A terminal's colours

    /// What Terminal.app answers, as it answers it (BEL-ended, four digits a channel).
    static let terminalAnswer: Data = {
        var text = "\u{1B}]10;rgb:e6ce/e6ce/e6ce\u{07}\u{1B}]11;rgb:213d/2743/33e7\u{07}"
        let palette = ["354e/4245/4bcf", "b480/55f1/47f9", "6c95/aad2/7107", "c4c4/acac/6262", "6d6d/9696/b4b4", "bdbd/7b7b/cdcd",
                       "7c16/cb85/ce42", "de68/e648/ec13", "46bd/5cd3/6d12", "e049/6c9a/5a49", "7965/be4a/7e0d", "e5e5/c8c8/7272",
                       "6767/b5b5/eded", "d3d3/8989/e5e5", "848c/de23/e13a", "e64a/ef7a/f63d"]
        for (index, colour) in palette.enumerated() { text += "\u{1B}]4;\(index);rgb:\(colour)\u{07}" }
        return Data((text + "\u{1B}[?1;2c").utf8)
    }()

    func testATerminalsAnswerBecomesItsColours() throws {
        XCTAssertTrue(TerminalColors.isComplete(Self.terminalAnswer))
        let theme = try XCTUnwrap(TerminalColors.parse(Self.terminalAnswer))
        XCTAssertEqual(theme.foreground, "#e6e6e6")
        XCTAssertEqual(theme.background, "#212734")
        XCTAssertEqual(theme.palette?.count, 16)
        XCTAssertEqual(theme.palette?[4], "#6d96b4")
        XCTAssertEqual(theme.palette?[15], "#e5eff5")
    }

    func testAnAnswerEndedTheOtherWayOrWithFewerDigitsIsReadToo() {
        let answer = Data("\u{1B}]11;rgb:1/2/f\u{1B}\\\u{1B}]10;rgb:ff/80/00\u{1B}\\\u{1B}[?62c".utf8)
        let theme = TerminalColors.parse(answer)
        XCTAssertEqual(theme?.background, "#1122ff")
        XCTAssertEqual(theme?.foreground, "#ff8000")
        XCTAssertNil(theme?.palette, "a palette is all 16 or nothing")
    }

    func testATerminalThatOnlySaysWhatItIsHasNoColours() {
        let answer = Data("\u{1B}[?1;2c".utf8)
        XCTAssertTrue(TerminalColors.isComplete(answer))
        XCTAssertNil(TerminalColors.parse(answer))
        XCTAssertFalse(TerminalColors.isComplete(Data("\u{1B}]11;rgb:0/0/0\u{07}".utf8)))
        XCTAssertNil(TerminalColors.parse(Data("\u{1B}]11;notacolour\u{07}\u{1B}]4;99;rgb:0/0/0\u{07}\u{1B}[?1c".utf8)))
    }

    func testOnlyWellFormedColoursAreKept() {
        let theme = ShellTheme(foreground: "#FFAA00", background: "red; rm -rf", palette: Array(repeating: "#000000", count: 15))
        XCTAssertEqual(theme.sanitized, ShellTheme(foreground: "#ffaa00"))
        XCTAssertNil(ShellTheme(background: "#12345").sanitized)
        XCTAssertNil(ShellTheme.rgb("#12345g"))
        XCTAssertEqual(ShellTheme.rgb("#102030")?.green, 0x20)
    }

    func testASessionWithoutAThemeIsSentAsBefore() throws {
        let plain = ShellSessionInfo(id: "A", title: "zsh", startedAt: 1, lastOutputAt: 2, running: true)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(plain), as: UTF8.self).contains("theme"))
        let themed = ShellSessionInfo(id: "B", title: "zsh", startedAt: 1, lastOutputAt: 2, running: true, origin: ShellSessionInfo.originMac,
                                      theme: ShellTheme(foreground: "#ffffff", background: "#000000"))
        XCTAssertEqual(try JSONDecoder().decode(ShellSessionInfo.self, from: JSONEncoder().encode(themed)), themed)
    }
}
