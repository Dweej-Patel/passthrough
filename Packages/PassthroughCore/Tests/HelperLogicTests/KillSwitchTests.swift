import XCTest
@testable import HelperLogic

final class KillSwitchRulesTests: XCTestCase {
    private let full = KillSwitchRules.Input(
        vpnInterface: "utun12",
        endpoints: [.init(ip: "203.0.113.5", port: 1194), .init(ip: "2001:db8::5", port: 51820), .init(ip: "203.0.113.5", port: 1194)],
        localSubnets: [CIDR("192.168.1.0/24")!, CIDR("fdc2:fc3c:56c:6545::/64")!],
        tailscaleInterfaces: ["utun9"])

    private func lines(_ input: KillSwitchRules.Input) -> [String] {
        KillSwitchRules.ruleset(input).split(separator: "\n").map(String.init).filter { !$0.hasPrefix("#") }
    }

    func testRules() {
        let rules = lines(full)
        XCTAssertEqual(rules.first, "pass quick on lo0 all no state")
        XCTAssertEqual(rules.last, "block drop out quick all", "everything else is dropped, IPv4 and IPv6")
        XCTAssertEqual(rules[1], "pass out quick on utun12 all no state")
        XCTAssertEqual(rules.filter { $0.contains("port 1194") }, ["pass out quick proto { tcp udp } to 203.0.113.5 port 1194 no state"],
                       "once per endpoint, on any interface (passthrough utun or Wi-Fi)")
        XCTAssertTrue(rules.contains("pass out quick proto { tcp udp } to 2001:db8::5 port 51820 no state"))
        for expected in ["pass out quick inet proto udp from any port 68 to any port 67 no state",
                         "pass out quick inet to 169.254.0.0/16 no state",
                         "pass out quick inet6 to fe80::/10 no state",
                         "pass out quick inet to 224.0.0.0/24 no state",
                         "pass out quick inet6 to ff02::/16 no state",
                         "pass out quick inet to 192.168.1.0/24 no state",
                         "pass out quick inet6 to fdc2:fc3c:56c:6545::/64 no state",
                         "pass out quick on utun9 all no state"] {
            XCTAssertTrue(rules.contains(expected), expected)
        }
        XCTAssertFalse(rules.contains { $0.contains("100.64.0.0/10") || $0.contains("fd7a:115c:a1e0::/48") },
                       "Tailscale's ranges only through its own interface: a network can hand them out too")
        let dnsBlock = "block drop out quick inet proto { tcp udp } to 192.168.1.0/24 port { 53 853 }"
        XCTAssertLessThan(rules.firstIndex(of: dnsBlock)!, rules.firstIndex(of: "pass out quick inet to 192.168.1.0/24 no state")!,
                          "DNS to a resolver on the local network is dropped before the local network is let through")
        XCTAssertTrue(rules.contains("block drop out quick inet6 proto { tcp udp } to fdc2:fc3c:56c:6545::/64 port { 53 853 }"))
        XCTAssertFalse(rules.contains("pass out quick inet6 all no state"), "IPv6 is blocked unless its bypass was chosen")
        XCTAssertTrue(rules.allSatisfy { $0.hasSuffix("no state") || $0.hasPrefix("block") }, "stateless: connections open before it engaged are judged too")
    }

    func testWhileDownNothingButTheServerAndTheLink() {
        let rules = lines(KillSwitchRules.Input(endpoints: [.init(ip: "203.0.113.5", port: 443)]))
        XCTAssertFalse(rules.contains { $0.contains("utun") })
        XCTAssertFalse(rules.contains { $0.contains("192.168.") }, "local network off: no subnets")
        XCTAssertEqual(rules.last, "block drop out quick all")
    }

    /// The phone dials the Mac's listener; the Mac's replies leave from its
    /// port. They go whether or not the local network is allowed, and nothing
    /// else does: not other ports, not UDP, not other hosts.
    func testPhoneLinkGoesThroughWithTheLocalNetworkBlocked() {
        let link = KillSwitchRules.PhoneLink(port: 50123, peers: ["172.20.10.1", "2001:db8:5::7"],
                                             subnets: [CIDR("172.20.10.0/28")!, CIDR("fdc2:fc3c:56c:6545::/64")!])
        let rules = lines(KillSwitchRules.Input(endpoints: [.init(ip: "203.0.113.5", port: 443)], phoneLink: link))
        let expected = ["pass out quick proto tcp from any port 50123 to 172.20.10.1 no state",
                        "pass out quick proto tcp from any port 50123 to 2001:db8:5::7 no state",
                        "pass out quick proto tcp from any port 50123 to 172.20.10.0/28 no state",
                        "pass out quick proto tcp from any port 50123 to fdc2:fc3c:56c:6545::/64 no state"]
        XCTAssertEqual(rules.filter { $0.contains("50123") }, expected)
        XCTAssertFalse(rules.contains("pass out quick inet to 172.20.10.0/28 no state"), "the local network itself stays blocked")
        XCTAssertLessThan(rules.firstIndex(of: expected[0])!, rules.firstIndex(of: "block drop out quick all")!)

        var repeated = link
        repeated.peers = ["172.20.10.1", "172.20.10.1"]
        repeated.subnets = []
        XCTAssertEqual(lines(.init(phoneLink: repeated)).filter { $0.contains("50123") }.count, 1)
        XCTAssertTrue(lines(.init()).allSatisfy { !$0.contains("from any port") || $0.contains("port 68") || $0.contains("port 546") },
                      "no link, no rule")
    }

