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
}
