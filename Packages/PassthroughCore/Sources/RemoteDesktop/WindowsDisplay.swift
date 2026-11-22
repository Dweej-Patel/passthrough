import CoreGraphics
import Foundation
import ScreenClient

/// The shape a PC's desktop is asked for, and how large Windows draws on it.
/// Pure: the view's pixels, the kind of device and the user's two choices in,
/// one `ScreenShape` out.
public enum WindowsDisplay {
    /// The Display menu's choice, remembered per computer.
    public enum Shape: String, Sendable, CaseIterable {
        /// The view's own pixels: one Windows pixel is one device pixel, and it turns with the device.
        case fit
        /// 16:10, landscape however the device is held; shown fitted, with pinch to zoom.
        case standard
    }

    public enum Device: Sendable {
        case phone, pad
    }

    /// Text size: the same three choices as a display a Mac makes for this device (`ScreenModel.spaces`).
    public static let spaces = [80, 100, 125]

    /// Windows' scale steps.
    static let scales = [100, 125, 150, 175, 200, 225, 250, 300, 350, 400, 450, 500]
    /// Display control's limits for a side, and this app's for the whole desktop (three copies of it are held).
    static let sideRange = 200...8192
    static let longestSide: CGFloat = 4096
    static let mostPixels: CGFloat = 8_300_000

    /// `viewPixels`: the screen view's area in device pixels, as the device is held. `space`: 80 (larger text), 100 or 125 (more space).
    public static func shape(_ shape: Shape, device: Device, viewPixels: CGSize, space: Int) -> ScreenShape {
        switch shape {
        case .standard:
            let scale: Int
            switch (device, space) {
            case (.phone, 80): scale = 175
            case (.phone, 125): scale = 125
            case (.phone, _): scale = 150
            case (.pad, 80): scale = 250
            case (.pad, 125): scale = 150
            case (.pad, _): scale = 200
            }
            let size = device == .pad ? (2560, 1600) : (1920, 1200)
            return ScreenShape(width: size.0, height: size.1, desktopScale: scale, deviceScale: deviceScale(for: scale))
        case .fit:
            var pixels = CGSize(width: max(viewPixels.width, 1), height: max(viewPixels.height, 1))
            // A view larger than the caps is asked for proportionally smaller.
            let cap = min(1, longestSide / max(pixels.width, pixels.height), (mostPixels / (pixels.width * pixels.height)).squareRoot())
            pixels = CGSize(width: pixels.width * cap, height: pixels.height * cap)
            let width = even(Int(pixels.width)), height = even(Int(pixels.height))
            // How many Windows points the short side should have; the scale is the largest step that still gives them.
            let target: Int
            switch (device, space) {
            case (.phone, 80): target = 480
            case (.phone, 125): target = 760
            case (.phone, _): target = 600
            case (.pad, 80): target = 800
            case (.pad, 125): target = 1280
            case (.pad, _): target = 1000
            }
            let short = min(width, height)
            let scale = scales.last { $0 * target <= short * 100 } ?? 100
            return ScreenShape(width: width, height: height, desktopScale: scale, deviceScale: deviceScale(for: scale))
        }
    }

    /// The device scale factor Windows pairs with a desktop scale.
    static func deviceScale(for desktopScale: Int) -> Int {
        desktopScale < 150 ? 100 : desktopScale <= 225 ? 140 : 180
    }

    private static func even(_ side: Int) -> Int {
        min(max(side, sideRange.lowerBound), sideRange.upperBound) & ~1
    }

    /// A change of shape waits for the turn to settle, and Windows is asked at most once a second.
    public static let settle: TimeInterval = 0.4
    public static let apart: TimeInterval = 1

    /// How long to wait before asking, `now` and `lastAsked` on the same clock (nil: never asked).
    /// A newer change replaces one that is waiting, and waits again.
    public static func wait(now: TimeInterval, lastAsked: TimeInterval?) -> TimeInterval {
        guard let lastAsked else { return settle }
        return max(settle, lastAsked + apart - now)
    }
}
