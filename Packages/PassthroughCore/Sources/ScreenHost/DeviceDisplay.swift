#if os(macOS)
import CoreGraphics
import CVirtualDisplay
import Foundation
import PassthroughCore

/// A display in the phone's shape, which the stream shows instead of the
/// Mac's own (`ScreenVideoWire.Fit.device`): `DeviceDisplay`, or a test's.
protocol DeviceDisplaying: AnyObject, Sendable {
    /// A display of `width`×`height` pixels that the Mac's own displays
    /// mirror, made or changed to that size; its id. Throws when it can't,
    /// and then it is closed.
    @MainActor func show(width: Int, height: Int) async throws -> CGDirectDisplayID
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

    func show(width: Int, height: Int) async throws -> CGDirectDisplayID {
        do {
            return try await make(width: width & ~1, height: height & ~1)
        } catch {
            close()
            throw error
        }
    }

    private func make(width: Int, height: Int) async throws -> CGDirectDisplayID {
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
            descriptor.vendorID = 0x5054
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
        settings.modes = [CGVirtualDisplayMode(width: UInt(width), height: UInt(height), refreshRate: 60),
                          CGVirtualDisplayMode(width: UInt(width / 2), height: UInt(height / 2), refreshRate: 60)]
        guard display.apply(settings) else { throw Failure.noMode(width: width, height: height) }
        let mode = try await self.mode(of: id, width: width, height: height)

        var config: CGDisplayConfigRef?
        let begun = CGBeginDisplayConfiguration(&config)
        guard begun == .success, let config else { throw Failure.configuration(begun) }
        CGConfigureDisplayWithDisplayMode(config, id, mode, nil)
        let others = Self.onlineDisplays().filter { $0 != id && !mirrored.contains($0) }
        for other in others { CGConfigureDisplayMirrorOfDisplay(config, other, id) }
        let done = CGCompleteDisplayConfiguration(config, .forAppOnly)
        guard done == .success else { throw Failure.configuration(done) }
        mirrored.formUnion(others)
        return id
    }

    /// The mode of `width`×`height` pixels, Retina (half the points) if there is one, once CoreGraphics lists it.
    private func mode(of id: CGDirectDisplayID, width: Int, height: Int) async throws -> CGDisplayMode {
        let options = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
        let deadline = Date().addingTimeInterval(Self.modeWait)
        while true {
            let modes = CGDisplayCopyAllDisplayModes(id, options) as? [CGDisplayMode] ?? []
            let matching = modes.filter { $0.pixelWidth == width && $0.pixelHeight == height }
            if let retina = matching.first(where: { $0.width * 2 == width }) ?? matching.min(by: { $0.width < $1.width }) {
                return retina
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
