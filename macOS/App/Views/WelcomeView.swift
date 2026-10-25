import SwiftUI
import PassthroughUI

/// First run: pick what the phone should do for this Mac, and see what each
/// choice needs, now or only when first used, instead of a wall of prompts.
/// Shown once, on a Mac that has never been set up; Continue applies the picks.
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

    /// A Mac that has never been set up: no pairing, no shell phones, Remote shell off.
    @MainActor static func shouldShow(_ session: SessionCoordinator) -> Bool {
        !UserDefaults.standard.bool(forKey: doneKey) && !session.hasToken && !session.remoteShellEnabled && session.shell.phones.isEmpty
    }

    var body: some View {
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
                    choice($awake, "cup.and.saucer", "Keep the Mac awake when I leave", "Lid closed is fine. It still sleeps when the battery is low or it gets hot.")
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
            needs.append(Need(title: "Screen Recording and Accessibility", why: "To show the screen and click for you.", when: "First Screen"))
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
            Text("Passthrough lives in the menu bar.")
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.top, 8)
        }
        .padding(18)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    /// Applies the picks: sharing connects by itself when plugged in, the
    /// helper is asked for now, Remote shell turns on, and the VPN settings
    /// open. Keep awake needs nothing yet: it's a switch in the panel.
    private func finish() {
        UserDefaults.standard.set(true, forKey: Self.doneKey)
        session.autoConnect = internet
        if internet || awake || vpn { session.retryHelper() }
        if reach { session.remoteShellEnabled = true }
        dismiss()
        if vpn { SettingsWindow.show(openSettings, tab: .vpn) }
    }
}
