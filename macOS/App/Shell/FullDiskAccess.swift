import AppKit
import Foundation

/// Whether Passthrough holds Full Disk Access. Shells it starts inherit its
/// privacy permissions, so without it a command touching Desktop, Documents
/// and the like raises a prompt on the Mac and waits.
enum FullDiskAccess {
    /// Folders only Full Disk Access opens. Several, because which exist
    /// varies: newer macOS has no per-user TCC folder at all, and a Mac may
    /// never have run Mail or Messages.
    static let protectedFolders = ["Library/Safari", "Library/Mail", "Library/Messages",
                                   "Library/Containers/com.apple.stocks", "Library/Application Support/com.apple.TCC"]

    /// Granted when any of `protectedFolders` can be listed.
    static var isGranted: Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return protectedFolders.contains {
            (try? FileManager.default.contentsOfDirectory(atPath: home.appendingPathComponent($0).path)) != nil
        }
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
