import XCTest
import Network
@testable import PassthroughCore
@testable import PhoneTransport

final class LineBufferTests: XCTestCase {
    func testSplitsLinesAcrossChunks() throws {
        var buffer = LineBuffer()
        XCTAssertEqual(try buffer.append(Data("{\"t\":\"pi".utf8)), [])
        let lines = try buffer.append(Data("ng\"}\n\n{\"t\":\"pong\"}\n{\"t\"".utf8))
        XCTAssertEqual(lines.map { String(decoding: $0, as: UTF8.self) }, [#"{"t":"ping"}"#, #"{"t":"pong"}"#])
        XCTAssertEqual(try buffer.append(Data(":\"x\"}\n".utf8)).count, 1)
    }

    func testRejectsAnEndlessLine() {
        var buffer = LineBuffer(limit: 8)
        XCTAssertNoThrow(try buffer.append(Data("12345678".utf8)))
        XCTAssertThrowsError(try buffer.append(Data("9".utf8)))
    }
}

/// A watcher driven by hand, standing in for usbmuxd or adb.
@MainActor
private final class FakeWatcher: DeviceWatcher {
    let transport: WatchTransport
    var status = WatchStatus()
    var onDevicesChange: (([PhoneDevice]) -> Void)?
    var onStatusChange: ((WatchStatus) -> Void)?
    init(transport: WatchTransport) { self.transport = transport }
    func start() {}
    func stop() { onDevicesChange?([]) }
}

@MainActor
final class DeviceDirectoryTests: XCTestCase {
    func testMergesWatchersAndReportsChanges() {
        let phones = FakeWatcher(transport: .usbmux)
        let androids = FakeWatcher(transport: .adb)
        let wireless = FakeWatcher(transport: .wireless)
        let directory = DeviceDirectory(watchers: [phones, androids, wireless])
        var changes: [String] = []
        directory.onChange = { change in
            switch change {
            case .attached(let d): changes.append("+\(d.id)")
            case .detached(let d): changes.append("-\(d.id)")
            }
        }
        let iPhone = PhoneDevice.iPhone(deviceID: 1, udid: "A")
        let pixel = PhoneDevice.android(serial: "P", model: "Pixel")
        let galaxy = PhoneDevice.android(serial: "G", model: nil)

        phones.onDevicesChange?([iPhone])
        androids.onDevicesChange?([pixel])
        androids.onDevicesChange?([pixel])          // unchanged: no events
        androids.onDevicesChange?([galaxy])         // one phone swapped for another
        XCTAssertEqual(changes, ["+usbmux:1", "+adb:P", "-adb:P", "+adb:G"])
        XCTAssertEqual(directory.devices.map(\.id), ["usbmux:1", "adb:G"])

        androids.stop()
        XCTAssertEqual(directory.devices.map(\.id), ["usbmux:1"], "stopping one watcher leaves the others' phones")
        XCTAssertTrue(directory.watcher(for: .adb) === androids)

        // The same iPhone over the air is a second device; its watcher's lists don't touch the cable one.
        let overAir = PhoneDevice.wireless(phoneID: "P1", kind: .iPhone, label: "iPhone", pairingSlot: "token", link: LoopbackLink())
        wireless.onDevicesChange?([overAir])
        wireless.onDevicesChange?([])
        XCTAssertEqual(directory.devices.map(\.id), ["usbmux:1"])
        XCTAssertEqual(changes.suffix(2), ["+wifi:P1", "-wifi:P1"])
    }
}
