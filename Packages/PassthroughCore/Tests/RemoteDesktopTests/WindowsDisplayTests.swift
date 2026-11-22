import CoreGraphics
import PassthroughCore
import ScreenClient
import XCTest
@testable import RemoteDesktop

final class WindowsDisplayTests: XCTestCase {
    /// View areas in pixels, portrait: (name, phone or iPad, width, height).
    private let devices: [(String, WindowsDisplay.Device, CGFloat, CGFloat)] = [
        ("iPhone SE", .phone, 750, 1334),
        ("iPhone 16 Pro", .phone, 1206, 2622),
        ("iPhone 16 Pro Max", .phone, 1320, 2868),
        ("iPad mini", .pad, 1488, 2266),
        ("iPad Pro 11", .pad, 1668, 2420),
        ("iPad Pro 13", .pad, 2064, 2752),
    ]

    func testFitHasTheViewsShapeAndTurnsWithIt() {
        for (name, device, width, height) in devices {
            for space in WindowsDisplay.spaces {
                let portrait = WindowsDisplay.shape(.fit, device: device, viewPixels: CGSize(width: width, height: height), space: space)
                let landscape = WindowsDisplay.shape(.fit, device: device, viewPixels: CGSize(width: height, height: width), space: space)
                XCTAssertEqual(landscape.width, portrait.height, name)
                XCTAssertEqual(landscape.height, portrait.width, name)
                // The view's own proportions, within a rounding to even pixels.
                XCTAssertEqual(Double(portrait.width) / Double(portrait.height), Double(width) / Double(height), accuracy: 0.01, name)
                XCTAssertEqual(portrait.width % 2, 0, name)
                XCTAssertEqual(portrait.height % 2, 0, name)
                XCTAssertLessThanOrEqual(portrait.width, Int(width), name)
            }
        }
    }

    /// Windows' scale is never changed: the session keeps the PC's own, whatever the device and the text size.
    func testTheSessionKeepsThePCsOwnScale() {
        for (name, device, width, height) in devices {
            for space in WindowsDisplay.spaces {
                for shape in WindowsDisplay.Shape.allCases {
                    let view = CGSize(width: width, height: height)
                    XCTAssertEqual(WindowsDisplay.shape(shape, device: device, viewPixels: view, space: space).desktopScale, 100, name)
                    for scale in [100, 125, 150, 200] {
                        let host = HostDisplay(width: 2560, height: 1440, scale: scale)
                        XCTAssertEqual(WindowsDisplay.shape(shape, device: device, viewPixels: view, space: space, host: host).desktopScale,
                                       scale, name)
                    }
                }
            }
        }
        // A scale Windows doesn't have is not passed on.
        let odd = HostDisplay(width: 2560, height: 1440, scale: 137)
        XCTAssertEqual(WindowsDisplay.shape(.fit, device: .phone, viewPixels: CGSize(width: 1206, height: 2622), space: 100, host: odd).desktopScale, 100)
    }

    /// Text size is how many pixels are asked for: the short side has its target in points at the PC's scale.
    func testTextSizeIsPixelsAskedFor() {
        let view = CGSize(width: 1206, height: 2622)
        // 1206 across at 600 points is a zoom of 200 %: 603 pixels at the PC's 100 %.
        XCTAssertEqual(WindowsDisplay.shape(.fit, device: .phone, viewPixels: view, space: 100).width, 602)
        XCTAssertEqual(WindowsDisplay.shape(.fit, device: .phone, viewPixels: view, space: 80).width, 482)    // 250 %
        XCTAssertEqual(WindowsDisplay.shape(.fit, device: .phone, viewPixels: view, space: 125).width, 804)   // 150 %
        // A PC at 150 % draws the same points in half as many pixels again.
        let host = HostDisplay(width: 3840, height: 2160, scale: 150)
        XCTAssertEqual(WindowsDisplay.shape(.fit, device: .phone, viewPixels: view, space: 100, host: host).width, 904)
        // Larger text never asks for more pixels than more space.
        for (name, device, width, height) in devices {
            let sizes = [80, 100, 125].map { WindowsDisplay.shape(.fit, device: device, viewPixels: CGSize(width: width, height: height), space: $0).width }
            XCTAssertLessThanOrEqual(sizes[0], sizes[1], name)
            XCTAssertLessThanOrEqual(sizes[1], sizes[2], name)
        }
    }

    func testThePCsOwnSizeIsItsMonitorAsItIs() {
        let host = HostDisplay(width: 5120, height: 1440, scale: 100)
        for space in WindowsDisplay.spaces {
            for view in [CGSize(width: 1206, height: 2622), CGSize(width: 2622, height: 1206)] {
                XCTAssertEqual(WindowsDisplay.shape(.own, device: .phone, viewPixels: view, space: space, host: host),
                               ScreenShape(width: 5120, height: 1440, desktopScale: 100, deviceScale: 100))
            }
        }
        // A PC that said nothing, or something Remote Desktop can't be asked for: the standard shape.
        let standard = WindowsDisplay.shape(.standard, device: .phone, viewPixels: CGSize(width: 1206, height: 2622), space: 100)
        XCTAssertEqual(WindowsDisplay.shape(.own, device: .phone, viewPixels: CGSize(width: 1206, height: 2622), space: 100), standard)
        let tiny = HostDisplay(width: 100, height: 100, scale: 100)
        XCTAssertEqual(WindowsDisplay.shape(.own, device: .phone, viewPixels: CGSize(width: 1206, height: 2622), space: 100, host: tiny), standard)
    }

