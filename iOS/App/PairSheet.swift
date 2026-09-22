import SwiftUI
import PassthroughCore
import PassthroughUI

struct PairSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var now = Date()
    private let clock = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            PTBackground(glow: 0.8)
            VStack(spacing: 26) {
                Capsule().fill(.secondary.opacity(0.4)).frame(width: 40, height: 5).padding(.top, 10)
                Spacer(minLength: 0)
                Image(systemName: "laptopcomputer.and.iphone")
                    .font(.system(size: 54, weight: .medium))
                    .foregroundStyle(PTTheme.accent)
                VStack(spacing: 6) {
                    Text("Pair a Mac").font(PTTheme.display(28))
                    Text("Open Passthrough in the menu bar on your Mac, plug in the cable, and enter this code.")
                        .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }
                if model.state != .running {
                    PTCard {
                        Label("Start the proxy first so the Mac can reach this phone.", systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote).foregroundStyle(PTTheme.warning)
                    }
                    .padding(.horizontal, 24)
                }
                if let code = model.pairingCode {
                    PairingCodeTiles(code: code.code, size: 50)
                    VStack(spacing: 6) {
                        ProgressView(value: remaining(code.expiry), total: PassthroughProtocol.pairingCodeLifetime)
                            .tint(PTTheme.accentEnd)
                            .frame(width: 220)
                        Text("Expires in \(ByteFormat.duration(remaining(code.expiry)))")
                            .font(PTTheme.mono(13)).foregroundStyle(.secondary)
                    }
                } else {
                    Button("Generate a new code") { model.beginPairing() }
                        .buttonStyle(.borderedProminent).tint(PTTheme.accentEnd)
                }
                Spacer(minLength: 0)
                Text("Codes are single use and only work over USB. Each Mac gets its own key you can revoke at any time.")
                    .font(.caption).foregroundStyle(.tertiary).multilineTextAlignment(.center).padding(.horizontal, 30)
                    .padding(.bottom, 24)
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.hidden)
        .onAppear { if model.pairingCode == nil { model.beginPairing() } }
        .onReceive(clock) { now = $0 }
        .onChange(of: model.pairedClients.count) { old, new in
            if new > old { dismiss() }
        }
    }

    private func remaining(_ expiry: Date) -> TimeInterval {
        max(0, expiry.timeIntervalSince(now))
    }
}
