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
                        Button {
                            model.share(shared, with: viewer, scopes: scopes, shell: shell)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: shell.kind(of: viewer.macID) == .windows ? "pc" : "desktopcomputer")
                                    .font(.title3)
                                    .foregroundStyle(PTColor.tint)
                                    .frame(width: 30)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(viewer.macName).foregroundStyle(.primary)
                                    Text(shell.kind(of: viewer.macID) == .windows ? "PC" : "Mac").font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
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
        .sensoryFeedback(.success, trigger: model.phase) { _, new in if case .done = new { true } else { false } }
        .sensoryFeedback(.error, trigger: model.phase) { _, new in if case .failed = new { true } else { false } }
        .onDisappear { model.reset() }
    }
}
