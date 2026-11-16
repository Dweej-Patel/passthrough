import SwiftUI
import CoreImage.CIFilterBuiltins
import PassthroughCore
import PassthroughUI
import PhoneTransport

/// iPad: pairs with the iPhone whose internet it will use. The QR code holds
/// this iPad's certificate fingerprint and a one-time secret; the iPhone scans
/// it and dials this iPad over its hotspot (`IPadEnrollment`). The code works
/// once, for five minutes, and a new one replaces it while the sheet is open.
struct PairWithPhoneSheet: View {
    @ObservedObject var hotspot: HotspotModel
    @Environment(\.dismiss) private var dismiss
    @State private var invitation: IPadEnrollment.Invitation?
    @State private var listener: EnrollmentListener?
    @State private var paired: String?
    @State private var problem: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Then this iPad can use the iPhone's internet over its hotspot, without spending hotspot data.")
                        .font(.subheadline).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let paired {
                        Label("Paired with \(paired)", systemImage: "checkmark.circle.fill")
                            .font(.headline).foregroundStyle(PTColor.tintText)
                    } else {
                        scanCard
                    }
                    if let problem {
                        SwitchNote(problem: .init(problem, warning: true))
                    }
                }
                .padding(24)
                .frame(maxWidth: 560, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .background(PTColor.background)
            .navigationTitle("Pair with your iPhone")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(paired == nil ? "Cancel" : "Done") { dismiss() } }
            }
        }
        .task { await showCodes() }
        .onDisappear { listener?.stop(); listener = nil }
    }

    private var scanCard: some View {
        PTSurface {
            HStack(alignment: .center, spacing: 20) {
                Group {
                    if let invitation, let image = Self.qrImage(invitation.url.absoluteString) {
                        Image(uiImage: image).interpolation(.none).resizable()
                            .accessibilityLabel("Pairing code for the iPhone to scan")
                    } else {
                        ProgressView()
                    }
                }
                .frame(width: 180, height: 180)
                .padding(12)
                .background(Color.white, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                VStack(alignment: .leading, spacing: 10) {
                    Text("Scan with iPhone").font(.headline)
                    Text("On the iPhone, open Passthrough, go to the iPhone tab, then Pair \u{25B8} Scan an iPad's code.")
                        .font(.subheadline)
                        .fixedSize(horizontal: false, vertical: true)
                    if !hotspot.onPhoneHotspot {
                        Label("Join the iPhone's Personal Hotspot first (Settings \u{25B8} Wi-Fi), so it can reach this iPad.",
                              systemImage: "wifi.exclamationmark")
                            .font(.footnote).foregroundStyle(PTColor.attentionText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text("Works once, for 5 minutes. The camera carries the key, like the cable does for a Mac.")
                        .font(.footnote).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// Shows a code and listens for the iPhone, with a new code each time one expires.
    private func showCodes() async {
        let identity: MacIdentity
        do {
            identity = try MacIdentity.loadOrCreate(label: HotspotTunnel.identityLabel, accessGroup: PassthroughProtocol.appGroup)
        } catch {
            problem = "This iPad couldn't make its pairing key: \(error.localizedDescription)"
            return
        }
        let store = hotspot.store
        while paired == nil, !Task.isCancelled {
            let invitation = IPadEnrollment.Invitation(clientID: store.clientID(), name: ThisDevice.displayName,
                                                       certSHA256: identity.fingerprint)
            let listener = EnrollmentListener(invitation: invitation, identity: identity)
            listener.onEnrolled = { phone in
                // Kept before answering "enrolled", so the iPhone stores it only once this iPad has.
                guard store.save(phone) else { return false }
                Task { @MainActor in
                    hotspot.adopted(phone)
                    paired = phone.name
                }
                return true
            }
            do {
                try listener.start()
            } catch {
                problem = "This iPad couldn't listen for the iPhone: \(error.localizedDescription)"
                return
            }
            self.listener?.stop()
            self.listener = listener
            self.invitation = invitation
            try? await Task.sleep(for: .seconds(IPadEnrollment.lifetime - 5))
        }
    }

    static func qrImage(_ text: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage,
              let cg = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}
