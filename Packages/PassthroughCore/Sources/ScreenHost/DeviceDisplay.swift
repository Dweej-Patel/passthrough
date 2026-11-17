#if os(macOS)
import CoreGraphics
import CVirtualDisplay
import Foundation
import PassthroughCore

/// A display in the phone's shape, which the stream shows instead of the
/// Mac's own (`ScreenVideoWire.Fit.device`): `DeviceDisplay`, or a test's.
protocol DeviceDisplaying: AnyObject, Sendable {
    /// A display of `width`×`height` pixels refreshing up to `fps` times a second (60 or 120)
    /// that the Mac's own displays mirror, made or changed to that; its id. Throws when it
    /// can't, and then it is closed.
    @MainActor func show(width: Int, height: Int, fps: Int) async throws -> CGDirectDisplayID
    /// Gone, and the Mac's displays as they were. Idempotent.
    @MainActor func close()
}

/// A virtual display (CoreGraphics' private `CGVirtualDisplay`, as Sidecar
/// makes for an iPad) in Retina mode at the phone's own pixels, so the Mac
/// lays its desktop out for the phone: its text one Mac point to two phone
/// pixels, no black bars. While it lasts the Mac's own displays mirror it
/// (their windows move onto it, the Mac's owner sees it letterboxed, or black
/// under the curtain); closing it ends the mirroring and macOS puts them back.
/// The changes are made for this app only (`forAppOnly`): if the app quits or
/// crashes, macOS undoes them, and the virtual display goes with the process.
@MainActor
final class DeviceDisplay: DeviceDisplaying {
    enum Failure: Error {
        /// Another phone's view has the Mac's one device display.
        case inUse
        /// This macOS has no virtual displays, or wouldn't make one.
        case unavailable
        /// It made the display but offered no mode of that size.
        case noMode(width: Int, height: Int)
        case configuration(CGError)
        /// The Mac's own displays wouldn't mirror it: it would show an empty desktop.
        case notMirrored
    }

    /// One at a time on this Mac: a second phone wanting one gets the Mac's
    /// own display (which, mirroring the first one's, shows that).
    private static var owner: ObjectIdentifier?
    /// How long a new display or mode gets to show up in CoreGraphics' lists.
    static let modeWait: TimeInterval = 2

    private var display: CGVirtualDisplay?
    private var maxSide = 0
    private var mirrored: Set<CGDirectDisplayID> = []

    nonisolated init() {}

    func show(width: Int, height: Int, fps: Int) async throws -> CGDirectDisplayID {
        do {
            return try await make(width: width & ~1, height: height & ~1, refresh: fps > 60 ? 120 : 60)
        } catch {
            close()
            throw error
        }
    }

