import Combine
import SwiftUI
import PassthroughCore
import PassthroughUI

struct PairSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            PTBackground(glow: 0.8)
            VStack(spacing: 26) {
                Capsule().fill(.secondary.opacity(0.4)).frame(width: 40, height: 5).padding(.top, 10)
                Spacer(minLength: 0)
                Image(systemName: ThisDevice.isPad ? "laptopcomputer.and.ipad" : "laptopcomputer.and.iphone")
                    .font(.system(size: 54, weight: .medium))
                    .foregroundStyle(PTTheme.accent)
                VStack(spacing: 6) {
                    Text("Pair a Mac or PC").font(PTTheme.display(28))
                    Text("Open Passthrough on your Mac or PC, plug in the cable, and enter this code.")
                        .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }
                if model.state != .running, !ThisDevice.isPad {
                    PTCard {
                        VStack(alignment: .leading, spacing: 10) {
                            Label("The cable link is off, so the computer can't reach this \(ThisDevice.name) to pair.", systemImage: "exclamationmark.triangle.fill")
                                .font(.footnote).foregroundStyle(PTTheme.warning)
                                .fixedSize(horizontal: false, vertical: true)
                            Button(model.state == .starting ? "Turning on…" : "Turn on the cable link") { model.start() }
                                .buttonStyle(.bordered)
                                .disabled(model.state == .starting || model.state == .stopping)
                        }
                    }
                    .padding(.horizontal, 24)
                }
                if let code = model.pairingCode {
                    PairingCodeTiles(code: code.code, size: 50)
                    // Counted by the clock: a timer kept on this view was made anew
                    // each time the screen behind redrew (every second on an iPad)
                    // and so never fired, leaving the countdown at 5:00.
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        VStack(spacing: 6) {
                            ProgressView(value: remaining(code.expiry, now: context.date), total: PassthroughProtocol.pairingCodeLifetime)
                                .tint(PTTheme.accentEnd)
                                .frame(width: 220)
                            Text("Expires in \(ByteFormat.duration(remaining(code.expiry, now: context.date)))")
                                .font(PTTheme.mono(13)).foregroundStyle(.secondary)
                        }
                    }
                } else {
                    if model.pairingCodeWithdrawn {
                        PTCard {
                            VStack(alignment: .leading, spacing: 4) {
                                Label("That code was withdrawn", systemImage: "exclamationmark.triangle.fill")
                                    .font(.footnote.weight(.semibold)).foregroundStyle(PTTheme.warning)
                                Text(Self.withdrawnDetail).font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                        .padding(.horizontal, 24)
                    }
                    Button("Generate a new code") { model.beginPairing() }
                        .buttonStyle(.borderedProminent).tint(PTTheme.accentEnd)
                }
                Spacer(minLength: 0)
                Text("Codes are single use and only work over USB. Each computer gets its own key you can revoke at any time.")
                    .font(.caption).foregroundStyle(.tertiary).multilineTextAlignment(.center).padding(.horizontal, 30)
                    .padding(.bottom, 24)
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.hidden)
        .onAppear { if model.pairingCode == nil { model.beginPairing() } }
        .onChange(of: model.pairedClients.count) { old, new in
            if new > old { dismiss() }
        }
    }

    /// Why the code on screen went away early. Same words as the Android app's.
    static let withdrawnDetail = "Too many wrong codes were entered, so it no longer works. If that wasn't you, something on this phone or the computer tried to guess it. Generate a new code to pair."

    private func remaining(_ expiry: Date, now: Date) -> TimeInterval {
        max(0, expiry.timeIntervalSince(now))
    }
}
