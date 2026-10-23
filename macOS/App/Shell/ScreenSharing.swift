import AppKit
import Foundation
import Network
import PassthroughCore

/// macOS Screen Sharing, which a phone's `screen` request is relayed to.
/// Passthrough can't turn it on; the owner does, in System Settings.
enum ScreenSharing {
    /// Whether it answers on loopback. It sees a connection that closes
    /// before saying anything, which it ignores.
    static func isOn(timeout: TimeInterval = 1) async -> Bool {
        guard let port = NWEndpoint.Port(rawValue: RemoteShell.screenSharingPort) else { return false }
        return await withCheckedContinuation { done in
            let connection = NWConnection(host: .ipv4(.loopback), port: port, using: .tcp)
            let finished = Locked(false)
            let finish: @Sendable (Bool) -> Void = { on in
                guard !finished.exchange(true) else { return }
                connection.cancel()
                done.resume(returning: on)
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: finish(true)
                // Refused (nothing listening) shows up as waiting, not failed.
                case .waiting, .failed: finish(false)
                default: break
                }
            }
            connection.start(queue: .global(qos: .utility))
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) { finish(false) }
        }
    }

    /// General › Sharing in System Settings (the pre-Ventura address as a fallback).
    static func openSettings() {
        for address in ["x-apple.systempreferences:com.apple.Sharing-Settings.extension",
                        "x-apple.systempreferences:com.apple.preferences.sharing?Services_ScreenSharing"] {
            if let url = URL(string: address), NSWorkspace.shared.open(url) { return }
        }
    }
}
