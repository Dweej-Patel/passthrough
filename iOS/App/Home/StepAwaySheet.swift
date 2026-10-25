import SwiftUI
import PassthroughCore
import PassthroughUI

/// Before leaving the Mac: what would bite once you're gone, each with a fix
/// where this phone can make one. "Step away" then switches to Away, which
/// only works while this phone can change the Mac's switches.
struct StepAwaySheet: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var shell: ShellModel
    let online: Bool
    let stepAway: () -> Void
    @Environment(\.dismiss) private var dismiss

    private struct Check: Identifiable {
        let id: String
        let ok: Bool
        let title: String
        let detail: String
        var fix: (title: String, action: () -> Void)?
    }

    private var state: MacState? { shell.macState }
    private var reachable: Bool { shell.reach == .ready }
    private var canControl: Bool { reachable && state?.control == true }

    /// Why Step away can't switch to Away from here; nil when it can.
    private var blocker: String? {
        if !reachable { return "Your Mac can't be reached right now, so this iPhone can't switch it to Away." }
        guard let state else { return "Your Mac hasn't said how it is. Update Passthrough on it to step away from here." }
        if state.control != true { return "Turn on Awake & VPN for this iPhone in Passthrough's Remote Shell settings on the Mac to step away from here." }
        return nil
    }

    private var checks: [Check] {
        var list: [Check] = []
        let hasLid = state?.hasLid ?? true
        if state?.awake == true {
            list.append(Check(id: "awake", ok: true, title: hasLid ? "Stays awake, even with the lid closed" : "Stays awake",
                              detail: hasLid ? "It still sleeps at its battery limit or if it gets hot." : "It still sleeps if it gets hot."))
        } else {
            list.append(Check(id: "awake", ok: false, title: "It will sleep",
                              detail: canControl ? "Keep awake is off, so shells pause once it sleeps." : "Keep awake is off. Turn it on at the Mac, or allow Awake & VPN for this iPhone there.",
                              fix: canControl ? ("Turn on", { shell.control(.awake(true)) }) : nil))
        }
        if let state, let battery = state.battery {
            if state.charging == true {
                list.append(Check(id: "battery", ok: true, title: "Plugged in", detail: "\(MacFormat.percent(battery)) and charging."))
            } else if let minutes = state.minutesLeft {
                let short = minutes < 120
                list.append(Check(id: "battery", ok: !short, title: MacFormat.duration(minutes: minutes) + " on battery",
                                  detail: short ? "Plug it in if you'll be gone longer." : "Until its \(MacFormat.percent(state.batteryFloor ?? 0)) limit, at the current rate."))
            } else {
                list.append(Check(id: "battery", ok: battery > 0.5, title: "\(MacFormat.percent(battery)) on battery",
                                  detail: "Plug it in if you'll be gone a while."))
            }
        }
        if online {
            list.append(Check(id: "internet", ok: false, title: "Online through this iPhone",
                              detail: "When you take it, the Mac falls back to its own Wi-Fi. Switch now to be sure it's online before you go.",
                              fix: ("Switch now", { model.stop() })))
        } else {
            list.append(Check(id: "internet", ok: true, title: "On its own connection", detail: "It doesn't need this iPhone to stay online."))
        }
        let anywhere = shell.selectedReachesFromAnywhere
        list.append(anywhere
            ? Check(id: "reach", ok: true, title: "Reachable from anywhere", detail: "Its shell and screen, from any network.")
            : Check(id: "reach", ok: false, title: "Reachable on this network only",
                    detail: "Turn on \u{201C}Reach this Mac from anywhere\u{201D} in Passthrough's Remote Shell settings on the Mac."))
        let running = shell.sessions.filter(\.running).count
        if running > 0 {
            list.append(Check(id: "shells", ok: true, title: running == 1 ? "1 shell keeps running" : "\(running) shells keep running",
                              detail: anywhere ? "Pick them up from here, or from anywhere." : "Pick them up from here, on the Mac's network."))
        }
        return list
    }

    var body: some View {
        let checks = self.checks
        let issues = checks.filter { !$0.ok }.count
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(checks) { check in
                        row(check)
                        if check.id != checks.last?.id { Divider().padding(.leading, 40) }
                    }
                }
                .padding(.horizontal, 20)
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 8) {
                    Button { stepAway(); dismiss() } label: { Label("Step away", systemImage: "figure.walk") }
                        .buttonStyle(PTProminentButtonStyle())
                        .disabled(blocker != nil)
                        // The style draws the same when disabled.
                        .opacity(blocker != nil ? 0.45 : 1)
                    Text(blocker ?? (issues == 0 ? "Switches to Away: Keep awake on, off this iPhone's connection."
                                     : issues == 1 ? "1 thing above may stop it working while you're gone." : "\(issues) things above may stop it working while you're gone."))
                        .font(.footnote).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            }
            .navigationTitle("Before you go")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
        .presentationDetents([.large])
    }

    private func row(_ check: Check) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: check.ok ? "checkmark" : "exclamationmark")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(check.ok ? PTColor.onTint : PTColor.onAttention)
                .frame(width: 26, height: 26)
                .background(check.ok ? PTColor.tint : PTColor.attention, in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(check.title).font(.subheadline.weight(.semibold))
                Text(check.detail).font(.footnote).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if let fix = check.fix {
                Button(fix.title, action: fix.action)
                    .font(.subheadline.weight(.semibold))
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .tint(PTColor.attentionText)
                    .frame(minHeight: 44)
            }
        }
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
        .animation(.easeOut(duration: 0.25), value: check.ok)
    }
}

/// When Step away last switched the Mac to Away: the Activity tab shows
/// what happened since, for a day.
enum StepAwayStore {
    private static let key = "PTSteppedAwayAt"

    static func record(_ date: Date = .now) {
        UserDefaults.standard.set(date.timeIntervalSince1970, forKey: key)
    }

    /// Within the last day, else nil.
    static var steppedAway: Date? {
        let at = UserDefaults.standard.double(forKey: key)
        guard at > 0, Date.now.timeIntervalSince1970 - at < 86_400 else { return nil }
        return Date(timeIntervalSince1970: at)
    }
}
