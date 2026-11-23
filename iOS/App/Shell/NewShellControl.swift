import SwiftUI
import PassthroughCore
import PassthroughUI

/// New shell. A plain button when the computer lists one shell or none, as it
/// always was; a split control when it lists more: the leading half opens the
/// preferred shell (named under it), the trailing half chooses another. Every
/// shell is also an accessibility action on the leading half, so VoiceOver and
/// Switch Control reach the chooser from the one element.
struct NewShellControl: View {
    enum Style {
        /// The filled button under an empty list.
        case prominent
        /// The text button under a list of sessions.
        case inline
        /// A toolbar's or tab bar's `+`.
        case toolbar
    }

    let shells: [HostShell]
    /// `ShellModel.preferredShell(for:)`.
    let preferred: HostShell?
    let hostName: String
    let style: Style
    var enabled = true
    /// The shell to open; nil lets the host choose.
    let open: (String?) -> Void

    var body: some View {
        Group {
            if shells.count > 1 { split } else { plain }
        }
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
    }

    @ViewBuilder private var plain: some View {
        switch style {
        case .prominent:
            Button { open(nil) } label: { Label("New shell", systemImage: "plus") }
                .buttonStyle(PTProminentButtonStyle())
        case .inline:
            Button { open(nil) } label: {
                Label("New shell", systemImage: "plus")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(PTColor.tintText)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        case .toolbar:
            Button { open(nil) } label: { Image(systemName: "plus") }
                .accessibilityLabel("New shell")
        }
    }

    @ViewBuilder private var split: some View {
        switch style {
        case .toolbar:
            // A tap opens the preferred shell; a long press lists them all.
            Menu { menuItems } label: { Image(systemName: "plus") } primaryAction: { open(preferred?.id) }
                .accessibilityLabel("New shell")
                .accessibilityValue(preferred?.name ?? "")
                .accessibilityActions { shellActions }
        case .prominent, .inline:
            HStack(spacing: 0) {
                Button { open(preferred?.id) } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "plus").font(.subheadline.weight(.bold))
                        VStack(alignment: .leading, spacing: 0) {
                            Text("New shell").font(.subheadline.weight(.semibold))
                            if let name = preferred?.name {
                                Text(name).font(.caption).opacity(0.85)
                            }
                        }
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.leading, 16)
                    .padding(.trailing, 12)
                    .padding(.vertical, 6)
                    .frame(minWidth: 44, minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("New shell")
                .accessibilityValue(preferred?.name ?? "")
                .accessibilityHint(preferred.map { "Opens \($0.name) on \(hostName)" } ?? "Opens a shell on \(hostName)")
                .accessibilityActions { shellActions }
                Rectangle().fill(foreground.opacity(0.35)).frame(width: 1, height: 24).accessibilityHidden(true)
                Menu { menuItems } label: {
                    Image(systemName: "chevron.down")
                        .font(.subheadline.weight(.semibold))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Choose a shell")
                .accessibilityHint("\(shells.count) shells on \(hostName)")
            }
            .foregroundStyle(foreground)
            .background(background, in: Capsule())
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The footnote heads the list, where a menu always shows it in full.
    @ViewBuilder private var menuItems: some View {
        Section("Shells open as you, never as administrator.") {
            ForEach(shells, id: \.id) { shell in
                Button { open(shell.id) } label: {
                    if shell.id == preferred?.id {
                        Label(shell.name, systemImage: "checkmark")
                    } else {
                        Text(shell.name)
                    }
                }
            }
        }
    }

    @ViewBuilder private var shellActions: some View {
        ForEach(shells, id: \.id) { shell in
            Button("New \(shell.name) shell") { open(shell.id) }
        }
    }

    private var foreground: Color { style == .prominent ? PTColor.onTint : PTColor.tintText }
    private var background: Color { style == .prominent ? PTColor.tint : PTColor.tintText.opacity(0.12) }
}
