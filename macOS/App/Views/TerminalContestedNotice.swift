import AppKit
import SwiftUI

/// Tells the owner that a window "Open here" opened was not the only one to
/// ask with its token (`LocalTerminalAccess.onContested`): something else on
/// this Mac may have read it, so the session was taken off the Mac's windows.
@MainActor
final class TerminalContestedNotice {
    private var panel: NSPanel?

    func show(_ title: String) {
        panel?.orderOut(nil)
        let host = NSHostingView(rootView: TerminalContestedView(title: title) { [weak self] in
            self?.panel?.orderOut(nil)
            self?.panel = nil
        })
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: host.fittingSize), styleMask: [.titled, .utilityWindow],
                            backing: .buffered, defer: false)
        panel.title = "Taken off this Mac"
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = host
        panel.center()
        self.panel = panel
        // A menu-bar app is not brought forward otherwise.
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
    }
}

private struct TerminalContestedView: View {
    let title: String
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("“\(title)” is no longer shown here").font(.headline)
            Text("Two windows asked to show it where Passthrough opened one, so it was taken off this Mac's windows: something else on this Mac may have tried to get to this session. It keeps running for the phone. Click Open here to try again.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("OK", action: dismiss).keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 340)
    }
}
