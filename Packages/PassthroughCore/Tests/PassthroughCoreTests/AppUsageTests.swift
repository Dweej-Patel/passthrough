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

private struct StubResolver: AppResolver {
    var apps: [Int32: AppIdentity] = [:]
    func identity(pid: Int32, processName: String) -> AppIdentity { apps[pid] ?? AppIdentity(key: processName, name: processName) }
}

final class AppUsageTallyTests: XCTestCase {
    private func rec(_ pid: Int32, _ name: String, _ bytesIn: Int64, _ bytesOut: Int64 = 0,
                     label: String = "tcp4 192.0.2.10:5000<->198.51.100.1:443", interface: String = "utun6") -> NettopRecord {
        NettopRecord(pid: pid, processName: name, label: label, interface: interface, bytesIn: bytesIn, bytesOut: bytesOut)
    }
    private func tally(_ resolver: StubResolver = StubResolver()) -> AppUsageTally { AppUsageTally(tracked: ["utun6"], resolver: resolver) }

    func testFirstSightingCountsTheRunningTotal() {
        var t = tally(); t.beginSample(); t.add(rec(1, "curl", 700, 50))
        XCTAssertEqual(t.top(5).map(\.total), [750])
    }

    func testLaterSamplesCountOnlyTheIncrease() {
        var t = tally()
        t.beginSample(); t.add(rec(1, "curl", 100))
        t.beginSample(); t.add(rec(1, "curl", 250))
        XCTAssertEqual(t.attributed, 250)
    }

    func testRestartDoesNotDoubleCount() {
        // A new nettop batch reports the same socket's running total again.
        var t = tally()
        t.beginSample(); t.add(rec(1, "curl", 100))
        t.beginSample(); t.add(rec(1, "curl", 250))
        t.beginSample(); t.add(rec(1, "curl", 300))
        XCTAssertEqual(t.attributed, 300)
    }

    func testSocketMissingFromASampleIsForgotten() {
        var t = tally()
        t.beginSample(); t.add(rec(1, "curl", 500))
        t.beginSample()
        t.beginSample(); t.add(rec(1, "curl", 100))
        XCTAssertEqual(t.attributed, 600)
    }

    func testSmallerTotalIsANewSocket() {
        var t = tally()
        t.beginSample(); t.add(rec(1, "curl", 500))
        t.beginSample(); t.add(rec(1, "curl", 100))
        XCTAssertEqual(t.attributed, 600)
    }

    func testOnlyTrackedInterfacesCount() {
        var t = tally()
        t.beginSample()
        t.add(rec(1, "curl", 500, interface: "en0"))
        t.add(rec(2, "zoom", 40, label: "udp4 a<->b", interface: "utun6"))
        XCTAssertEqual(t.top(5).map(\.app.name), ["zoom"])
    }

    func testChangingTrackedMidSessionCountsOnlyNewGrowth() {
        var t = tally()
        t.beginSample(); t.add(rec(1, "curl", 100, interface: "utun9"))
        t.tracked = ["utun9"]
        t.beginSample(); t.add(rec(1, "curl", 150, interface: "utun9"))
        XCTAssertEqual(t.attributed, 50)
    }

    func testHelpersRollUpIntoTheirApp() {
        let chrome = AppIdentity(key: "/Applications/Google Chrome.app", name: "Google Chrome")
        var t = tally(StubResolver(apps: [10: chrome, 11: chrome]))
        t.beginSample()
        t.add(rec(10, "Google Chrome", 300))
        t.add(rec(11, "Google Chrome He", 200, label: "tcp4 192.0.2.10:6000<->198.51.100.2:443"))
        XCTAssertEqual(t.top(5), [AppUsageEntry(app: chrome, bytesIn: 500, bytesOut: 0)])
    }

