import AppKit
import Foundation

/// Whether Passthrough holds Full Disk Access. Shells it starts inherit its
/// privacy permissions, so without it a command touching Desktop, Documents
/// and the like raises a prompt on the Mac and waits.
enum FullDiskAccess {
    /// The user's TCC database opens only with Full Disk Access.
    static var isGranted: Bool {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/com.apple.TCC/TCC.db").path
        guard let handle = FileHandle(forReadingAtPath: path) else { return false }
        try? handle.close()
        return true
    }

    /// Privacy & Security › Full Disk Access in System Settings (the pre-Ventura
    /// address as a fallback).
    static func openSettings() {
        for address in ["x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles",
                        "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"] {
            if let url = URL(string: address), NSWorkspace.shared.open(url) { return }
        }
    }

    /// A Finder window with Passthrough selected, to drag into the list: macOS
    /// shows an app there only once it has been added.
    static func revealApp() {
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
    }
}
