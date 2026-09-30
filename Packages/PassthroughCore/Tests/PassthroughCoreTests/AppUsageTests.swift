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

    /// Network.framework QUIC flows (macOS 27): no addresses, and the
    /// interface as its index. Taken as a process, the port read as a pid and
    /// the rows after it went to that "process".
    func testQUICRowsAreSocketsOfTheCurrentProcess() {
        let lines = parse("""
        ,interface,bytes_in,bytes_out,
        replicatord.1023,,2502261,1077056,
        udp6 *.64600<->*.*,,589042,0,
        quic6 .64600<->.65013,idx-25,1884483,1066214,
        quic4 .51000<->.443,idx-28,700,300,
        udp6 2001:db8::5.64600<->2001:db8::9.61171,utun6,28736,10842,
        ControlCenter.1081,,0,0,
        """)
        XCTAssertEqual(lines[3], .connection(NettopRecord(pid: 1023, processName: "replicatord", label: "quic6 .64600<->.65013",
                                                          interface: "idx-25", bytesIn: 1884483, bytesOut: 1066214)))
        XCTAssertEqual(lines[4], .connection(NettopRecord(pid: 1023, processName: "replicatord", label: "quic4 .51000<->.443",
                                                          interface: "idx-28", bytesIn: 700, bytesOut: 300)))
        XCTAssertEqual(lines[5], .connection(NettopRecord(pid: 1023, processName: "replicatord", label: "udp6 2001:db8::5.64600<->2001:db8::9.61171",
                                                          interface: "utun6", bytesIn: 28736, bytesOut: 10842)))
        XCTAssertEqual(lines[6], .process(pid: 1081, name: "ControlCenter"))
    }

    /// A socket kind this parser doesn't know is skipped, not taken for a
    /// process, and the rows after it stay with their process.
    func testUnknownSocketKindIsSkippedAndKeepsItsProcess() {
        let lines = parse("""
        ,interface,bytes_in,bytes_out,
        replicatord.1023,,1,1,
        sctp4 .5000<->.6000,idx-25,10,10,
        mptcp 192.0.2.10.5000,utun6,10,10,
        tcp4 192.0.2.10:1<->198.51.100.1:443,utun6,5,5,
        """)
        XCTAssertEqual(Array(lines[2...3]), [.skipped, .skipped])
        XCTAssertEqual(lines[4], .connection(NettopRecord(pid: 1023, processName: "replicatord", label: "tcp4 192.0.2.10:1<->198.51.100.1:443",
                                                          interface: "utun6", bytesIn: 5, bytesOut: 5)))
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

    /// A batch's first sample, which the tally drops: under load nettop's
    /// first sample can list sockets with counters not read yet (0).
    private func startBatch(_ t: inout AppUsageTally, _ records: NettopRecord...) {
        t.beginSample()
        records.forEach { t.add($0) }
    }

    /// One nettop sample: its header, then its rows. Growth is credited when
    /// the sample closes (the next header, or the end of the batch).
    private func sample(_ t: inout AppUsageTally, _ records: NettopRecord...) {
        t.beginSample()
        records.forEach { t.add($0) }
    }

    /// Sockets already open when counting starts (a VPN that was up before
    /// the session) are a baseline, not usage.
    func testFirstSampleIsABaseline() {
        var t = tally()
        startBatch(&t)
        sample(&t, rec(1, "curl", 1_000_000))
        sample(&t, rec(1, "curl", 1_000_500))
        t.endBatch()
        XCTAssertEqual(t.attributed, 500)
    }

    /// Measured under CPU load: a run's first sample lists some sockets at 0,
    /// the next at their real totals. Crediting that jump invented gigabytes.
    func testFirstSampleOfEveryBatchIsDropped() {
        var t = tally()
        startBatch(&t, rec(1, "java", 0))
        sample(&t, rec(1, "java", 47_000_000))
        sample(&t, rec(1, "java", 47_000_100))
        t.endBatch()
        startBatch(&t, rec(1, "java", 0))
        sample(&t, rec(1, "java", 47_000_200))
        t.endBatch()
        XCTAssertEqual(t.attributed, 200)
    }

    func testSocketOpenedAfterTheBaselineCountsFromItsStart() {
        var t = tally()
        startBatch(&t)
        sample(&t, rec(9, "idle", 1, label: "udp4 other", interface: "en0"))
        sample(&t, rec(1, "curl", 700, 50))
        t.endBatch()
        XCTAssertEqual(t.top(5).map(\.total), [750])
    }

    func testLaterSamplesCountOnlyTheIncrease() {
        var t = tally()
        startBatch(&t)
        sample(&t, rec(1, "curl", 100))
        sample(&t, rec(1, "curl", 250))
        sample(&t, rec(1, "curl", 400))
        t.endBatch()
        XCTAssertEqual(t.attributed, 300)
    }

    func testRestartDoesNotDoubleCount() {
        // A new nettop batch reports the same socket's running total again.
        var t = tally()
        startBatch(&t)
        sample(&t, rec(1, "curl", 100))
        sample(&t, rec(1, "curl", 250))
        t.endBatch()
        startBatch(&t)
        sample(&t, rec(1, "curl", 300))
        t.endBatch()
        XCTAssertEqual(t.attributed, 200)
    }

    func testRestartAfterATruncatedLastSampleDoesNotDoubleCount() {
        // The batch's last sample was cut short before the socket's row.
        var t = tally()
        startBatch(&t)
        sample(&t, rec(1, "curl", 100))
        sample(&t, rec(1, "curl", 200))
        sample(&t, rec(2, "other", 5, label: "tcp4 truncated"))
        t.endBatch()
        startBatch(&t)
        sample(&t, rec(1, "curl", 300))
        t.endBatch()
        XCTAssertEqual(t.top(5).first { $0.app.name == "curl" }?.total, 200)
    }

    /// nettop can leave a live socket out of a sample. Forgetting it then
    /// credited its whole total again when it was listed next.
    func testSocketMissingFromASampleIsRemembered() {
        let idle = rec(9, "idle", 1, label: "udp4 other", interface: "en0")
        var t = tally()
        startBatch(&t)
        sample(&t, idle)
        sample(&t, rec(1, "curl", 1_000_000_000))
        sample(&t, idle)
        sample(&t, rec(1, "curl", 1_000_000_100))
        t.endBatch()
        XCTAssertEqual(t.attributed, 1_000_000_100)
    }

    /// Closed sockets don't pile up: one missing for longer is forgotten, so
    /// a later socket with its label counts from zero.
    func testSocketMissingForLongIsForgotten() {
        let idle = rec(9, "idle", 1, label: "udp4 other", interface: "en0")
        var t = tally()
        startBatch(&t)
        sample(&t, idle)
        sample(&t, rec(1, "curl", 500))
        for _ in 0...AppUsageTally.forgetAfterMissedSamples { sample(&t, idle) }
        sample(&t, rec(1, "curl", 100))
        t.endBatch()
        XCTAssertEqual(t.attributed, 600)
    }

    func testSocketMissingJustUnderTheLimitIsRemembered() {
        let idle = rec(9, "idle", 1, label: "udp4 other", interface: "en0")
        var t = tally()
        startBatch(&t)
        sample(&t, idle)
        sample(&t, rec(1, "curl", 500))
        for _ in 0..<AppUsageTally.forgetAfterMissedSamples { sample(&t, idle) }
        sample(&t, rec(1, "curl", 600))
        t.endBatch()
        XCTAssertEqual(t.attributed, 600)
    }

    /// A reading of 0 is no reading: crediting the socket as new afterwards
    /// turned a 1 GB socket into 2 GB.
    func testZeroReadingIsNotANewSocket() {
        var t = tally()
        startBatch(&t)
        sample(&t, rec(9, "idle", 1, label: "udp4 other", interface: "en0"))
        sample(&t, rec(1, "curl", 1_000_000_000, 5_000))
        sample(&t, rec(1, "curl", 0, 0))
        sample(&t, rec(1, "curl", 1_000_000_000, 5_000))
        sample(&t, rec(1, "curl", 1_000_000_100, 5_010))
        t.endBatch()
        XCTAssertEqual(t.top(5).map { [$0.bytesIn, $0.bytesOut] }, [[1_000_000_100, 5_010]])
    }

    /// Nor is a lower reading: only growth past the highest counts, each
    /// direction on its own.
    func testLowerReadingIsNotANewSocket() {
        var t = tally()
        startBatch(&t)
        sample(&t, rec(9, "idle", 1, label: "udp4 other", interface: "en0"))
        sample(&t, rec(1, "curl", 500, 50))
        sample(&t, rec(1, "curl", 100, 80))
        sample(&t, rec(1, "curl", 520, 60))
        t.endBatch()
        XCTAssertEqual(t.top(5).map { [$0.bytesIn, $0.bytesOut] }, [[520, 80]])
    }

    /// A bad reading in a batch's last sample isn't credited either.
    func testZeroReadingAcrossARestartIsNotANewSocket() {
        var t = tally()
        startBatch(&t)
        sample(&t, rec(1, "curl", 100))
        sample(&t, rec(1, "curl", 200))
        sample(&t, rec(1, "curl", 0))
        t.endBatch()
        startBatch(&t, rec(1, "curl", 0))
        sample(&t, rec(1, "curl", 250))
        t.endBatch()
        XCTAssertEqual(t.attributed, 150)
    }

    /// A QUIC flow names its interface by index; tracking the tunnel by
    /// name and index credits it to its process.
    func testQUICFlowOnTheTunnelCounts() {
        var t = AppUsageTally(tracked: NettopInterface.names(["utun6"], index: { $0 == "utun6" ? 28 : 0 }), resolver: StubResolver())
        let quic = "quic6 .64600<->.443"
        startBatch(&t)
        sample(&t, rec(1, "Safari", 100, 10, label: quic, interface: "idx-28"), rec(2, "peer", 7, label: quic, interface: "idx-25"))
        sample(&t, rec(1, "Safari", 900, 40, label: quic, interface: "idx-28"), rec(2, "peer", 70, label: quic, interface: "idx-25"))
        t.endBatch()
        XCTAssertEqual(t.top(5), [AppUsageEntry(app: AppIdentity(key: "Safari", name: "Safari"), bytesIn: 800, bytesOut: 30)])
    }

    /// Captured on macOS 27 (link-local addresses moved to documentation
    /// ranges), fed through the parser as the sampler does. The QUIC flow's
    /// growth goes to replicatord (1023), not to a "process" 65013.
    func testRealSampleWithAQUICFlowCreditsItsProcess() {
        let capture = """
        ,interface,bytes_in,bytes_out,
        replicatord.1023,,2502261,1077056,
        udp6 2001:db8::5.64600<->2001:db8::9.61171,anri0,28736,10842,
        udp6 *.64600<->*.*,,589042,0,
        quic6 .64600<->.65013,idx-25,1884483,1066214,
        ControlCenter.1081,,0,0,
        tcp6 *.5000<->*.*,,,,
        tcp4 *:5000<->*:*,,,,
        """
        var t = AppUsageTally(tracked: NettopInterface.names(["utun9"], index: { $0 == "utun9" ? 25 : 0 }), resolver: StubResolver())
        var parser = NettopParser()
        for text in [capture, capture, capture.replacingOccurrences(of: "idx-25,1884483,1066214", with: "idx-25,1904483,1066714")] {
            for line in text.split(separator: "\n") {
                switch parser.parse(line) {
                case .header: t.beginSample()
                case .connection(let r): t.add(r)
                case .process, .skipped: break
                }
            }
        }
        t.endBatch()
        XCTAssertEqual(t.top(5), [AppUsageEntry(app: AppIdentity(key: "replicatord", name: "replicatord"), bytesIn: 20_000, bytesOut: 500)])
    }

    func testSameLabelOnAnotherInterfaceIsAnotherSocket() {
        // Unconnected UDP (mDNS) shares its label across interfaces.
        let mdns = "udp4 *:5353<->*:*"
        var t = tally()
        startBatch(&t)
        sample(&t, rec(1, "adb", 100, label: mdns), rec(1, "adb", 5_000, label: mdns, interface: "en0"))
        sample(&t, rec(1, "adb", 150, label: mdns), rec(1, "adb", 5_100, label: mdns, interface: "en0"))
        sample(&t, rec(1, "adb", 200, label: mdns), rec(1, "adb", 5_200, label: mdns, interface: "en0"))
        t.endBatch()
        XCTAssertEqual(t.attributed, 100)
    }

    func testDuplicateRowsInOneSampleAreSummed() {
        let mdns = "udp4 *:5353<->*:*"
        var t = tally()
        startBatch(&t)
        sample(&t, rec(1, "Chrome", 10, label: mdns), rec(1, "Chrome", 20, label: mdns))
        sample(&t, rec(1, "Chrome", 12, label: mdns), rec(1, "Chrome", 25, label: mdns))
        t.endBatch()
        XCTAssertEqual(t.attributed, 7)
    }

    func testOnlyTrackedInterfacesCount() {
        var t = tally()
        startBatch(&t)
        sample(&t, rec(9, "idle", 1, label: "udp4 other", interface: "en0"))
        sample(&t, rec(1, "curl", 500, interface: "en0"), rec(2, "zoom", 40, label: "udp4 a<->b", interface: "utun6"))
        t.endBatch()
        XCTAssertEqual(t.top(5).map(\.app.name), ["zoom"])
    }

    func testChangingTrackedMidSessionDoesNotAddHistory() {
        // Growth is credited against the tracked set when a sample closes, so
        // the sample read just before the switch counts; the socket's earlier
        // history (its first 100 bytes) does not.
        var t = tally()
        startBatch(&t)
        sample(&t, rec(1, "curl", 100, interface: "utun9"))
        sample(&t, rec(1, "curl", 120, interface: "utun9"))
        t.tracked = ["utun9"]
        sample(&t, rec(1, "curl", 150, interface: "utun9"))
        t.endBatch()
        XCTAssertEqual(t.attributed, 50)
    }

    func testHelpersRollUpIntoTheirApp() {
        let chrome = AppIdentity(key: "/Applications/Google Chrome.app", name: "Google Chrome")
        var t = tally(StubResolver(apps: [10: chrome, 11: chrome]))
        startBatch(&t)
        sample(&t, rec(9, "idle", 1, label: "udp4 other", interface: "en0"))
        sample(&t, rec(10, "Google Chrome", 300), rec(11, "Google Chrome He", 200, label: "tcp4 192.0.2.10:6000<->198.51.100.2:443"))
        t.endBatch()
        XCTAssertEqual(t.top(5), [AppUsageEntry(app: chrome, bytesIn: 500, bytesOut: 0)])
    }

    func testTopOrdersByTotalThenNameAndLimits() {
        var t = tally()
        startBatch(&t)
        sample(&t, rec(99, "idle", 1, label: "udp4 other", interface: "en0"))
        t.beginSample()
        for (i, (name, bytes)) in [("b", 10), ("a", 10), ("c", 30), ("d", 5)].enumerated() {
            t.add(rec(Int32(i), name, Int64(bytes), label: "tcp4 \(i)"))
        }
        t.endBatch()
        XCTAssertEqual(t.top(3).map(\.app.name), ["c", "a", "b"])
    }

    func testOtherIsTheUnattributedRemainder() {
        let curl = AppUsageEntry(app: AppIdentity(key: "curl", name: "curl"), bytesIn: 600, bytesOut: 100)
        // `attributed` counts apps beyond the top ones shown.
        XCTAssertEqual(AppUsageBreakdown(top: [curl], attributed: 800, sessionTotal: 1000).other, 200)
        XCTAssertEqual(AppUsageBreakdown(top: [curl], attributed: 800, sessionTotal: 1000).top, [curl])
        XCTAssertEqual(AppUsageBreakdown(top: [curl], attributed: 700, sessionTotal: 700).other, 0)
    }

    /// The apps never add up to more than the session total the card shows.
    func testAppsAreScaledToFitTheSessionTotal() {
        let a = AppUsageEntry(app: AppIdentity(key: "a", name: "a"), bytesIn: 600, bytesOut: 300)
        let b = AppUsageEntry(app: AppIdentity(key: "b", name: "b"), bytesIn: 333, bytesOut: 0)
        let shown = AppUsageBreakdown(top: [a, b], attributed: 1_500, sessionTotal: 1_000)
        XCTAssertEqual(shown.other, 0)
        XCTAssertEqual(shown.top.map(\.app.name), ["a", "b"])
        XCTAssertEqual(shown.top.map { [$0.bytesIn, $0.bytesOut] }, [[400, 200], [222, 0]])
        XCTAssertLessThanOrEqual(shown.top.reduce(0) { $0 + $1.total }, 1_000)
        XCTAssertEqual(AppUsageBreakdown(top: [a], attributed: 900, sessionTotal: 0).top.map(\.total), [0])
    }

    func testTrackedInterfacesIncludeTheirIndex() {
        XCTAssertEqual(NettopInterface.names(["utun6", "gone"], index: { $0 == "utun6" ? 28 : 0 }), ["utun6", "idx-28", "gone"])
        XCTAssertEqual(NettopInterface.names(["lo0"]), ["lo0", "idx-\(if_nametoindex("lo0"))"])
    }

    func testResetStartsAFreshSessionWithANewBaseline() {
        var t = tally()
        startBatch(&t)
        sample(&t, rec(9, "idle", 1, label: "udp4 other", interface: "en0"))
        sample(&t, rec(1, "curl", 700))
        t.endBatch()
        t.reset()
        XCTAssertEqual(t.attributed, 0)
        startBatch(&t)
        sample(&t, rec(1, "curl", 800))
        sample(&t, rec(1, "curl", 900))
        t.endBatch()
        XCTAssertEqual(t.attributed, 100)
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
/// Runs the real `nettop` with the production arguments: if a macOS update
/// changes its output, this fails instead of the panel silently going wrong.
final class NettopSmokeTests: XCTestCase {
    private func run(samples: Int) throws -> [(String, NettopLine)] {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: NettopCommand.path), "nettop not installed")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: NettopCommand.path)
        process.arguments = NettopCommand.arguments(samples: samples, interval: 1)
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        var parser = NettopParser()
        return output.split(separator: "\n").map { (String($0), parser.parse($0)) }
    }

    /// Every row must be one the parser positively recognises: a process
    /// row (name.pid, no interface or endpoints) or a known socket kind.
    /// Anything else, a new socket kind included, is skipped and fails here.
    func testEveryLineOfRealOutputParses() throws {
        let rows = try run(samples: 1)
        let lines = rows.map(\.1)
        XCTAssertEqual(lines.filter { $0 == .header }.count, 1)
        XCTAssertTrue(lines.contains { if case .process = $0 { return true }; return false })
        XCTAssertTrue(lines.contains { if case .connection = $0 { return true }; return false })
        let unrecognised = rows.filter { $0.1 == .skipped }.map(\.0)
        XCTAssertEqual(unrecognised, [], "nettop's output format changed")
        for (raw, line) in rows {
            switch line {
            case .connection(let r):
                XCTAssertTrue(NettopParser.socketKinds.contains(where: r.label.hasPrefix), raw)
                XCTAssertTrue(r.label.contains("<->"), raw)
            case .process:
                // A socket row taken for a process reads its port as a pid.
                XCTAssertFalse(raw.contains("<->"), raw)
            case .header, .skipped:
                break
            }
        }
    }

    /// A socket's label must not change between samples, or the tally takes
    /// it for a new socket and credits its whole total again. nettop resolves
    /// addresses to host names in the background unless told not to.
    func testSocketLabelsStayNumericAcrossSamples() throws {
        let hosts = try run(samples: 3).compactMap { _, line -> String? in
            guard case .connection(let r) = line else { return nil }
            // Drop the protocol and any %scope; what remains is addresses, ports, '*', ':' '.' '<->'.
            let body = r.label.drop { $0 != " " }.replacingOccurrences(of: #"%[A-Za-z0-9]+"#, with: "", options: .regularExpression)
            return body.range(of: "[g-zG-Z]", options: .regularExpression) != nil ? r.label : nil
        }
        XCTAssertEqual(hosts, [], "labels contain host names")
    }
}
#endif
