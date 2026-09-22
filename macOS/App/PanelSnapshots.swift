import SwiftUI
import AppKit
import PassthroughCore

/// Development aid: renders the menu panel in representative states to PNG.
/// `Passthrough.app/Contents/MacOS/Passthrough --snapshot /tmp/panels`
enum PanelSnapshots {
    @MainActor
    static func render(to directory: String) {
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let states: [(String, (SessionCoordinator) -> Void)] = [
            ("1-no-device", { $0.debugApply(phase: .noDevice) }),
            ("2-ready", { $0.debugApply(phase: .deviceFound, device: true, status: DeviceStatus(deviceName: "My iPhone", radio: "5G", battery: 0.82, hosting: "background")) }),
            ("3-pairing", { $0.debugApply(phase: .pairingRequired, device: true, status: DeviceStatus(deviceName: "My iPhone", radio: "5G", battery: 0.82, hosting: "background")) }),
            ("4-connected", { $0.debugApply(phase: .connected, device: true, status: DeviceStatus(deviceName: "My iPhone", radio: "5G", battery: 0.82, hosting: "background"), traffic: true) }),
            ("5-helper", { $0.debugApply(phase: .helperRequired, device: true) }),
            ("6-vpn", { $0.debugApply(phase: .connected, device: true, status: DeviceStatus(deviceName: "My iPhone", radio: "5G", battery: 0.82, hosting: "background"), traffic: true, vpn: "connected") }),
            ("8-vpn-over-wifi", { $0.debugApply(phase: .deviceFound, device: true, status: DeviceStatus(deviceName: "My iPhone", radio: "5G", battery: 0.82, hosting: "background"), traffic: true, vpn: "connected", underlay: "Wi-Fi") }),
            ("7-vpn-blocked", { $0.debugApply(phase: .connected, device: true, status: DeviceStatus(deviceName: "My iPhone", radio: "5G", battery: 0.82, hosting: "background"), traffic: true, vpn: "blocked") }),
        ]
        for (name, configure) in states {
            let session = SessionCoordinator()
            configure(session)
            for scheme in [ColorScheme.dark, .light] {
                let view = MenuPanelView().environmentObject(session).environment(\.colorScheme, scheme)
                    .frame(width: 356)
                let renderer = ImageRenderer(content: view)
                renderer.scale = 2
                if let image = renderer.nsImage, let tiff = image.tiffRepresentation,
                   let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                    try? png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name)-\(scheme == .dark ? "dark" : "light").png"))
                }
            }
        }
    }
}
