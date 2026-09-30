import XCTest
@testable import PhoneTransport

/// Lines taken from real `nettop -x -J interface,bytes_in,bytes_out` output,
/// with addresses moved to documentation ranges.
final class NettopParserTests: XCTestCase {
    private func parse(_ text: String) -> [NettopLine] {
        var parser = NettopParser()
        return text.split(separator: "\n", omittingEmptySubsequences: false).map { parser.parse($0) }
    }

    func testHeaderProcessAndConnectionRows() {
        let lines = parse("""
        ,interface,bytes_in,bytes_out,
        zoom.us.2028,,306168,48212,
        tcp6 2001:db8::5.51000<->2001:db8::9.443,utun6,306168,48212,
        udp4 192.0.2.10:56098<->198.51.100.9:443,en0,91727,4701,
        """)
        XCTAssertEqual(lines[0], .header)
        XCTAssertEqual(lines[1], .process(pid: 2028, name: "zoom.us"))
        XCTAssertEqual(lines[2], .connection(NettopRecord(pid: 2028, processName: "zoom.us", label: "tcp6 2001:db8::5.51000<->2001:db8::9.443",
                                                          interface: "utun6", bytesIn: 306168, bytesOut: 48212)))
        XCTAssertEqual(lines[3], .connection(NettopRecord(pid: 2028, processName: "zoom.us", label: "udp4 192.0.2.10:56098<->198.51.100.9:443",
                                                          interface: "en0", bytesIn: 91727, bytesOut: 4701)))
    }

    func testProcessNameWithDots() {
        XCTAssertEqual(parse(",interface,bytes_in,bytes_out,\ncom.apple.WebKit.Networking.812,,51234,4321,")[1],
                       .process(pid: 812, name: "com.apple.WebKit.Networking"))
    }

    func testListeningSocketWithEmptyCountsReadsAsZero() {
        let lines = parse(",interface,bytes_in,bytes_out,\nControlCenter.1370,,0,0,\ntcp4 *:7000<->*:*,,,,")
        XCTAssertEqual(lines[2], .connection(NettopRecord(pid: 1370, processName: "ControlCenter", label: "tcp4 *:7000<->*:*",
                                                          interface: "", bytesIn: 0, bytesOut: 0)))
    }

    func testTimestampedVariant() {
        let lines = parse("""
        time,,interface,bytes_in,bytes_out,
        23:05:53.461070,remoted.561,,3978,2570,
        23:05:53.339645,tcp4 192.0.2.10:51812<->198.51.100.4:5223,utun6,1514080,5883934,
        """)
        XCTAssertEqual(lines[0], .header)
        XCTAssertEqual(lines[1], .process(pid: 561, name: "remoted"))
        XCTAssertEqual(lines[2], .connection(NettopRecord(pid: 561, processName: "remoted", label: "tcp4 192.0.2.10:51812<->198.51.100.4:5223",
                                                          interface: "utun6", bytesIn: 1514080, bytesOut: 5883934)))
    }

    func testRowsWithoutContextAreSkipped() {
        // Before any header; a connection before any process; a connection right after a new header.
        let lines = parse("""
        zoom.us.2028,,1,1,
        ,interface,bytes_in,bytes_out,
        tcp4 192.0.2.10:1<->198.51.100.1:443,utun6,5,5,
        zoom.us.2028,,1,1,
        ,interface,bytes_in,bytes_out,
        tcp4 192.0.2.10:1<->198.51.100.1:443,utun6,5,5,
        """)
        XCTAssertEqual(lines, [.skipped, .header, .skipped, .process(pid: 2028, name: "zoom.us"), .header, .skipped])
    }

    func testMalformedLinesAreSkipped() {
        let lines = parse("""
        ,interface,bytes_in,bytes_out,
        zoom.us.2028,,1,1,
        tcp4 192.0.2.10:1<->198.51.100.1:443,utun6,lots,5,
        garbage

        noPid,,1,1,
        """)
        XCTAssertEqual(Array(lines[2...]), [.skipped, .skipped, .skipped, .skipped])
    }
}