    func testDeviceScaleFollowsTheDesktopScale() {
        XCTAssertEqual(WindowsDisplay.deviceScale(for: 100), 100)
        XCTAssertEqual(WindowsDisplay.deviceScale(for: 125), 100)
        XCTAssertEqual(WindowsDisplay.deviceScale(for: 150), 140)
        XCTAssertEqual(WindowsDisplay.deviceScale(for: 225), 140)
        XCTAssertEqual(WindowsDisplay.deviceScale(for: 250), 180)
        XCTAssertEqual(WindowsDisplay.deviceScale(for: 500), 180)
    }

    func testSidesAreEvenAndWithinDisplayControlsLimits() {
        let tiny = WindowsDisplay.shape(.fit, device: .phone, viewPixels: CGSize(width: 120, height: 90), space: 100)
        XCTAssertEqual(tiny.width, 200)
        XCTAssertEqual(tiny.height, 200)
        let nothing = WindowsDisplay.shape(.fit, device: .phone, viewPixels: .zero, space: 100)
        XCTAssertEqual(nothing.width, 200)
        XCTAssertEqual(nothing.height, 200)
        for (name, device, width, height) in devices {
            for shape in WindowsDisplay.Shape.allCases {
                let made = WindowsDisplay.shape(shape, device: device, viewPixels: CGSize(width: width + 1, height: height + 1), space: 100)
                XCTAssertEqual(made.width % 2, 0, name)
                XCTAssertEqual(made.height % 2, 0, name)
                XCTAssertTrue((200...8192).contains(made.width) && (200...8192).contains(made.height), name)
            }
        }
    }

    func testAViewPastTheCapsIsAskedForProportionallySmaller() {
        let long = WindowsDisplay.shape(.fit, device: .pad, viewPixels: CGSize(width: 6000, height: 1000), space: 125)
        XCTAssertLessThanOrEqual(long.width, 4096)
        XCTAssertEqual(Double(long.width) / Double(long.height), 6, accuracy: 0.1)
        let large = WindowsDisplay.shape(.fit, device: .pad, viewPixels: CGSize(width: 4000, height: 3000), space: 125)
        XCTAssertLessThanOrEqual(large.width * large.height, 8_300_000)
        XCTAssertEqual(Double(large.width) / Double(large.height), 4.0 / 3.0, accuracy: 0.01)
    }

    func testStandardIsSixteenByTenHoweverTheDeviceIsHeld() {
        for space in WindowsDisplay.spaces {
            let portrait = WindowsDisplay.shape(.standard, device: .phone, viewPixels: CGSize(width: 1206, height: 2622), space: space)
            let landscape = WindowsDisplay.shape(.standard, device: .phone, viewPixels: CGSize(width: 2622, height: 1206), space: space)
            XCTAssertEqual(portrait, landscape)
            XCTAssertEqual(Double(portrait.width) / Double(portrait.height), 1.6, accuracy: 0.01)
        }
        // 1920 x 1200 drawn at 150 % is 1280 x 800 at the PC's 100 %; an iPad's 2560 x 1600 at 200 % likewise.
        XCTAssertEqual(WindowsDisplay.shape(.standard, device: .phone, viewPixels: .zero, space: 100), ScreenShape(width: 1280, height: 800))
        XCTAssertEqual(WindowsDisplay.shape(.standard, device: .pad, viewPixels: .zero, space: 100), ScreenShape(width: 1280, height: 800))
        XCTAssertEqual(WindowsDisplay.shape(.standard, device: .pad, viewPixels: .zero, space: 125).width, 1706)
    }

    func testOnlyAChangeWorthItIsAsked() {
        let current = ScreenShape(width: 1000, height: 2000)
        XCTAssertTrue(WindowsDisplay.worthAsking(current, current: nil))
        XCTAssertFalse(WindowsDisplay.worthAsking(current, current: current))
        XCTAssertFalse(WindowsDisplay.worthAsking(ScreenShape(width: 1020, height: 1960), current: current))   // 2 % each way
        XCTAssertTrue(WindowsDisplay.worthAsking(ScreenShape(width: 1000, height: 1900), current: current))    // 5 % shorter
        XCTAssertTrue(WindowsDisplay.worthAsking(ScreenShape(width: 2000, height: 1000), current: current))    // turned
        XCTAssertTrue(WindowsDisplay.worthAsking(ScreenShape(width: 1000, height: 2000, desktopScale: 150), current: current))
    }

    func testAChangeSettlesAndWindowsIsAskedAtMostOnceEveryTwoSeconds() {
        // Never asked: only the settle.
        XCTAssertEqual(WindowsDisplay.wait(now: 100, lastAsked: nil), 1)
        // Asked long ago: only the settle.
        XCTAssertEqual(WindowsDisplay.wait(now: 100, lastAsked: 90), 1)
        // Asked 0.2 s ago: the rest of the two seconds.
        XCTAssertEqual(WindowsDisplay.wait(now: 100.2, lastAsked: 100), 1.8, accuracy: 0.0001)
        // Asked 1.5 s ago: the settle is the longer wait.
        XCTAssertEqual(WindowsDisplay.wait(now: 101.5, lastAsked: 100), 1, accuracy: 0.0001)
    }
}
