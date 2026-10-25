import AppIntents
import SwiftUI
import WidgetKit
import PassthroughCore

@main
struct PassthroughWidgets: WidgetBundle {
    var body: some Widget {
        MacWidget()
        MacLiveActivity()
        if #available(iOS 18.0, *) {
            KeepMacAwakeControl()
            MacVPNOnControl()
        }
    }
}

// MARK: - Control Center

// Buttons, not toggles: only the app can reach the Mac (its keys need Face
// ID), so each opens Passthrough, which unlocks and then does it. Turning
// the VPN off is not offered here: it lowers protection, so it's in-app only.

@available(iOS 18.0, *)
struct KeepMacAwakeControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "KeepMacAwake") {
            ControlWidgetButton(action: OpenURLIntent(AppLink.keepAwake.url)) {
                Label("Keep Mac awake", systemImage: "cup.and.saucer.fill")
            }
        }
        .displayName("Keep Mac awake")
        .description("Opens Passthrough and turns on Keep awake on your Mac.")
    }
}

@available(iOS 18.0, *)
struct MacVPNOnControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "MacVPNOn") {
            ControlWidgetButton(action: OpenURLIntent(AppLink.vpnOn.url)) {
                Label("Mac VPN on", systemImage: "lock.shield.fill")
            }
        }
        .displayName("Mac VPN on")
        .description("Opens Passthrough and turns on your Mac's VPN.")
    }
}
