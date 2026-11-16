import SwiftUI
import AVFoundation
import LocalAuthentication
import PassthroughCore
import PassthroughUI

/// iPhone: adds an iPad by scanning the code it shows. The iPad then uses this
/// iPhone's internet over its Personal Hotspot, its traffic leaving from this
/// phone's own network stack. Adding one asks for Face ID, like anything that
/// lets a new device use this phone.
struct IPadScannerSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var invitation: IPadEnrollment.Invitation?
    @State private var phase = Phase.scanning

    enum Phase: Equatable {
        case scanning, confirm, pairing
        case done(String)
        case failed(String)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                switch phase {
                case .scanning: scanner
                case .confirm: confirm
                case .pairing:
                    ProgressView("Pairing with \(invitation?.name ?? "the iPad")\u{2026}").padding(.top, 60)
                case .done(let name): done(name)
                case .failed(let message): failed(message)
                }
                Spacer(minLength: 0)
            }
            .padding(20)
            .frame(maxWidth: .infinity)
            .background(PTColor.background)
            .navigationTitle("Add an iPad")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(phase == .scanning ? "Cancel" : "Close") { dismiss() } }
            }
        }
    }

    private var scanner: some View {
        VStack(spacing: 16) {
            Text("On the iPad, open Passthrough and tap Pair with iPhone. Then point this camera at the code.")
                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            QRScannerView { text in
                guard phase == .scanning, let url = URL(string: text) else { return }
                guard let invitation = IPadEnrollment.Invitation(url: url) else { return }
                guard !invitation.isExpired else { phase = .failed(IPadEnrollment.EnrollmentError.expired.localizedDescription); return }
                self.invitation = invitation
                phase = .confirm
            }
            .aspectRatio(1, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(PTColor.tint.opacity(0.6), lineWidth: 2))
            .frame(maxWidth: 360)
        }
    }

    private var confirm: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Add \(invitation?.name ?? "this iPad")?", systemImage: "ipad")
                .font(.title2.weight(.bold))
            Text("It will use this iPhone's internet while it's on this iPhone's Personal Hotspot. Its traffic leaves from this iPhone itself, not through the hotspot.")
                .font(.subheadline).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("You can remove it any time under Paired devices.")
                .font(.footnote).foregroundStyle(.secondary)
            Button { Task { await add() } } label: {
                Label("Add iPad", systemImage: "faceid").frame(maxWidth: .infinity)
            }
            .buttonStyle(PTProminentButtonStyle())
        }
        .frame(maxWidth: 480)
    }

    private func done(_ name: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 52)).foregroundStyle(PTColor.tint)
            Text("\(name) is paired").font(.title3.weight(.semibold))
            Text(model.state == .running
                 ? "Turn on Internet through iPhone on the iPad. It works while Passthrough is on here."
                 : "Turn Passthrough on here, then Internet through iPhone on the iPad.")
                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if model.state != .running {
                Button("Turn Passthrough on") { model.start(); dismiss() }.buttonStyle(PTProminentButtonStyle())
            }
        }
        .padding(.top, 40)
    }

    private func failed(_ message: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 44)).foregroundStyle(PTColor.attention)
            Text(message).font(.subheadline).multilineTextAlignment(.center)
            Button("Scan again") { invitation = nil; phase = .scanning }.buttonStyle(PTProminentButtonStyle())
        }
        .padding(.top, 40)
    }

    private func add() async {
        guard let invitation else { return }
        let context = LAContext()
        do {
            guard try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Let \(invitation.name) use this iPhone's internet") else { return }
        } catch {
            return   // cancelled: stay on the question
        }
        phase = .pairing
        switch await model.addIPad(invitation) {
        case .success: phase = .done(invitation.name)
        case .failure(let error): phase = .failed(error.localizedDescription)
        }
    }
}

/// The camera, reporting each QR code it reads.
struct QRScannerView: UIViewRepresentable {
    let found: (String) -> Void

    func makeUIView(context: Context) -> ScannerView {
        let view = ScannerView()
        view.found = found
        view.start()
        return view
    }

    func updateUIView(_ view: ScannerView, context: Context) { view.found = found }

    static func dismantleUIView(_ view: ScannerView, coordinator: ()) { view.stop() }

    final class ScannerView: UIView, AVCaptureMetadataOutputObjectsDelegate {
        var found: ((String) -> Void)?
        private let session = AVCaptureSession()
        private let sessionQueue = DispatchQueue(label: "\(PassthroughProtocol.identifier).scanner")
        private var preview: AVCaptureVideoPreviewLayer?

        func start() {
            backgroundColor = .black
            let preview = AVCaptureVideoPreviewLayer(session: session)
            preview.videoGravity = .resizeAspectFill
            layer.addSublayer(preview)
            self.preview = preview
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                guard granted, let self else { return }
                self.sessionQueue.async { self.configure() }
            }
        }

        private func configure() {
            guard let camera = AVCaptureDevice.default(for: .video), let input = try? AVCaptureDeviceInput(device: camera),
                  session.canAddInput(input) else { return }
            session.addInput(input)
            let output = AVCaptureMetadataOutput()
            guard session.canAddOutput(output) else { return }
            session.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: .main)
            output.metadataObjectTypes = [.qr]
            session.startRunning()
        }

        func stop() { sessionQueue.async { [session] in session.stopRunning() } }

        override func layoutSubviews() {
            super.layoutSubviews()
            preview?.frame = bounds
        }

        func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput objects: [AVMetadataObject], from connection: AVCaptureConnection) {
            for case let code as AVMetadataMachineReadableCodeObject in objects {
                if let text = code.stringValue { found?(text) }
            }
        }
    }
}
