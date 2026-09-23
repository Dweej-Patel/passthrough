import XCTest
import Network
@testable import PassthroughCore
@testable import USBMux

final class AndroidTransportTests: XCTestCase {
    func testADBRequestFraming() {
        XCTAssertEqual(String(decoding: ADB.request("host:track-devices-l"), as: UTF8.self), "0014host:track-devices-l")
        XCTAssertEqual(String(decoding: ADB.request("tcp:7890"), as: UTF8.self), "0008tcp:7890")
    }

    func testParsesDeviceList() {
        let text = """
        R58M123ABC             device usb:1-1 product:beyond1 model:SM_G973F device:beyond1 transport_id:3
        0A171FDD4000FJ         unauthorized usb:336592896X transport_id:4
        emulator-5554          device product:sdk_gphone64_arm64 model:sdk_gphone64_arm64 device:emu64a transport_id:1
        adb-2B1-x._adb-tls-connect._tcp device product:husky model:Pixel_8_Pro device:husky transport_id:5
        XYZ                    no permissions (user in plugdev group) usb:1-2 transport_id:6

        """
        let d = ADB.parseDevices(text)
        XCTAssertEqual(d.count, 5)
        XCTAssertEqual(d[0].serial, "R58M123ABC")
        XCTAssertTrue(d[0].isReady && d[0].isUSB)
        XCTAssertEqual(d[0].model, "SM G973F")
        XCTAssertEqual(d[1].state, "unauthorized")
        XCTAssertTrue(d[1].isUSB)
        XCTAssertFalse(d[2].isUSB, "emulators are not on the cable")
        XCTAssertFalse(d[3].isUSB, "adb over Wi-Fi is not USB")
        XCTAssertTrue(d[4].state.hasPrefix("no permissions"))
        XCTAssertTrue(d[4].isUSB)
    }

    func testFriendlyErrors() {
        XCTAssertTrue(ADB.ADBError.failed("closed").localizedDescription.contains("Passthrough running"))
        XCTAssertTrue(ADB.ADBError.failed("device 'X' not found").localizedDescription.contains("not found"))
    }

    func testPhoneDeviceIdentity() {
        let a = PhoneDevice(transport: .adb("R58M"), label: "Pixel")
        let i = PhoneDevice(transport: .usbmux(3), label: "0000…")
        XCTAssertEqual(a.id, "adb:R58M")
        XCTAssertEqual(i.id, "usbmux:3")
        XCTAssertEqual(a.kind, .android)
        XCTAssertEqual(i.kindName, "iPhone")
    }

    /// What the Android app's kotlinx.serialization encoder emits (nulls omitted).
    func testDecodesAndroidEnvelopes() throws {
        let welcome = try ControlEnvelope.decode(Data(#"{"t":"welcome","protocolVersion":1,"socksPort":7890,"deviceName":"Pixel 8","radio":"5G","carrier":"T-Mobile","battery":0.82,"hosting":"background","paired":false}"#.utf8))
        XCTAssertEqual(welcome.t, ControlEnvelope.welcome)
        XCTAssertEqual(welcome.paired, false)
        XCTAssertEqual(welcome.battery, 0.82)
        let status = try ControlEnvelope.decode(Data(#"{"t":"status","deviceName":"Pixel 8","activeConnections":3,"rxBytes":5000000000,"txBytes":12,"timestamp":1.7580624E9}"#.utf8))
        XCTAssertEqual(status.rxBytes, 5_000_000_000)
        XCTAssertEqual(status.timestamp ?? 0, 1.7580624e9, accuracy: 1)
    }
}

/// Talks to a real Android phone (or emulator) running Passthrough, through
/// the local adb server. Skipped unless PASSTHROUGH_ADB_SERIAL is set.
/// Optional: PASSTHROUGH_ADB_CODE (pairing code shown on the phone) or
/// PASSTHROUGH_ADB_TOKEN (a token from an earlier pairing) for the data path.
final class AndroidEndToEndTests: XCTestCase {
    private let env = ProcessInfo.processInfo.environment
    private let clientID = "e2e-test-mac"

    func testControlPairingAndSOCKSOverADB() throws {
        guard let serial = env["PASSTHROUGH_ADB_SERIAL"] else { throw XCTSkip("set PASSTHROUGH_ADB_SERIAL to run") }
        let device = PhoneDevice(transport: .adb(serial), label: serial)
        let queue = DispatchQueue(label: "e2e")

        // 1. The device shows up in adb's device list.
        let seen = expectation(description: "device listed")
        let listed = Locked(false)
        let track = ADB.track(queue: queue) { event in
            if case .devices(let list) = event, list.contains(where: { $0.serial == serial && $0.isReady }), !listed.exchange(true) { seen.fulfill() }
        }
        wait(for: [seen], timeout: 10)
        track.cancel()

        // 2. Control channel: hello, optionally pair.
        var token = env["PASSTHROUGH_ADB_TOKEN"]
        let welcomed = expectation(description: "welcome")
        let pairedExp = expectation(description: "paired")
        let code = env["PASSTHROUGH_ADB_CODE"]
        if code == nil { pairedExp.isInverted = true }
        let issued = Locked<String?>(nil)
        var client: ControlClient!
        client = ControlClient(device: device, identity: .init(clientID: clientID, name: "E2E Mac", token: token)) { event in
            switch event {
            case .welcomed(let paired, let status, let port):
                XCTAssertEqual(port, 7890)
                print("welcome from \(status.deviceName) radio=\(status.radio ?? "-") paired=\(paired)")
                welcomed.fulfill()
                if let code { client.pair(code: code) }
            case .paired(let t):
                issued.set(t)
                pairedExp.fulfill()
            case .pairingFailed(let f):
                XCTFail("pairing failed: \(f)")
            default: break
            }
        }
        client.connect()
        wait(for: [welcomed, pairedExp], timeout: 10)
        client.close()
        if let t = issued.get() {
            XCTAssertEqual(t.count, 43)
            token = t
            print("PASSTHROUGH_ADB_TOKEN=\(t)")
        }
        guard let token else { return }

        // 3. Data path: local forwarder over adb, then a real request through the phone.
        let forwarder = LocalForwarder(device: device, localPort: 17999)
        try forwarder.start()
        defer { forwarder.stop() }
        let curl = Process()
        curl.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        curl.arguments = ["-s", "-o", "/dev/null", "-w", "%{http_code}", "--max-time", "20",
                          "--socks5-hostname", "127.0.0.1:17999", "--proxy-user", "\(clientID):\(token)", "https://example.com/"]
        let out = Pipe()
        curl.standardOutput = out
        try curl.run()
        curl.waitUntilExit()
        let status = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        XCTAssertEqual(status, "200", "HTTPS through the phone")
        XCTAssertGreaterThan(forwarder.counter.snapshot().rx, 0)
    }
}
