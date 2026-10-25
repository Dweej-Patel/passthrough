import AppKit
import SwiftUI
import PassthroughUI

/// A short notice at the top of the screen with the menu bar: it grows out of
/// the notch when that screen has one, else it drops in as a capsule under the
/// menu bar (older Macs, most monitors, a closed lid on a monitor). Which one
/// is decided each time, so it follows the menu bar from screen to screen.
@MainActor
final class NotchNotice {
    enum Kind {
        /// Something got safer or simply happened: gone after a few seconds.
        case quiet(title: String, detail: String?, symbol: String)
        /// Something got less safe: stays until dismissed, with a way to undo it.
        case lowered(title: String, detail: String?, action: String, perform: () -> Void)
    }

    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?

    func show(_ kind: Kind) {
        hide(animated: false)
        // The first screen is the one with the menu bar.
        guard let screen = NSScreen.screens.first else { return }
        let notch = screen.safeAreaInsets.top
        let host = NSHostingView(rootView: NotchNoticeView(kind: kind, notchHeight: notch) { [weak self] in self?.hide(animated: true) })
        let size = host.fittingSize
        let top = notch > 0 ? screen.frame.maxY : screen.visibleFrame.maxY - 8
        let panel = NSPanel(contentRect: NSRect(x: screen.frame.midX - size.width / 2, y: top - size.height, width: size.width, height: size.height),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.contentView = host
        panel.orderFrontRegardless()
        self.panel = panel
        if case .quiet = kind {
            hideTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(4))
                guard !Task.isCancelled else { return }
                self?.hide(animated: true)
            }
        }
    }

    func hide(animated: Bool) {
        hideTask?.cancel()
        hideTask = nil
        guard let panel else { return }
        self.panel = nil
        guard animated else { return panel.orderOut(nil) }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.2
            panel.animator().alphaValue = 0
        }, completionHandler: { panel.orderOut(nil) })
    }
}

struct NotchNoticeView: View {
    let kind: NotchNotice.Kind
    /// The notch's height, or 0 on a screen without one.
    let notchHeight: CGFloat
    /// For `--snapshot`: already shown, and a plain stand-in for the
    /// behind-window glass, which an image can't capture.
    var snapshot = false
    let dismiss: () -> Void
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme

    private var inNotch: Bool { notchHeight > 0 }

    var body: some View {
        content
            .padding(.horizontal, 16)
            .padding(.top, inNotch ? notchHeight + 8 : 10)
            .padding(.bottom, inNotch ? 14 : 10)
            .frame(width: 380)
            .background { background }
            // Exit faster than entrance; no bounce. Reduce Motion: a fade only.
            .scaleEffect(x: 1, y: shown || reduceMotion || snapshot ? 1 : 0.4, anchor: .top)
            .opacity(shown || snapshot ? 1 : 0)
            .padding(inNotch ? 0 : 12)   // room for the capsule's shadow
            .onAppear { withAnimation(.easeOut(duration: 0.35)) { shown = true } }
            // The notch is black hardware: its notice is always dark. The capsule follows the system.
            .environment(\.colorScheme, inNotch ? .dark : scheme)
    }

    @ViewBuilder private var background: some View {
        if inNotch {
            UnevenRoundedRectangle(bottomLeadingRadius: 26, bottomTrailingRadius: 26, style: .continuous).fill(.black)
        } else {
            Group { if snapshot { Color(nsColor: .windowBackgroundColor).opacity(0.92) } else { VisualEffect() } }
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Color.primary.opacity(0.12)))
                .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
        }
    }

    @ViewBuilder private var content: some View {
        switch kind {
        case let .quiet(title, detail, symbol):
            HStack(spacing: 12) {
                badge(symbol, tint: PTColor.tint, icon: PTColor.tintText)
                text(title, detail)
                Spacer(minLength: 0)
            }
        case let .lowered(title, detail, action, perform):
            HStack(spacing: 12) {
                badge("exclamationmark.shield", tint: PTColor.attention, icon: PTColor.attentionText)
                text(title, detail)
                Spacer(minLength: 0)
                Button(action) { perform(); dismiss() }
                    .buttonStyle(PTPillButtonStyle())
                Button(action: dismiss) { Image(systemName: "xmark").font(.caption.weight(.bold)) }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Dismiss")
            }
        }
    }

    private func badge(_ symbol: String, tint: Color, icon: Color) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(icon)
            .frame(width: 32, height: 32)
            .background(tint.opacity(0.16), in: Circle())
    }

    private func text(_ title: String, _ detail: String?) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
            if let detail { Text(detail).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(2) }
        }
    }
}

/// The capsule's glass: a real behind-window material (SwiftUI's blends within the window only).
private struct VisualEffect: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}
