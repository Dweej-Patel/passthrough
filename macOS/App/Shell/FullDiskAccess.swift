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

    static func openSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") else { return }
        NSWorkspace.shared.open(url)
    }
}
