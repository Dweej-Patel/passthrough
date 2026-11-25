import SwiftUI
import PassthroughCore
import PassthroughUI

/// A glance at a session from a list: touch and hold its row to see its latest
/// output above what can be done to it, without opening the terminal. The
/// output is the end of the Mac's recording (`transcript` with `tail`), so a
/// peek never attaches: it takes nothing over from another phone and types nothing.
struct ShellPeekView: View {
    let shell: ShellModel
    let session: ShellSessionInfo
    @StateObject private var driver = TerminalDriver(readOnly: true, scrollback: 2_000)
    @State private var replay: [ShellReplayChunk]?
    @State private var failed = false

    /// How much of the end of a session's output a peek asks for and draws.
    static let tailBytes = 256 * 1024
    /// Small enough that a wide Mac window's session shows most of its width.
    static let minimumFontSize: CGFloat = 5

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Color.white.opacity(0.08))
            ZStack {
                if let replay {
                    if Self.hasOutput(replay) {
                        ReplayTerminalHost(driver: driver, replay: replay, minimumFontSize: Self.minimumFontSize, glance: true)
                            .padding(.horizontal, 6)
                            .clipped()
                    } else {
                        message("Nothing printed yet.", icon: "terminal")
                    }
                } else if failed {
                    message("Couldn't load its latest output. Open it to see the terminal.", icon: "exclamationmark.triangle")
                } else {
                    ProgressView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 340, height: 460)
        .background(Color(driver.background))
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .contain)
        .task { await load() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            PTStatusDot(color: session.isAsking ? PTColor.attention : (session.running ? PTColor.tint : .secondary.opacity(0.5)),
                        live: session.running)
            VStack(alignment: .leading, spacing: 2) {
                Text(shell.title(of: session)).font(.subheadline.weight(.semibold)).lineLimit(1)
                Text(RemoteShellCard.status(session, now: .now, kind: shell.selectedKind))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func message(_ text: String, icon: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon).font(.title2).foregroundStyle(.tertiary)
            Text(text).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding(24)
    }

    private func load() async {
        driver.apply(session.theme)
        guard let chunks = await shell.transcript(session.id, tail: Self.tailBytes) else {
            failed = true
            return
        }
        // A host that predates `tail` sends up to 8 MiB: draw only the end.
        replay = ShellReplay.tail(chunks, maxBytes: Self.tailBytes)
    }

    private static func hasOutput(_ replay: [ShellReplayChunk]) -> Bool {
        replay.contains { if case let .output(data) = $0 { !data.isEmpty } else { false } }
    }
}

extension View {
    /// Touch and hold to peek at a session (`ShellPeekView`), with Open, Rename
    /// and End session (or Remove, once it has finished) beneath.
    func shellPeek(_ session: ShellSessionInfo, shell: ShellModel,
                   open: @escaping () -> Void, rename: @escaping () -> Void) -> some View {
        contextMenu {
            Button(action: open) { Label("Open", systemImage: "terminal") }
            Button(action: rename) { Label("Rename", systemImage: "pencil") }
            if session.running {
                Button(role: .destructive) { shell.close(session.id) } label: { Label("End session", systemImage: "xmark") }
            } else {
                Button(role: .destructive) { shell.remove(session.id) } label: { Label("Remove", systemImage: "trash") }
            }
        } preview: {
            ShellPeekView(shell: shell, session: session)
        }
    }

    /// Asks for a new name for `session` while it's set; the name is this phone's own (`ShellModel.rename`).
    func shellRenamePrompt(_ session: Binding<ShellSessionInfo?>, shell: ShellModel) -> some View {
        modifier(ShellRenamePrompt(shell: shell, session: session))
    }
}

private struct ShellRenamePrompt: ViewModifier {
    let shell: ShellModel
    @Binding var session: ShellSessionInfo?
    @State private var name = ""

    func body(content: Content) -> some View {
        content
            .onChange(of: session?.id) { _, _ in
                if let session { name = shell.title(of: session) }
            }
            .alert("Rename shell", isPresented: Binding(get: { session != nil }, set: { if !$0 { session = nil } }),
                   presenting: session) { session in
                TextField(session.title, text: $name)
                    .autocorrectionDisabled()
                Button("Cancel", role: .cancel) {}
                Button("Save") { shell.rename(session.id, to: name) }
            } message: { session in
                Text("Only this \(ThisDevice.name) shows this name. Clear it to go back to \u{201C}\(session.title)\u{201D}.")
            }
    }
}
