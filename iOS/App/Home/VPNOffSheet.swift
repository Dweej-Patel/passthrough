import SwiftUI
import LocalAuthentication
import PassthroughUI

/// Turning the Mac's VPN off from the phone: it lowers protection, so it
/// says what changes and asks for Face ID, Touch ID or the passcode first. The
/// system draws the prompt. Turning the VPN on never comes through here.
struct VPNOffSheet: View {
    let macName: String
    let killSwitch: Bool
    let turnOff: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var checking = false
    @State private var failure: String?
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        ScrollView {
            content.padding(22)
        }
        .scrollBounceBehavior(.basedOnSize)
        // Half height fits until the accessibility sizes; it scrolls either way.
        .presentationDetents(typeSize.isAccessibilitySize ? [.large] : [.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                Image(systemName: "lock.slash")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(PTColor.attentionText)
                    .frame(width: 48, height: 48)
                    .background(PTColor.attention.opacity(0.16), in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text("Turn VPN off?").font(.title3.weight(.bold))
                    Text("Lowers protection, so it asks first").font(.subheadline.weight(.semibold)).foregroundStyle(PTColor.attentionText)
                }
            }
            Text("\(macName)'s traffic will leave without the VPN\(killSwitch ? ", and the kill switch turns off too" : "").")
                .font(.subheadline)
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(PTColor.attention.opacity(0.1), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .fixedSize(horizontal: false, vertical: true)
            Text("\(Self.confirmedBy) The Mac shows a notice. Turning the VPN back on never asks.")
                .font(.footnote).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let failure {
                Label(failure, systemImage: "exclamationmark.circle.fill")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(PTColor.problem)
            }
            Button("Keep VPN on") { dismiss() }
                .buttonStyle(PTProminentButtonStyle())
            Button { confirm() } label: {
                Text("Turn VPN off")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(PTColor.attentionText)
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .overlay(Capsule().strokeBorder(PTColor.attention.opacity(0.5)))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(checking)
        }
    }

    /// How this phone checks it's you: whatever `deviceOwnerAuthentication` will ask for.
    private static var confirmedBy: String {
        let context = LAContext()
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil) else { return "This iPhone has no passcode, so nothing confirms it." }
        switch context.biometryType {
        case .faceID: return "Face ID confirms it."
        case .touchID: return "Touch ID confirms it."
        case .opticID: return "Optic ID confirms it."
        default: return "Your passcode confirms it."
        }
    }

    private func confirm() {
        checking = true
        failure = nil
        let context = LAContext()
        Task {
            defer { checking = false }
            do {
                try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Turn the VPN off on \(macName)")
                turnOff()
                dismiss()
            } catch let error as LAError where error.code == .userCancel || error.code == .appCancel || error.code == .systemCancel {
                // Cancelled: stay on the sheet, nothing changed.
            } catch let error as LAError where error.code == .passcodeNotSet {
                // Nothing to check on a phone without a passcode, as the app lock does.
                turnOff()
                dismiss()
            } catch {
                failure = "Couldn't confirm it's you. The VPN stays on."
            }
        }
    }
}