    func testMalformedPhoneLinkIsLeftOut() {
        let rules = KillSwitchRules.ruleset(.init(phoneLink: .init(port: 0, peers: ["172.20.10.1"])))
        XCTAssertFalse(rules.contains("172.20.10.1"), "no port, no rule")
        let bad = KillSwitchRules.ruleset(.init(phoneLink: .init(port: 50123, peers: ["any", "172.20.10.1 port 1", "fe80::1%en0", ""])))
        XCTAssertFalse(bad.contains("50123"))
    }

    /// What the app sends: the listener's port and the phone's addresses,
    /// checked like every other XPC value.
    func testPhoneLinkFromXPC() throws {
        let keys = (portKey: "phoneLinkPort", peersKey: "phoneLinkPeers")
        XCTAssertNil(try KillSwitchRules.PhoneLink.read([:], portKey: keys.portKey, peersKey: keys.peersKey), "no wireless link")
        XCTAssertEqual(try KillSwitchRules.PhoneLink.read(["phoneLinkPort": 50123, "phoneLinkPeers": ["172.20.10.1"]],
                                                          portKey: keys.portKey, peersKey: keys.peersKey),
                       .init(port: 50123, peers: ["172.20.10.1"]))
        XCTAssertEqual(try KillSwitchRules.PhoneLink.read(["phoneLinkPort": 50123], portKey: keys.portKey, peersKey: keys.peersKey),
                       .init(port: 50123), "no phone linked yet")
        for bad: [String: Any] in [["phoneLinkPort": 70000], ["phoneLinkPort": 0], ["phoneLinkPort": "50123"],
                                   ["phoneLinkPort": 50123, "phoneLinkPeers": ["phone.local"]],
                                   ["phoneLinkPort": 50123, "phoneLinkPeers": ["fe80::1%en0"]],
                                   ["phoneLinkPort": 50123, "phoneLinkPeers": Array(repeating: "10.0.0.1", count: 5)],
                                   ["phoneLinkPort": 50123, "phoneLinkPeers": "172.20.10.1"]] {
            XCTAssertThrowsError(try KillSwitchRules.PhoneLink.read(bad, portKey: keys.portKey, peersKey: keys.peersKey), "\(bad)")
        }
    }

    func testIPv6Bypass() {
        var input = full
        input.allowIPv6Bypass = true
        let rules = lines(input)
        XCTAssertEqual(rules[rules.count - 2], "pass out quick inet6 all no state")
    }

    func testMalformedInputIsLeftOut() {
        let rules = KillSwitchRules.ruleset(.init(vpnInterface: "utun1 all\npass out quick all",
                                                  endpoints: [.init(ip: "1.2.3.4 port 1", port: 1), .init(ip: "1.2.3.4", port: 0),
                                                              .init(ip: "vpn.example.com", port: 1194)],
                                                  tailscaleInterfaces: ["utun9 all", ""]))
        XCTAssertFalse(rules.contains("utun1"))
        XCTAssertFalse(rules.contains("1.2.3.4"))
        XCTAssertFalse(rules.contains("vpn.example"))
        XCTAssertFalse(rules.contains("utun9"))
        XCTAssertFalse(rules.contains("pass out quick all"))
    }

