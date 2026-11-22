import CoreGraphics
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

    func testFitIsTheViewsOwnPixelsAndTurnsWithIt() {
        for (name, device, width, height) in devices {
            for space in WindowsDisplay.spaces {
                let portrait = WindowsDisplay.shape(.fit, device: device, viewPixels: CGSize(width: width, height: height), space: space)
                let landscape = WindowsDisplay.shape(.fit, device: device, viewPixels: CGSize(width: height, height: width), space: space)
                XCTAssertEqual(portrait.width, Int(width) & ~1, name)
                XCTAssertEqual(portrait.height, Int(height) & ~1, name)
                XCTAssertEqual(landscape.width, portrait.height, name)
                XCTAssertEqual(landscape.height, portrait.width, name)
                // The text size goes by the short side, so turning the device keeps it.
                XCTAssertEqual(landscape.desktopScale, portrait.desktopScale, name)
                XCTAssertTrue(WindowsDisplay.scales.contains(portrait.desktopScale), name)
            }
        }
    }

    func testFitTextSizeIsTheLargestStepThatKeepsTheTargetPoints() {
        // The plan's example: 1206 pixels across at 600 points is 201 %, so 200 %.
        XCTAssertEqual(WindowsDisplay.shape(.fit, device: .phone, viewPixels: CGSize(width: 1206, height: 2622), space: 100).desktopScale, 200)
        XCTAssertEqual(WindowsDisplay.shape(.fit, device: .phone, viewPixels: CGSize(width: 1206, height: 2622), space: 80).desktopScale, 250)
        XCTAssertEqual(WindowsDisplay.shape(.fit, device: .phone, viewPixels: CGSize(width: 1206, height: 2622), space: 125).desktopScale, 150)
        XCTAssertEqual(WindowsDisplay.shape(.fit, device: .pad, viewPixels: CGSize(width: 2064, height: 2752), space: 100).desktopScale, 200)
        XCTAssertEqual(WindowsDisplay.shape(.fit, device: .pad, viewPixels: CGSize(width: 2064, height: 2752), space: 80).desktopScale, 250)
        XCTAssertEqual(WindowsDisplay.shape(.fit, device: .pad, viewPixels: CGSize(width: 2064, height: 2752), space: 125).desktopScale, 150)
        // Never below 100 %, however small the view.
        XCTAssertEqual(WindowsDisplay.shape(.fit, device: .pad, viewPixels: CGSize(width: 400, height: 300), space: 125).desktopScale, 100)
        for (name, device, width, height) in devices {
            for (space, phone, pad) in [(80, 480, 800), (100, 600, 1000), (125, 760, 1280)] {
                let shape = WindowsDisplay.shape(.fit, device: device, viewPixels: CGSize(width: width, height: height), space: space)
                let target = device == .pad ? pad : phone, short = min(shape.width, shape.height)
                if shape.desktopScale > 100 { XCTAssertGreaterThanOrEqual(short * 100 / shape.desktopScale, target, name) }
                if let next = WindowsDisplay.scales.first(where: { $0 > shape.desktopScale }) {
                    XCTAssertLessThan(short * 100, next * target, "\(name): a larger step would still fit")
                }
            }
        }
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
        let odd = WindowsDisplay.shape(.fit, device: .phone, viewPixels: CGSize(width: 1179, height: 2221), space: 100)
        XCTAssertEqual(odd.width, 1178)
        XCTAssertEqual(odd.height, 2220)
        let tiny = WindowsDisplay.shape(.fit, device: .phone, viewPixels: CGSize(width: 120, height: 90), space: 100)
        XCTAssertEqual(tiny.width, 200)
        XCTAssertEqual(tiny.height, 200)
        let nothing = WindowsDisplay.shape(.fit, device: .phone, viewPixels: .zero, space: 100)
        XCTAssertEqual(nothing.width, 200)
        XCTAssertEqual(nothing.height, 200)
    }

    func testAViewPastTheCapsIsAskedForProportionallySmaller() {
        // Longer than 4096 on a side.
        let long = WindowsDisplay.shape(.fit, device: .pad, viewPixels: CGSize(width: 6000, height: 1000), space: 100)
        XCTAssertLessThanOrEqual(long.width, 4096)
        XCTAssertEqual(Double(long.width) / Double(long.height), 6, accuracy: 0.05)
        // More than 8.3 million pixels.
        let large = WindowsDisplay.shape(.fit, device: .pad, viewPixels: CGSize(width: 4000, height: 3000), space: 100)
        XCTAssertLessThanOrEqual(large.width * large.height, 8_300_000)
        XCTAssertEqual(Double(large.width) / Double(large.height), 4.0 / 3.0, accuracy: 0.01)
    }

    func testStandardIsSixteenByTenHoweverTheDeviceIsHeld() {
        for (space, phone, pad) in [(80, 175, 250), (100, 150, 200), (125, 125, 150)] {
            for view in [CGSize(width: 1206, height: 2622), CGSize(width: 2622, height: 1206)] {
                XCTAssertEqual(WindowsDisplay.shape(.standard, device: .phone, viewPixels: view, space: space),
                               ScreenShape(width: 1920, height: 1200, desktopScale: phone, deviceScale: WindowsDisplay.deviceScale(for: phone)))
                XCTAssertEqual(WindowsDisplay.shape(.standard, device: .pad, viewPixels: view, space: space),
                               ScreenShape(width: 2560, height: 1600, desktopScale: pad, deviceScale: WindowsDisplay.deviceScale(for: pad)))
            }
        }
    }

    func testAChangeSettlesAndWindowsIsAskedAtMostOnceASecond() {
        // Never asked: only the settle.
        XCTAssertEqual(WindowsDisplay.wait(now: 100, lastAsked: nil), 0.4)
        // Asked long ago: only the settle.
        XCTAssertEqual(WindowsDisplay.wait(now: 100, lastAsked: 90), 0.4)
        // Asked 0.2 s ago: the rest of the second.
        XCTAssertEqual(WindowsDisplay.wait(now: 100.2, lastAsked: 100), 0.8, accuracy: 0.0001)
        // Asked 0.9 s ago: the settle is the longer wait.
        XCTAssertEqual(WindowsDisplay.wait(now: 100.9, lastAsked: 100), 0.4, accuracy: 0.0001)
    }
}
