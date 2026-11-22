import SwiftUI
import PassthroughCore
import PassthroughUI

/// Lets another of this phone's computers use the one on screen, without this
/// phone (stage 7 a.6): pick what it may do and which computer, confirm with
/// Face ID, and the phone hands it access. Offered only when the computer on
/// screen said this phone may share it (`host.access.share`).
struct ShareComputerSheet: View {
    @ObservedObject var shell: ShellModel
    /// The computer being shared.
    let shared: ShellCredential
    @StateObject private var model = ComputerShareModel()
    @State private var withShell = false
    /// A computer that already has access was tapped: asked before it is shared again.
    @State private var again: ShellCredential?
    @Environment(\.dismiss) private var dismiss

    private var others: [ShellCredential] { shell.macs.filter { $0.macID != shared.macID } }

    private var scopes: [String] { withShell ? [Computers.scopeShell, Computers.scopeScreen] : [Computers.scopeScreen] }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("Access", selection: $withShell) {
                        Text("Screen only").tag(false)
                        Text("Shell and screen").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .disabled(model.isWorking)
                } footer: {
                    if withShell { Text("It can run commands as you on \(shared.macName).") }
                }

                Section {
                    ForEach(others, id: \.macID) { viewer in
                        let had = SharedComputers.entry(shared: shared.macID, viewer: viewer.macID)
                        Button {
                            // One that already has access isn't given it again by a stray tap.
                            if had != nil { again = viewer } else { model.share(shared, with: viewer, scopes: scopes, shell: shell) }
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: shell.kind(of: viewer.macID) == .windows ? "pc" : "desktopcomputer")
                                    .font(.title3)
                                    .foregroundStyle(PTColor.tint)
                                    .frame(width: 30)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(viewer.macName).foregroundStyle(.primary)
                                    if let had {
                                        Text("Has access (\(had.shell ? "shell and screen" : "screen only")), shared \(had.at.formatted(.relative(presentation: .named)))")
                                            .font(.caption).foregroundStyle(.secondary)
                                    } else {
                                        Text(shell.kind(of: viewer.macID) == .windows ? "PC" : "Mac").font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                Image(systemName: had != nil ? "checkmark.circle.fill" : "chevron.right")
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(had != nil ? AnyShapeStyle(PTColor.tintText) : AnyShapeStyle(.tertiary))
                            }
                        }
                        .disabled(model.isWorking)
                    }
                } header: {
                    Text("Which computer should use \(shared.macName)?")
                } footer: {
                    Text("That computer gets its own access to \(shared.macName), from anywhere, without this \(ThisDevice.name). It stops working if this \(ThisDevice.name) loses access to \(shared.macName). Remove it any time in Passthrough's settings on \(shared.macName).")
                }

                switch model.phase {
                case .idle:
                    EmptyView()
                case let .working(step):
                    Section {
                        HStack(spacing: 12) {
                            ProgressView()
                            Text(step).foregroundStyle(.secondary)
                        }
                    }
                case let .done(message):
                    Section {
                        Label(message, systemImage: "checkmark.circle.fill")
                            .foregroundStyle(PTColor.tintText)
                    }
                case let .failed(message):
                    Section {
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(PTColor.attentionText)
                    }
                }
            }
            .navigationTitle("Share")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .confirmationDialog(again.map { "\($0.macName) already has access to \(shared.macName)" } ?? "",
                            isPresented: Binding(get: { again != nil }, set: { if !$0 { again = nil } }), titleVisibility: .visible) {
            Button("Share Again") {
                if let viewer = again { model.share(shared, with: viewer, scopes: scopes, shell: shell) }
                again = nil
            }
            Button("Cancel", role: .cancel) { again = nil }
        } message: {
            Text("Sharing again replaces what it has with \(withShell ? "shell and screen" : "screen only"). If you removed its access on \(shared.macName), this gives it back.")
        }
        .sensoryFeedback(.success, trigger: model.phase) { _, new in if case .done = new { true } else { false } }
        .sensoryFeedback(.error, trigger: model.phase) { _, new in if case .failed = new { true } else { false } }
        .onDisappear { model.reset() }
    }
}
