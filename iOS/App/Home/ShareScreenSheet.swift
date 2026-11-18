import SwiftUI
import PassthroughCore
import PassthroughUI

/// Lets another of this phone's Macs see and control the Mac on screen: pick
/// the Mac, confirm with Face ID, and the phone hands it a screen-only pass.
struct ShareScreenSheet: View {
    @ObservedObject var shell: ShellModel
    /// The Mac whose screen is shared.
    let shared: ShellCredential
    @StateObject private var model = ScreenShareModel()
    @Environment(\.dismiss) private var dismiss

    private var others: [ShellCredential] { shell.macs.filter { $0.macID != shared.macID } }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(others, id: \.macID) { viewer in
                        Button {
                            model.share(shared, with: viewer, shell: shell)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "desktopcomputer")
                                    .font(.title3)
                                    .foregroundStyle(PTColor.tint)
                                    .frame(width: 30)
                                Text(viewer.macName).foregroundStyle(.primary)
                                Spacer()
                                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                            }
                        }
                        .disabled(model.isWorking)
                    }
                } header: {
                    Text("Which Mac should see \(shared.macName)?")
                } footer: {
                    Text("That Mac gets a pass to see and control \(shared.macName)'s screen, from anywhere, without this \(ThisDevice.name). Controlling it means it can type into any app on \(shared.macName), Terminal included; it can't open Passthrough's shells or change its settings, and opening it asks for Touch ID or the password on that Mac. It stops working if this \(ThisDevice.name) loses access or Screen on \(shared.macName). Remove it any time in Passthrough's Remote Shell settings on \(shared.macName).")
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
            .navigationTitle("Share Screen")
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