    func testTopOrdersByTotalThenNameAndLimits() {
        var t = tally(); t.beginSample()
        for (i, (name, bytes)) in [("b", 10), ("a", 10), ("c", 30), ("d", 5)].enumerated() {
            t.add(rec(Int32(i), name, Int64(bytes), label: "tcp4 \(i)"))
        }
        XCTAssertEqual(t.top(3).map(\.app.name), ["c", "a", "b"])
    }

    func testOtherIsTheUnattributedRemainderNeverNegative() {
        var t = tally(); t.beginSample(); t.add(rec(1, "curl", 700))
        XCTAssertEqual(t.other(sessionTotal: 1000), 300)
        XCTAssertEqual(t.other(sessionTotal: 500), 0)
    }

    func testResetStartsAFreshSession() {
        var t = tally(); t.beginSample(); t.add(rec(1, "curl", 700))
        t.reset()
        XCTAssertEqual(t.attributed, 0)
        t.beginSample(); t.add(rec(1, "curl", 800))
        XCTAssertEqual(t.attributed, 800, "a socket seen before the reset counts from its full total")
    }
}

final class AppBundleTests: XCTestCase {
    func testHelperRollsUpToTheOutermostApp() {
        XCTAssertEqual(AppBundle.outermost(inExecutablePath: "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Helpers/Google Chrome Helper.app/Contents/MacOS/Google Chrome Helper"),
                       "/Applications/Google Chrome.app")
    }
    func testAppExecutable() {
        XCTAssertEqual(AppBundle.outermost(inExecutablePath: "/System/Applications/Music.app/Contents/MacOS/Music"), "/System/Applications/Music.app")
    }
    func testPlainBinaryHasNoBundle() {
        XCTAssertNil(AppBundle.outermost(inExecutablePath: "/usr/bin/curl"))
        XCTAssertNil(AppBundle.outermost(inExecutablePath: "/Users/me/my.apps/bin/tool"))
    }
}

final class BatchRestartPolicyTests: XCTestCase {
    func testFullBatchesAlwaysRelaunch() {
        var p = BatchRestartPolicy()
        for _ in 0..<10 { XCTAssertTrue(p.shouldRelaunch(afterRunOf: 60)) }
    }
    func testThreeQuickExitsInARowGiveUp() {
        var p = BatchRestartPolicy()
        XCTAssertTrue(p.shouldRelaunch(afterRunOf: 0.1))
        XCTAssertTrue(p.shouldRelaunch(afterRunOf: 0.1))
        XCTAssertFalse(p.shouldRelaunch(afterRunOf: 0.1))
    }
    func testAFullBatchResetsTheCount() {
        var p = BatchRestartPolicy()
        _ = p.shouldRelaunch(afterRunOf: 0.1); _ = p.shouldRelaunch(afterRunOf: 0.1)
        XCTAssertTrue(p.shouldRelaunch(afterRunOf: 60))
        XCTAssertTrue(p.shouldRelaunch(afterRunOf: 0.1))
    }
}

#if os(macOS)
/// Runs the real `nettop` once: if a macOS update changes its output, this
/// fails instead of the panel silently going empty.
final class NettopSmokeTests: XCTestCase {
    func testEveryLineOfRealOutputParses() throws {
        let nettop = "/usr/bin/nettop"
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: nettop), "nettop not installed")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: nettop)
        process.arguments = ["-x", "-L", "1", "-J", "interface,bytes_in,bytes_out"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()

        var parser = NettopParser()
        var headers = 0, processes = 0, connections = 0
        var unparsed: [String] = []
        for line in output.split(separator: "\n") {
            switch parser.parse(line) {
            case .header: headers += 1
            case .process: processes += 1
            case .connection: connections += 1
            case .skipped: unparsed.append(String(line))
            }
        }
        XCTAssertEqual(headers, 1)
        XCTAssertGreaterThan(processes, 0)
        XCTAssertGreaterThan(connections, 0)
        XCTAssertEqual(unparsed, [], "nettop's output format changed")
    }
}
#endif