    /// pfctl parses without loading (and without root) under -n: every
    /// variant must be a ruleset pf accepts.
    func testPfctlAcceptsTheRules() throws {
        let pfctl = "/sbin/pfctl"
        guard FileManager.default.isExecutableFile(atPath: pfctl) else { throw XCTSkip("no pfctl") }
        var bypass = full
        bypass.allowIPv6Bypass = true
        var linked = full
        linked.phoneLink = .init(port: 50123, peers: ["172.20.10.1", "2001:db8:5::7"], subnets: [CIDR("172.20.10.0/28")!, CIDR("fd00::/64")!])
        for input in [full, bypass, linked, KillSwitchRules.Input(), KillSwitchRules.Input(endpoints: [.init(ip: "2001:db8::1", port: 1)])] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: pfctl)
            process.arguments = ["-n", "-a", KillSwitchRules.anchor(identifier: "dev.example.passthrough"), "-f", "-"]
            let stdin = Pipe(), stderr = Pipe()
            process.standardInput = stdin
            process.standardError = stderr
            process.standardOutput = FileHandle.nullDevice
            try process.run()
            stdin.fileHandleForWriting.write(Data(KillSwitchRules.ruleset(input).utf8))
            try stdin.fileHandleForWriting.close()
            process.waitUntilExit()
            let errors = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            XCTAssertEqual(process.terminationStatus, 0, errors + "\n" + KillSwitchRules.ruleset(input))
        }
    }

    func testAnchorName() {
        XCTAssertEqual(KillSwitchRules.anchor(identifier: "dev.dpatel.passthrough"), "com.apple/100.dev.dpatel.passthrough.killswitch")
        XCTAssertEqual(KillSwitchRules.anchor(identifier: String(repeating: "a", count: 60)), "com.apple/100.passthrough.killswitch")
        XCTAssertEqual(KillSwitchRules.anchor(identifier: "x\"y"), "com.apple/100.passthrough.killswitch")
        XCTAssertTrue(KillSwitchRules.anchor(identifier: "dev.dpatel.passthrough") < "com.apple/200.AirDrop", "evaluated before Apple's anchors")
    }
}

final class PFOutputTests: XCTestCase {
    func testToken() {
        XCTAssertEqual(PFOutput.token(fromEnable: "No ALTQ support in kernel\nALTQ related functions disabled\npf enabled\nToken : 10432567890123\n"),
                       "10432567890123")
        XCTAssertNil(PFOutput.token(fromEnable: "pfctl: pf already enabled\n"))
        XCTAssertNil(PFOutput.token(fromEnable: "Token : abc\n"))
    }

    func testStatus() {
        XCTAssertEqual(PFOutput.isEnabled(info: "Status: Enabled for 0 days 00:01:02           Debug: Urgent\n\nState Table"), true)
        XCTAssertEqual(PFOutput.isEnabled(info: "Status: Disabled for 0 days 00:00:00           Debug: Urgent\n"), false)
        XCTAssertNil(PFOutput.isEnabled(info: "pfctl: /dev/pf: Permission denied"))
    }

    func testMainRulesetEvaluatesTheAnchor() {
        let anchor = "com.apple/100.dev.example.killswitch"
        let main = "scrub-anchor \"com.apple/*\" all fragment reassemble\nanchor \"com.apple/*\" all\n"
        XCTAssertTrue(PFOutput.evaluates(anchor: anchor, mainRules: main))
        XCTAssertFalse(PFOutput.evaluates(anchor: anchor, mainRules: "scrub-anchor \"com.apple/*\" all\n"))
        XCTAssertFalse(PFOutput.evaluates(anchor: anchor, mainRules: ""))
    }
}

final class KillSwitchStateTests: XCTestCase {
    private func store() throws -> KillSwitchStateStore {
        let dir = NSTemporaryDirectory() + "ks-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(atPath: dir) }
        return KillSwitchStateStore(directory: dir)
    }

