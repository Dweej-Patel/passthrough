import SwiftUI
import PassthroughCore
import PassthroughUI

/// A Mac's profile picture: its initial on a color picked from its ID, with an
/// amber dot when it needs you. Whatever holds it gives the label (the toolbar
/// button), or hides it beside the name it shows (a switcher row).
struct MacAvatar: View {
    let macID: String
    let name: String
    var badge = false
    var size: CGFloat = 30

    private var color: Color {
        let palette = PTTheme.avatarPalette
        return palette[MacProfiles.colorIndex(macID: macID, paletteCount: palette.count)]
    }

    var body: some View {
        Text(MacProfiles.initial(name))
            .font(.system(size: size * 0.5, weight: .semibold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(color, in: Circle())
            .overlay(alignment: .topTrailing) {
                if badge {
                    Circle().fill(PTTheme.warning)
                        .frame(width: size * 0.4, height: size * 0.4)
                        .overlay(Circle().strokeBorder(PTColor.background, lineWidth: 2))
                        .offset(x: size * 0.1, y: -size * 0.1)
                }
            }
    }
}

/// What the switcher hands its host to present once it has closed.
enum SwitcherNext: Equatable {
    case addMac, settings
    /// The terminal at the question a session on that Mac is asking (the Mac is already selected).
    case answer(macID: String, session: String)
}

/// "Your Macs": every paired Mac with what it's doing, then Add a Mac and Settings.
struct MacSwitcherSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var shell: ShellModel
    @Binding var then: SwitcherNext?
    /// The first tap wins: rows and actions do nothing once one was taken and the sheet is closing.
    @State private var acting = false

    struct Row: Identifiable { let id: String; let name: String }

    private var rows: [Row] { Self.rows(model.pairedClients, shell: shell) }

    /// Every paired computer, by the name its shell grant gives it (else its pairing's): the switcher's rows,
    /// and the Shells and Activity tabs' title menu (`ComputerTitleMenu`).
    static func rows(_ paired: [PairedClient], shell: ShellModel) -> [Row] {
        paired.map { client in
            Row(id: client.id, name: shell.macs.first { $0.macID == client.id }?.macName ?? client.name)
        }
    }

    /// The switch itself, the same from every place that offers one: the shell sets up that computer's tabs.
    static func switchTo(_ macID: String, shell: ShellModel) {
        shell.select(macID)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    PTSurface(padding: 6) {
                        VStack(spacing: 0) {
                            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                                if index > 0 { Divider().padding(.leading, 62) }
                                macRow(row)
                            }
                        }
                    }
                    PTSurface(padding: 6) {
                        VStack(spacing: 0) {
                            actionRow("Add a computer", systemImage: "plus") { close(then: .addMac) }
                            Divider().padding(.leading, 62)
                            actionRow("Settings", systemImage: "gearshape") { close(then: .settings) }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .background(PTColor.background)
            .navigationTitle("Your computers")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
    }

    private func macRow(_ row: Row) -> some View {
        let status = shell.status(for: row.id)
        var asking: String?
        if case .asking = status {
            asking = askingSession(on: row.id)
        }
        let current = row.id == shell.selectedMacID
        let isAsking = { if case .asking = status { return true } else { return false } }()
        return Button { choose(row.id, asking: asking) } label: {
            HStack(spacing: 12) {
                MacAvatar(macID: row.id, name: row.name, size: 38)
                    .accessibilityHidden(true)   // the name beside it says the same
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.name).font(.body.weight(.semibold)).lineLimit(1)
                    Text(MacProfiles.statusText(status, now: .now, kind: shell.kind(of: row.id), showKind: shell.mixedKinds))
                        .font(.caption)
                        .foregroundStyle(isAsking ? PTColor.attentionText : Color.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                if current { Image(systemName: "checkmark").font(.body.weight(.semibold)).foregroundStyle(PTTheme.down) }
            }
            .padding(.horizontal, 10)
            .frame(minHeight: 60)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(current ? .isSelected : [])
    }

    /// Closes the sheet; `next` runs from the host's `onDismiss`, once the sheet has gone.
    private func close(then next: SwitcherNext?) {
        guard !acting else { return }
        acting = true
        then = next
        dismiss()
    }

    private func choose(_ macID: String, asking: String?) {
        guard !acting else { return }
        // The switch sets up the Mac's tabs now; the terminal attaches to the question after the sheet is gone.
        Self.switchTo(macID, shell: shell)
        close(then: asking.map { .answer(macID: macID, session: $0) })
    }

    private func actionRow(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 38, height: 38)
                Text(title).font(.body)
                Spacer(minLength: 8)
            }
            .padding(.horizontal, 10)
            .frame(minHeight: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// The session waiting on a question on that Mac: this one's live list, or what the watch last saw.
    private func askingSession(on macID: String) -> String? {
        let sessions = macID == shell.selectedMacID ? shell.visibleSessions : (shell.watcher.seen[macID]?.sessions ?? [])
        return sessions.first(where: \.isAsking)?.id
    }
}

// MARK: - Title menu (Shells, Activity)

/// The Shells and Activity tabs' title menu: the switcher's computers, each with its kind and state and a
/// checkmark on the one selected; picking one switches exactly as the switcher does (`switchTo`).
struct ComputerTitleMenu: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var shell: ShellModel

    var body: some View {
        Picker("Computer", selection: Binding(get: { shell.selectedMacID ?? "" },
                                              set: { MacSwitcherSheet.switchTo($0, shell: shell) })) {
            ForEach(MacSwitcherSheet.rows(model.pairedClients, shell: shell)) { row in
                item(row).tag(row.id)
            }
        }
    }

    private func item(_ row: MacSwitcherSheet.Row) -> some View {
        let kind = shell.kind(of: row.id)
        return Label {
            Text(row.name)
            Text(MacProfiles.statusText(shell.status(for: row.id), now: .now, kind: kind, showKind: true))
        } icon: {
            Image(systemName: HostWords(kind: kind, name: nil, device: ThisDevice.name).symbol)
        }
    }
}

/// With two or more computers paired, the navigation title opens `ComputerTitleMenu`. Inline: that's
/// where iOS draws a title's menu. With one, the tab keeps its plain large title.
private struct ComputerTitleMenuModifier: ViewModifier {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var shell: ShellModel

    func body(content: Content) -> some View {
        if model.pairedClients.count >= 2 {
            content
                .toolbarTitleMenu { ComputerTitleMenu(shell: shell) }
                .navigationBarTitleDisplayMode(.inline)
        } else {
            content
        }
    }
}

extension View {
    /// The computer switcher in the navigation title (`ComputerTitleMenuModifier`); goes where `navigationTitle` does.
    func computerTitleMenu(_ shell: ShellModel) -> some View { modifier(ComputerTitleMenuModifier(shell: shell)) }
}
