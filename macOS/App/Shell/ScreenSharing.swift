import AppKit
import Foundation

/// macOS Screen Sharing, which a phone's `screen` request is relayed to.
/// Passthrough can't turn it on; the owner does, in System Settings.
enum ScreenSharing {
    /// What listens on Screen Sharing's port, as the root helper judges it
    /// from the sockets' owners; nil when the helper did not answer. Something
    /// answering on loopback proves nothing: while Screen Sharing is off any
    /// process of this user's can listen on the port, and a phone relayed
    /// there would hand it the Mac account's password.
    static func check(_ helper: HelperClient) async -> ScreenSharingCheck.Result? {
        await helper.checkScreenSharing()
    }

    /// General › Sharing in System Settings (the pre-Ventura address as a fallback).
    static func openSettings() {
        for address in ["x-apple.systempreferences:com.apple.Sharing-Settings.extension",
                        "x-apple.systempreferences:com.apple.preferences.sharing?Services_ScreenSharing"] {
            if let url = URL(string: address), NSWorkspace.shared.open(url) { return }
        }
    }
}