    func testWantedMarker() throws {
        let s = try store()
        XCTAssertFalse(s.isWanted)
        try s.setWanted(.init(allowLocalNetwork: false))
        XCTAssertTrue(s.isWanted)
        XCTAssertEqual(s.wanted?.allowLocalNetwork, false)
        let mode = try FileManager.default.attributesOfItem(atPath: s.directory + "/vpn-wanted")[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
        s.clearWanted()
        XCTAssertFalse(s.isWanted)
    }

    func testEndpointsSurviveForReconnectsWithoutDNS() throws {
        let s = try store()
        XCTAssertEqual(s.endpoints, [:])
        try s.setEndpoints(["vpn.example.com": ["203.0.113.5", "2001:db8::5"], "bad": ["not an ip"]])
        XCTAssertEqual(KillSwitchStateStore(directory: s.directory).endpoints, ["vpn.example.com": ["203.0.113.5", "2001:db8::5"]],
                       "a new helper reads them; anything that isn't an address is dropped")
    }

    func testToken() throws {
        let s = try store()
        XCTAssertNil(s.token)
        try s.setToken(.init(token: "123", wasEnabled: true))
        XCTAssertEqual(s.token, .init(token: "123", wasEnabled: true))
        s.clearToken()
        XCTAssertNil(s.token)
    }

    func testHoldDecisions() {
        XCTAssertEqual(KillSwitchHold.appGone(killSwitch: true), .hold, "a crash must not lift the block")
        XCTAssertEqual(KillSwitchHold.appGone(killSwitch: false), .lift)
        XCTAssertEqual(KillSwitchHold.helperStart(wanted: true), .hold)
        XCTAssertEqual(KillSwitchHold.helperStart(wanted: false), .lift)
        XCTAssertEqual(KillSwitchHold.failedStart(wasHeld: true), .hold, "a reconnect that fails keeps the block it found")
        XCTAssertEqual(KillSwitchHold.failedStart(wasHeld: false), .lift)
    }
}

final class LocalNetworksTests: XCTestCase {
    func testSubnetsOfNonTunnelInterfaces() {
        let addresses: [LocalNetworks.Address] = [
            .init(interface: "lo0", address: "127.0.0.1", prefixLength: 8, isLoopback: true),
            .init(interface: "en0", address: "192.168.1.81", prefixLength: 24),
            .init(interface: "en0", address: "fe80::1c%en0", prefixLength: 64),
            .init(interface: "en0", address: "fdc2:fc3c:56c:6545:4b1:26fb:69bf:d3ae", prefixLength: 64),
            .init(interface: "bridge100", address: "192.168.2.1", prefixLength: 24),
            .init(interface: "utun9", address: "100.95.219.56", prefixLength: 32, isPointToPoint: true),
            .init(interface: "utun3", address: "10.7.0.2", prefixLength: 32, isPointToPoint: true),
            .init(interface: "feth0", address: "10.83.0.1", prefixLength: 24),
            .init(interface: "en5", address: "10.0.0.9", prefixLength: 24, isUp: false),
        ]
        XCTAssertEqual(LocalNetworks.subnets(addresses).map(\.description), ["192.168.1.0/24", "fdc2:fc3c:56c:6545::/64", "192.168.2.0/24"])
        XCTAssertEqual(LocalNetworks.tailscaleInterfaces(addresses), ["utun9"])
    }

    /// TunnelCrack's LocalNet: a network whose netmask makes public
    /// addresses "local" gets nothing for them; nor does carrier-grade NAT
    /// space or a global IPv6 prefix on the LAN.
    func testOnlyPrivateSubnetsAreLocal() {
        let addresses: [LocalNetworks.Address] = [
            .init(interface: "en0", address: "172.20.10.2", prefixLength: 28),
            .init(interface: "en0", address: "10.0.0.5", prefixLength: 1),
            .init(interface: "en0", address: "192.168.7.9", prefixLength: 8),
            .init(interface: "en1", address: "203.0.113.9", prefixLength: 24),
            .init(interface: "en1", address: "100.64.1.5", prefixLength: 10),
            .init(interface: "en1", address: "169.254.3.3", prefixLength: 16),
            .init(interface: "en1", address: "2001:db8:1::9", prefixLength: 64),
            .init(interface: "en1", address: "fd00:1::9", prefixLength: 6),
            .init(interface: "en1", address: "10.20.0.1", prefixLength: 16),
        ]
        XCTAssertEqual(LocalNetworks.subnets(addresses).map(\.description), ["172.20.10.0/28", "10.20.0.0/16"])
    }

    /// A rogue DHCP server handing en0 a carrier-grade NAT address (plus
    /// routes) must not have everything leave on en0 as "Tailscale".
    func testOnlyUpPointToPointTunnelsAreTailscale() {
        let addresses: [LocalNetworks.Address] = [
            .init(interface: "en0", address: "100.64.1.5", prefixLength: 10),
            .init(interface: "en0", address: "fd7a:115c:a1e0::5", prefixLength: 64),
            .init(interface: "bridge100", address: "100.100.1.1", prefixLength: 32, isPointToPoint: true),
            .init(interface: "utun4", address: "100.70.1.1", prefixLength: 32, isUp: false, isPointToPoint: true),
            .init(interface: "utun5", address: "100.71.1.1", prefixLength: 32),
            .init(interface: "utun6", address: "100.72.1.1", prefixLength: 32, isPointToPoint: true),
            .init(interface: "utun7", address: "fd7a:115c:a1e0::7", prefixLength: 128, isPointToPoint: true),
            .init(interface: "utun8", address: "10.7.0.2", prefixLength: 32, isPointToPoint: true),
            .init(interface: "utun9", address: "100.95.219.56", prefixLength: 32, isPointToPoint: true),
        ]
        XCTAssertEqual(LocalNetworks.tailscaleInterfaces(addresses), ["utun6", "utun7", "utun9"])
        XCTAssertEqual(LocalNetworks.tailscaleInterfaces(addresses, excluding: ["utun6"]), ["utun7", "utun9"],
                       "the underlay is never Tailscale: it carries everything around the VPN")
    }

    func testReadsThisMac() {
        let addresses = LocalNetworks.current()
        XCTAssertTrue(addresses.contains { $0.interface == "lo0" && $0.address == "127.0.0.1" && $0.prefixLength == 8 && $0.isLoopback })
    }
}
