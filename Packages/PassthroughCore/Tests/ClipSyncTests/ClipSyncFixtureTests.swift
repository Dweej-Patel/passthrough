import XCTest
@testable import PassthroughCore

/// Checks the Mac's clipboard sync against protocol/fixtures.json's `clipSync`, the file the Windows
/// tests read too, so the two sides agree byte for byte and decline the same things.
final class ClipSyncFixtureTests: XCTestCase {
    private func fixtures() throws -> [String: Any] {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while dir.path != "/" {
            let file = dir.appendingPathComponent("protocol/fixtures.json")
            if FileManager.default.fileExists(atPath: file.path) {
                let all = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
                return try XCTUnwrap(all["clipSync"] as? [String: Any])
            }
            dir.deleteLastPathComponent()
        }
        throw XCTSkip("protocol/fixtures.json not found")
    }

    private static func hex(_ s: String) -> Data {
        var data = Data()
        var i = s.startIndex
        while i < s.endIndex {
            let j = s.index(i, offsetBy: 2)
            data.append(UInt8(s[i..<j], radix: 16)!)
            i = j
        }
        return data
    }

    func testConstantsAndErrors() throws {
        let f = try fixtures()
        XCTAssertEqual(f["maxPayload"] as? Int, ClipSyncWire.maxPayload)
        XCTAssertEqual(f["maxChunk"] as? Int, ClipSyncWire.maxChunk)
        XCTAssertEqual(f["maxOpenTransfers"] as? Int, 4)
        let errors = try XCTUnwrap(f["errors"] as? [String])
        XCTAssertEqual(Set(errors), [ShellError.noScreenView, .clipSyncOff, .clipSyncUnavailable].map(\.rawValue).reduce(into: Set()) { $0.insert($1) })
    }

    func testMessagesByteForByte() throws {
        for m in try XCTUnwrap(fixtures()["messages"] as? [[String: Any]]) {
            let name = try XCTUnwrap(m["name"] as? String)
            let n = { (k: String) in UInt32(truncatingIfNeeded: (m[k] as? NSNumber)?.int64Value ?? 0) }
            let message: ClipSyncWire.Message
            switch name {
            case "hello": message = .hello(version: UInt8(n("version")))
            case "offer":
                message = .offer(.init(transfer: n("transfer"), kind: try XCTUnwrap(.init(rawValue: UInt8(n("kind")))),
                                       x: UInt16(n("x")), y: UInt16(n("y")), count: n("count"),
                                       total: UInt64(truncating: try XCTUnwrap(m["total"] as? NSNumber))))
            case "item":
                message = .item(transfer: n("transfer"), index: n("index"),
                                .init(format: try XCTUnwrap(.init(rawValue: UInt8(n("format")))), size: UInt64(n("size")),
                                      name: try XCTUnwrap(m["itemName"] as? String)))
            case "data": message = .data(transfer: n("transfer"), item: n("item"), bytes: Self.hex(try XCTUnwrap(m["bytes"] as? String)))
            case "done": message = .done(transfer: n("transfer"))
            case "abandon": message = .abandon(transfer: n("transfer"))
            case "decline": message = .decline(transfer: n("transfer"), reason: try XCTUnwrap(.init(rawValue: UInt8(n("reason")))))
            case "result": message = .result(transfer: n("transfer"), status: try XCTUnwrap(.init(rawValue: UInt8(n("status")))))
            default: XCTFail("unknown fixture message \(name)"); continue
            }
            let bytes = Self.hex(try XCTUnwrap(m["hex"] as? String))
            XCTAssertEqual(ClipSyncWire.encode(message), bytes, name)
            var reader = ClipSyncWire.Reader()
            XCTAssertEqual(try reader.append(bytes), [message], name)
        }
    }

    func testNames() throws {
        let f = try fixtures()
        for name in try XCTUnwrap(f["validNames"] as? [String]) { XCTAssertTrue(ClipSyncWire.isValidName(name), name.debugDescription) }
        for name in try XCTUnwrap(f["invalidNames"] as? [String]) { XCTAssertFalse(ClipSyncWire.isValidName(name), name.debugDescription) }
    }

    func testOffers() throws {
        for o in try XCTUnwrap(fixtures()["offers"] as? [[String: Any]]) {
            let offer = ClipSyncWire.Offer(transfer: 1, kind: try XCTUnwrap(.init(rawValue: UInt8(truncating: o["kind"] as! NSNumber))),
                                           count: UInt32(truncating: o["count"] as! NSNumber),
                                           total: UInt64(truncating: o["total"] as! NSNumber))
            let expected = (o["decline"] as? NSNumber).map { UInt8(truncating: $0) }
            XCTAssertEqual(ClipSyncWire.refusal(of: offer)?.rawValue, expected, "\(o)")
        }
    }

    func testTransfers() throws {
        for t in try XCTUnwrap(fixtures()["transfers"] as? [[String: Any]]) {
            let name = t["name"] as? String ?? "?"
            let offer = ClipSyncWire.Offer(transfer: 1, kind: try XCTUnwrap(.init(rawValue: UInt8(truncating: t["kind"] as! NSNumber))),
                                           count: UInt32(truncating: t["count"] as! NSNumber),
                                           total: UInt64(truncating: t["total"] as! NSNumber))
            var check = ClipSyncWire.ItemCheck(offer)
            var declined = false
            for i in try XCTUnwrap(t["items"] as? [[String: Any]]) {
                let item = ClipSyncWire.Item(rawFormat: UInt8(truncating: i["format"] as! NSNumber),
                                             size: UInt64(truncating: i["size"] as! NSNumber), name: i["name"] as? String ?? "")
                let got = check.refusal(of: item, index: UInt32(truncating: i["index"] as! NSNumber))
                let expected = (i["decline"] as? NSNumber).map { UInt8(truncating: $0) }
                XCTAssertEqual(got?.rawValue, expected, "\(name): \(i)")
                if got != nil { declined = true; break }
            }
            if !declined, let complete = t["complete"] as? Bool { XCTAssertEqual(check.isComplete, complete, name) }
        }
    }
}
