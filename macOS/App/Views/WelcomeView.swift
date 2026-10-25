import SwiftUI
import PassthroughUI

/// First run: pick what the phone should do for this Mac, and see what each
/// choice needs, now or only when first used, instead of a wall of prompts.
/// Shown once, on a Mac that has never been set up; Continue applies the
/// picks (then, with Internet picked, says to plug in the phone), Skip just closes it.
struct WelcomeView: View {
    static let id = "welcome"
    static let doneKey = "welcomeDone"

    @EnvironmentObject private var session: SessionCoordinator
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openSettings) private var openSettings
    @State private var internet = true
    @State private var awake = true
    @State private var reach = true
    @State private var vpn = false
    /// Continue applied the picks: now say to plug in the phone.
    @State private var plugIn = false

    /// A Mac that has never been set up: no pairing, no shell phones, Remote shell off.
    @MainActor static func shouldShow(_ session: SessionCoordinator) -> Bool {
        !UserDefaults.standard.bool(forKey: doneKey) && !session.hasToken && !session.remoteShellEnabled && session.shell.phones.isEmpty
    }

    var body: some View {
        if plugIn { plugInStep } else { picker }
    }

    private var picker: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 8) {
                Text("What should your phone do for this Mac?")
                    .font(.system(size: 28, weight: .bold))
                Text("Pick any. You can change this later, and each one asks for permission only when it needs it.")
                    .font(.title3).foregroundStyle(.secondary)
            }
            HStack(alignment: .top, spacing: 20) {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                    choice($internet, "wifi", "Get online through my phone", "Plug in and the Mac uses the phone's connection. No hotspot.")
                    choice($awake, "cup.and.saucer", "Keep the Mac awake when I leave", 
                           session.keepAwake.hasLid ? "Lid closed is fine. It still sleeps when the battery is low or it gets hot." : "It still sleeps when it gets hot.")
                    choice($reach, "apple.terminal", "Reach the Mac from my phone", "Its shell and its screen, from anywhere, end-to-end encrypted.")
                    choice($vpn, "lock.shield", "Protect my traffic with a VPN", "NordVPN or WireGuard on top, with a kill switch for public Wi-Fi.")
                }
                needs.frame(width: 300)
            }
        }
        .padding(36)
        .frame(width: 900)
    }

    private func choice(_ on: Binding<Bool>, _ symbol: String, _ title: String, _ detail: String) -> some View {
        Button { on.wrappedValue.toggle() } label: {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: symbol)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(on.wrappedValue ? PTColor.onTint : Color.primary)
                        .frame(width: 40, height: 40)
                        .background(on.wrappedValue ? PTColor.tint : Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    Spacer()
                    Image(systemName: on.wrappedValue ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 20))
                        .foregroundStyle(on.wrappedValue ? PTColor.tintText : Color.secondary)
                }
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(18)
            .frame(maxWidth: .infinity, minHeight: 170, alignment: .topLeading)
            .background(on.wrappedValue ? PTColor.surfaceOn : Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(on.wrappedValue ? PTColor.tint.opacity(0.5) : Color.primary.opacity(0.08)))
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .animation(.easeOut(duration: 0.2), value: on.wrappedValue)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on.wrappedValue ? .isSelected : [])
    }

    private struct Need: Identifiable {
        var id: String { title }
        let title: String
        let why: String
        let when: String
        var now: Bool { when == "Now" }
    }

    private var list: [Need] {
        var needs: [Need] = []
        if internet || awake || vpn {
            needs.append(Need(title: "Approve the helper", why: "One admin prompt. It changes routes, lid-close sleep and the VPN, and nothing else.", when: "Now"))
        }
        if internet || reach {
            needs.append(Need(title: "Plug in your phone once", why: "Pairing and access keys only travel over the cable.", when: "Now"))
        }
        if reach {
            needs.append(Need(title: "Full Disk Access", why: "So commands from your phone don't stall on a privacy prompt nobody can click.", when: "First shell"))
            needs.append(Need(title: "Screen Recording and Accessibility", why: "To show the screen and click for you.", when: "First screen"))
        }
        if vpn {
            needs.append(Need(title: "Add a VPN", why: "Sign in to NordVPN or import a WireGuard file.", when: "First use"))
        }
        return needs
    }

    private var needs: some View {
        let needs = list
        let now = needs.filter(\.now).count
        return VStack(alignment: .leading, spacing: 0) {
            Text("What this needs").font(.headline)
            Text(needs.isEmpty ? "Pick something to get started." : "\(now) now, \(needs.count - now) later, when you first use it")
                .font(.callout).foregroundStyle(.secondary)
                .padding(.bottom, 6)
            ForEach(needs) { need in
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(need.title).font(.callout.weight(.semibold))
                        Text(need.why).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 6)
                    Text(need.when)
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .foregroundStyle(need.now ? PTColor.tintText : Color.secondary)
                        .background(need.now ? PTColor.tint.opacity(0.16) : Color.primary.opacity(0.07), in: Capsule())
                }
                .padding(.vertical, 10)
                Divider().opacity(0.5)
            }
            Spacer(minLength: 16)
            Button("Continue") { finish() }
                .buttonStyle(PTProminentButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(needs.isEmpty)
                .opacity(needs.isEmpty ? 0.5 : 1)
            Button("Skip for now") { skip() }
                .buttonStyle(.plain)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.top, 10)
            Text("Passthrough lives in the menu bar.")
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.top, 4)
        }
        .padding(18)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    /// With Internet picked, the last step: the phone goes online for the Mac once it's plugged in.
    private var plugInStep: some View {
        VStack(spacing: 16) {
            Image(systemName: "cable.connector")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(PTColor.onTint)
                .frame(width: 64, height: 64)
                .background(PTColor.tint, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            Text("Now plug in your phone").font(.system(size: 28, weight: .bold))
            Text("Connect it with a cable and unlock it. Trust this Mac if asked; an Android phone needs USB debugging on. The Mac goes online through it by itself.")
                .font(.title3).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button("Done") { close() }
                .buttonStyle(PTProminentButtonStyle())
                .keyboardShortcut(.defaultAction)
                .frame(width: 240)
                .padding(.top, 8)
            Text("Passthrough lives in the menu bar.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(48)
        .frame(width: 560)
    }

    /// Applies the picks: sharing connects by itself when plugged in (never
    /// turned off here: Auto-connect may already be on), the helper is asked
    /// for now, Remote shell turns on, and the VPN settings open. Keep awake
    /// needs nothing yet: it's a switch in the panel.
    private func finish() {
        UserDefaults.standard.set(true, forKey: Self.doneKey)
        if internet { session.autoConnect = true }
        if internet || awake || vpn { session.retryHelper() }
        if reach { session.remoteShellEnabled = true }
        if internet { plugIn = true } else { close() }
    }

    private func close() {
        dismiss()
        if vpn { SettingsWindow.show(openSettings, tab: .vpn) }
    }

    /// Nothing set up, and not shown again: it's all in the panel and Settings.
    private func skip() {
        UserDefaults.standard.set(true, forKey: Self.doneKey)
        dismiss()
    }
}
