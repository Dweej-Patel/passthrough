import CoreGraphics
import Foundation
import PassthroughCore

/// The shape a PC's desktop is asked for, and how large things are on it.
/// Pure: the view's pixels, the kind of device, the PC's own display and the
/// user's two choices in, one `ScreenShape` out.
///
/// Windows' scale factor is never changed: a session at another scale than the
/// PC's own monitor leaves the taskbar unlaid and older apps stretched, there
/// and back at the PC. The session keeps the PC's scale, and text size is how
/// many pixels are asked for: fewer, shown larger here.
public enum WindowsDisplay {
    /// The Display menu's choice, remembered per computer.
    public enum Shape: String, Sendable, CaseIterable {
        /// The view's own pixels: one Windows pixel is one device pixel, and it turns with the device.
        case fit
        /// 16:10, landscape however the device is held; shown fitted, with pinch to zoom.
        case standard
        /// The PC's own monitor as it is: nothing on its desktop moves, here or back at the PC. Pan and zoom.
        /// Without the PC's display (`HostDisplay`), the standard shape.
        case own
    }



    public enum Device: Sendable {
        case phone, pad
    }

    /// Text size: the same three choices as a display a Mac makes for this device (`ScreenModel.spaces`).
    public static let spaces = [80, 100, 125]

    /// Windows' scale steps.
    public static let scales = [100, 125, 150, 175, 200, 225, 250, 300, 350, 400, 450, 500]
    /// Display control's limits for a side, and this app's for the whole desktop (three copies of it are held).
    static let sideRange = 200...8192
    static let longestSide: CGFloat = 4096
    static let mostPixels: CGFloat = 8_300_000

    /// `viewPixels`: the screen view's area in device pixels, as the device is held. `space`: 80 (larger text), 100
    /// or 125 (more space). `host`: the PC's own monitor, when it said; its scale is the session's (100 % without it).
    public static func shape(_ shape: Shape, device: Device, viewPixels: CGSize, space: Int, host: HostDisplay? = nil) -> ScreenShape {
        let hostScale = host.map { scales.contains($0.scale) ? $0.scale : 100 } ?? 100
        func made(_ width: Int, _ height: Int) -> ScreenShape {
            ScreenShape(width: even(width), height: even(height), desktopScale: hostScale, deviceScale: deviceScale(for: hostScale))
        }
        switch shape {
        case .own:
            guard let host, sideRange.contains(host.width), sideRange.contains(host.height) else {
                return Self.shape(.standard, device: device, viewPixels: viewPixels, space: space, host: host)
            }
            return made(host.width, host.height)
        case .standard:
            // How large things would be drawn at the full size; the desktop is that much smaller instead.
            let zoom: Int
            switch (device, space) {
            case (.phone, 80): zoom = 175
            case (.phone, 125): zoom = 125
            case (.phone, _): zoom = 150
            case (.pad, 80): zoom = 250
            case (.pad, 125): zoom = 150
            case (.pad, _): zoom = 200
            }
            let size = device == .pad ? (2560, 1600) : (1920, 1200)
            return made(size.0 * hostScale / zoom, size.1 * hostScale / zoom)
        case .fit:
            var pixels = CGSize(width: max(viewPixels.width, 1), height: max(viewPixels.height, 1))
            // A view larger than the caps is asked for proportionally smaller.
            let cap = min(1, longestSide / max(pixels.width, pixels.height), (mostPixels / (pixels.width * pixels.height)).squareRoot())
            pixels = CGSize(width: pixels.width * cap, height: pixels.height * cap)
            // How many points the short side should have; the zoom is the largest step that still gives them.
            let target: Int
            switch (device, space) {
            case (.phone, 80): target = 480
            case (.phone, 125): target = 760
            case (.phone, _): target = 600
            case (.pad, 80): target = 800
            case (.pad, 125): target = 1280
            case (.pad, _): target = 1000
            }
            let short = Int(min(pixels.width, pixels.height))
            let zoom = scales.last { $0 * target <= short * 100 } ?? 100
            // The view's shape, with as many pixels as the PC draws those points in at its own scale.
            return made(Int(pixels.width) * hostScale / zoom, Int(pixels.height) * hostScale / zoom)
        }
    }

    /// The device scale factor Windows pairs with a desktop scale.
    public static func deviceScale(for desktopScale: Int) -> Int {
        desktopScale < 150 ? 100 : desktopScale <= 225 ? 140 : 180
    }

    private static func even(_ side: Int) -> Int {
        min(max(side, sideRange.lowerBound), sideRange.upperBound) & ~1
    }

    /// A change of shape waits a second after the last change (a turn of the device passes through several
    /// sizes), and Windows is asked at most once every two seconds: each ask rearranges the PC's desktop.
    public static let settle: TimeInterval = 1
    public static let apart: TimeInterval = 2

    /// Whether `next` differs enough from `current` to ask Windows for it: a few percent either way isn't worth
    /// rearranging the PC's desktop for.
    public static func worthAsking(_ next: ScreenShape, current: ScreenShape?) -> Bool {
        guard let current else { return true }
        if next.desktopScale != current.desktopScale { return true }
        func near(_ a: Int, _ b: Int) -> Bool { abs(a - b) * 100 <= max(a, b) * 3 }
        return !(near(next.width, current.width) && near(next.height, current.height))
    }

    /// How long to wait before asking, `now` and `lastAsked` on the same clock (nil: never asked).
    /// A newer change replaces one that is waiting, and waits again.
    public static func wait(now: TimeInterval, lastAsked: TimeInterval?) -> TimeInterval {
        guard let lastAsked else { return settle }
        return max(settle, lastAsked + apart - now)
    }
}