    private func make(width: Int, height: Int, refresh: Double) async throws -> CGDirectDisplayID {
        guard width >= 320, height >= 320 else { throw Failure.noMode(width: width, height: height) }
        let me = ObjectIdentifier(self)
        guard Self.owner == nil || Self.owner == me else { throw Failure.inUse }
        // Turning the phone swaps the sides, which the first display's limits allow; a bigger one is made again.
        if display != nil, max(width, height) > maxSide { close() }
        if display == nil {
            guard NSClassFromString("CGVirtualDisplay") != nil else { throw Failure.unavailable }
            let side = max(width, height)
            let descriptor = CGVirtualDisplayDescriptor()
            descriptor.setDispatchQueue(.main)
            descriptor.name = "Passthrough (phone)"
            descriptor.maxPixelsWide = UInt32(side)
            descriptor.maxPixelsHigh = UInt32(side)
            // About a phone's density, so macOS treats it as a Retina display.
            descriptor.sizeInMillimeters = CGSize(width: Double(width) / 220 * 25.4, height: Double(height) / 220 * 25.4)
            descriptor.vendorID = Self.vendor
            descriptor.productID = 0x0001
            descriptor.serialNum = 1
            guard let made = CGVirtualDisplay(descriptor: descriptor) else { throw Failure.unavailable }
            display = made
            maxSide = side
            Self.owner = me
            ptLog(.info, "screen: made a display for the phone")
        }
        guard let display else { throw Failure.unavailable }
        let id = display.displayID

        // Retina: the mode's pixels at 2×. Both readings of a mode's size are
        // offered (CoreGraphics doesn't document which it takes); the one with
        // these pixels at half the points is chosen below.
        let settings = CGVirtualDisplaySettings()
        settings.hiDPI = 1
        settings.modes = [CGVirtualDisplayMode(width: UInt(width), height: UInt(height), refreshRate: refresh),
                          CGVirtualDisplayMode(width: UInt(width / 2), height: UInt(height / 2), refreshRate: refresh)]
        guard display.apply(settings) else { throw Failure.noMode(width: width, height: height) }
        let mode = try await self.mode(of: id, width: width, height: height, refresh: refresh)

        var config: CGDisplayConfigRef?
        let begun = CGBeginDisplayConfiguration(&config)
        guard begun == .success, let config else { throw Failure.configuration(begun) }
        CGConfigureDisplayWithDisplayMode(config, id, mode, nil)
        // Every other display that isn't mirroring this one now: asked again each time, since
        // changing the display's modes can end the mirroring. Not other virtual displays of
        // ours still on their way out.
        let others = Self.onlineDisplays().filter { $0 != id && CGDisplayMirrorsDisplay($0) != id && CGDisplayVendorNumber($0) != Self.vendor }
        for other in others { CGConfigureDisplayMirrorOfDisplay(config, other, id) }
        let done = CGCompleteDisplayConfiguration(config, .forAppOnly)
        guard done == .success else { throw Failure.configuration(done) }
        mirrored.formUnion(others)
        // It must really be so: without the mirroring the phone would see an empty desktop beside the Mac's.
        let physical = Self.onlineDisplays().filter { $0 != id && CGDisplayVendorNumber($0) != Self.vendor }
        let notMirroring = physical.filter { CGDisplayMirrorsDisplay($0) != id }
        ptLog(.info, "screen: the phone's display is \(mode.width)×\(mode.height) points (\(mode.pixelWidth)×\(mode.pixelHeight) pixels) for \(width)×\(height); \(physical.count - notMirroring.count) of \(physical.count) of the Mac's displays mirror it")
        guard notMirroring.isEmpty else { throw Failure.notMirrored }
        return id
    }

    static let vendor: UInt32 = 0x5054

    /// The mode of `width`×`height` pixels, Retina (half the points) if there is one, at the
    /// refresh rate closest to `refresh`, once CoreGraphics lists it.
    private func mode(of id: CGDirectDisplayID, width: Int, height: Int, refresh: Double) async throws -> CGDisplayMode {
        let options = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
        let deadline = Date().addingTimeInterval(Self.modeWait)
        while true {
            let modes = CGDisplayCopyAllDisplayModes(id, options) as? [CGDisplayMode] ?? []
            let sized = modes.filter { $0.pixelWidth == width && $0.pixelHeight == height }
            let retina = sized.filter { $0.width * 2 == width }
            let matching = retina.isEmpty ? sized : retina
            // A mode's refresh rate reads 0 when it isn't known.
            if let best = matching.min(by: { abs(($0.refreshRate == 0 ? 60 : $0.refreshRate) - refresh) < abs(($1.refreshRate == 0 ? 60 : $1.refreshRate) - refresh) }) {
                return best
            }
            guard Date() < deadline else {
                ptLog(.warning, "screen: the phone's display offers no \(width)×\(height) mode (\(modes.map { "\($0.pixelWidth)×\($0.pixelHeight)/\($0.width)" }))")
                throw Failure.noMode(width: width, height: height)
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    func close() {
        guard display != nil else { return }
        if !mirrored.isEmpty {
            var config: CGDisplayConfigRef?
            if CGBeginDisplayConfiguration(&config) == .success, let config {
                for other in mirrored { CGConfigureDisplayMirrorOfDisplay(config, other, kCGNullDirectDisplay) }
                let done = CGCompleteDisplayConfiguration(config, .forAppOnly)
                if done != .success { ptLog(.warning, "screen: couldn't end mirroring the phone's display (\(done.rawValue))") }
            }
        }
        self.display = nil   // released: macOS removes it
        mirrored = []
        maxSide = 0
        if Self.owner == ObjectIdentifier(self) { Self.owner = nil }
        ptLog(.info, "screen: removed the phone's display")
    }

    private static func onlineDisplays() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return [] }
        return Array(ids.prefix(Int(count)))
    }
}
#endif
