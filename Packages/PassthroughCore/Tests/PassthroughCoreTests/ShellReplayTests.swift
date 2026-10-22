import Foundation
import XCTest
@testable import PassthroughCore

final class ShellReplayTests: XCTestCase {
    /// What the user's iPhone recorded at 48 columns: zsh fills the line to the
    /// margin, then relies on autowrap ("v " wraps, "\r\e[K" clears the new line).
    private let recording: [ShellReplayChunk] = [
        .resize(cols: 48, rows: 20),
        .output(Data("janeappleseed@Janes-MacBook-Pro16 ~ % ".utf8)),
        .output(Data("python --v".utf8)),
        .output(Data("v \r\u{1b}[K".utf8)),
        .output(Data("ersion\r\n".utf8)),
    ]

    func testSizeStrings() {
        XCTAssertEqual(ShellReplay.sizeString(cols: 48, rows: 20), "48x20")
        XCTAssertEqual(ShellReplay.parseSize("48x20")?.cols, 48)
        XCTAssertEqual(ShellReplay.parseSize("48x20")?.rows, 20)
        for bad in ["", "48", "48x", "x20", "0x20", "48x0", "-1x5", "48x20x1", "1001x20", "a x b"] {
            XCTAssertNil(ShellReplay.parseSize(bad), bad)
        }
    }

    func testLargestGrid() {
        XCTAssertNil(ShellReplay.largestGrid([.output(Data("x".utf8))]))
        let grid = ShellReplay.largestGrid([.resize(cols: 48, rows: 40), .output(Data()), .resize(cols: 100, rows: 20)])
        XCTAssertEqual(grid?.cols, 100)
        XCTAssertEqual(grid?.rows, 40)
    }

    func testFitScaleOnlyShrinksAndStopsAtTheMinimum() {
        XCTAssertEqual(ShellReplay.fitScale(neededWidth: 300, neededHeight: 300, availableWidth: 600, availableHeight: 600, minimum: 0.5), 1)
        XCTAssertEqual(ShellReplay.fitScale(neededWidth: 800, neededHeight: 300, availableWidth: 600, availableHeight: 600, minimum: 0.5), 0.75)
        XCTAssertEqual(ShellReplay.fitScale(neededWidth: 300, neededHeight: 1200, availableWidth: 600, availableHeight: 600, minimum: 0.4), 0.5)
        XCTAssertEqual(ShellReplay.fitScale(neededWidth: 6000, neededHeight: 300, availableWidth: 600, availableHeight: 600, minimum: 0.5), 0.5)
        XCTAssertEqual(ShellReplay.fitScale(neededWidth: 300, neededHeight: 300, availableWidth: 0, availableHeight: 600, minimum: 0.5), 1)
    }

    /// The size goes out on the first line, so a phone sets 48 columns before
    /// feeding the prompt, and comes back the same.
    func testTranscriptLinesCarrySizesAndRoundTrip() throws {
        let lines = ShellReplay.transcriptLines(session: "s", recording)
        XCTAssertEqual(lines.first?.cols, 48)
        XCTAssertEqual(lines.first?.rows, 20)
        XCTAssertEqual(lines.dropFirst().compactMap(\.cols), [])
        XCTAssertEqual(lines.last?.done, true)
        XCTAssertEqual(lines.dropLast().compactMap(\.done), [])
        var collector = ShellReplay.Collector()
        for line in lines {
            let decoded = try ShellEnvelope.decode(line.encodedLine())
            collector.add(try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(decoded.data))), cols: decoded.cols, rows: decoded.rows)
        }
        var joined = Data()
        for case let .output(d) in recording { joined.append(d) }
        XCTAssertEqual(collector.chunks, [.resize(cols: 48, rows: 20), .output(joined)])
    }

    func testTranscriptLinesSplitOutputAndKeepResizesInPlace() {
        let chunks: [ShellReplayChunk] = [
            .resize(cols: 80, rows: 24), .output(Data("abcde".utf8)),
            .resize(cols: 40, rows: 10), .resize(cols: 41, rows: 11), .output(Data("fg".utf8)),
            .resize(cols: 50, rows: 12),
        ]
        let lines = ShellReplay.transcriptLines(session: "s", chunks, chunkSize: 2)
        XCTAssertEqual(lines.map { Data(base64Encoded: $0.data ?? "").map { String(decoding: $0, as: UTF8.self) } },
                       ["ab", "cd", "e", "fg", ""])
        XCTAssertEqual(lines.map(\.cols), [80, nil, nil, 41, 50])
        XCTAssertEqual(lines.map(\.rows), [24, nil, nil, 11, 12])
        XCTAssertEqual(lines.map(\.done), [nil, nil, nil, nil, true])
        XCTAssertTrue(lines.allSatisfy { $0.session == "s" && $0.t == ShellEnvelope.transcriptData })

        var collector = ShellReplay.Collector()
        for line in lines { collector.add(Data(base64Encoded: line.data ?? "") ?? Data(), cols: line.cols, rows: line.rows) }
        XCTAssertEqual(collector.chunks, [
            .resize(cols: 80, rows: 24), .output(Data("abcde".utf8)),
            .resize(cols: 41, rows: 11), .output(Data("fg".utf8)), .resize(cols: 50, rows: 12),
        ])
    }

    /// Small pieces of output are joined into full lines.
    func testTranscriptLinesJoinSmallOutput() {
        let chunks: [ShellReplayChunk] = [.resize(cols: 48, rows: 20)] + "abcde".map { .output(Data(String($0).utf8)) }
        let lines = ShellReplay.transcriptLines(session: "s", chunks, chunkSize: 2)
        XCTAssertEqual(lines.map { $0.data.flatMap { Data(base64Encoded: $0) }.map { String(decoding: $0, as: UTF8.self) } },
                       ["ab", "cd", "e"])
        XCTAssertEqual(lines.map(\.cols), [48, nil, nil])
    }

    func testEmptyReplayIsOneDoneLine() {
        let lines = ShellReplay.transcriptLines(session: "s", [])
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines[0].data, "")
        XCTAssertEqual(lines[0].done, true)
        XCTAssertNil(lines[0].cols)
    }

    /// An older Mac sends no sizes: just output.
    func testCollectorWithoutSizes() {
        var collector = ShellReplay.Collector()
        collector.add(Data("a".utf8))
        collector.add(Data("b".utf8), cols: 0, rows: 5)   // invalid: ignored
        XCTAssertEqual(collector.chunks, [.output(Data("ab".utf8))])
        XCTAssertNil(ShellReplay.largestGrid(collector.chunks))
    }
}
