import SwiftUI
import PassthroughCore
import PassthroughUI

/// An iPad's "Internet through iPhone" switch: on the iPhone's hotspot, but
/// with traffic leaving from the iPhone itself, so it isn't hotspot data.
/// While it's on and the iPhone isn't carrying it, the iPad is offline on
/// purpose, and the row says why and what to do.
struct HotspotRow: View {
    @ObservedObject var hotspot: HotspotModel
    let pair: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SwitchRow(title: "Internet through iPhone", symbol: "wifi", status: status, warning: warning,
                      isOn: hotspot.phase.isOn, pending: hotspot.phase == .starting,
                      enabled: hotspot.phase != .unpaired, problem: problem) { hotspot.setOn($0) }
                .accessibilityHint(hotspot.phase.isOn ? "Stops using the iPhone's internet" : "Uses the iPhone's internet without spending hotspot data")
            if hotspot.phase == .online {
                Label(onlineNote, systemImage: "checkmark.circle")
                    .font(.footnote)
                    .foregroundStyle(PTColor.tintText)
                    .padding(.leading, 58).padding(.trailing, 10).padding(.bottom, 10)
            }
        }
        .animation(.easeOut(duration: 0.25), value: hotspot.phase)
        .sensoryFeedback(.selection, trigger: hotspot.phase.isOn)
    }

    private var phone: String { hotspot.phoneName }

    private var status: String {
        switch hotspot.phase {
        case .unpaired: "Not paired with an iPhone"
        case .off: hotspot.onPhoneHotspot ? "Off \u{2014} on the hotspot like any device" : "Off"
        case .starting: "Turning on\u{2026}"
        case .online: "On \u{2014} through \(phone), over its hotspot"
        case .waiting: "On \u{2014} waiting for \(phone)"
        case .refused: "On \u{2014} \(phone) didn't let this iPad in"
        case .failed: "Off \u{2014} couldn't turn on"
        }
    }

    private var warning: Bool {
        switch hotspot.phase {
        case .waiting, .refused, .failed: true
        default: false
        }
    }

    private var onlineNote: String {
        let used = (hotspot.status?.rx ?? 0) + (hotspot.status?.tx ?? 0)
        let amount = ByteCountFormatter.string(fromByteCount: used, countStyle: .file)
        return "Leaves from the iPhone itself, so it isn't hotspot data \u{00B7} \(amount) since it went on"
    }

    private var problem: SwitchProblem? {
        switch hotspot.phase {
        case .unpaired:
            return .init("Pair with your iPhone to use its internet over its hotspot without spending hotspot data.",
                         fix: ("Pair with iPhone", pair))
        case .off, .starting, .online:
            return nil
        case .waiting:
            let what = hotspot.onPhoneHotspot
                ? "Open Passthrough on \(phone) and keep it on."
                : "Join \(phone)'s Personal Hotspot in Settings \u{25B8} Wi-Fi."
            let why = hotspot.status?.message.map { "\($0) " } ?? ""
            return .init("\(why)Offline on purpose: nothing leaves this iPad over the hotspot until \(phone) carries it. \(what)",
                         warning: true, fix: ("Use hotspot data instead", { hotspot.setOn(false) }))
        case .refused(let message):
            return .init(message, warning: true, fix: ("Pair again", pair))
        case .failed(let message):
            return .init(message, warning: true, fix: ("Try again", { hotspot.setOn(true) }))
        }
    }
}

/// The three devices and what joins them, as this iPad sees it.
struct DevicesStrip: View {
    @ObservedObject var hotspot: HotspotModel
    let macName: String?
    /// The Mac says it's online through the iPhone.
    let macOnline: Bool

    var body: some View {
        PTSurface(padding: 14) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 14) { title; strip; caption.frame(maxWidth: 170, alignment: .leading) }
                VStack(alignment: .leading, spacing: 12) { title; strip; caption }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var title: some View {
        Text("Your devices").font(.body.weight(.semibold))
    }

    private var strip: some View {
        HStack(spacing: 10) {
            if let macName {
                node(macName, symbol: "laptopcomputer", on: macOnline)
                wire(macOnline ? "Online" : "Not known", style: macOnline ? .solid : .idle)
            }
            node(hotspot.upstream == nil ? "No iPhone" : hotspot.phoneName, symbol: "iphone", on: hotspot.upstream != nil)
            wire(phoneWireLabel, style: phoneWireStyle)
            node("This iPad", symbol: "ipad", on: hotspot.phase == .online)
        }
    }

    private var caption: some View {
        Text(hotspot.upstream != nil && macName != nil ? "All three are paired, so each one lists the other two."
             : hotspot.upstream == nil ? "Pair with your iPhone to use its internet here." : "Pair a Mac to reach it from here.")
            .font(.footnote).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private enum WireStyle { case solid, waiting, idle }

    private var phoneWireLabel: String {
        switch hotspot.phase {
        case .online: "Passthrough"
        case .waiting, .starting: "Looking\u{2026}"
        case .refused: "Refused"
        default: "Hotspot only"
        }
    }

    private var phoneWireStyle: WireStyle {
        switch hotspot.phase {
        case .online: .solid
        case .waiting, .starting, .refused: .waiting
        default: .idle
        }
    }

    private func node(_ name: String, symbol: String, on: Bool) -> some View {
        HStack(spacing: 8) {
            SwitchIcon(symbol: symbol, on: on, warning: false)
            Text(name).font(.subheadline.weight(.semibold)).lineLimit(1)
        }
        .fixedSize()
    }

    private func wire(_ label: String, style: WireStyle) -> some View {
        let color: Color = style == .solid ? PTColor.tint : style == .waiting ? PTColor.attention : Color.secondary
        return VStack(spacing: 4) {
            Text(label).font(.caption.weight(.semibold))
                .foregroundStyle(style == .solid ? PTColor.tintText : style == .waiting ? PTColor.attentionText : .secondary)
                .lineLimit(1)
            WireLine()
                .stroke(color, style: StrokeStyle(lineWidth: 3, lineCap: .round, dash: style == .solid ? [] : [6, 6]))
                .frame(height: 3)
        }
        .frame(minWidth: 50, maxWidth: .infinity)
    }
}

/// A straight line across the middle of its frame.
private struct WireLine: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + 1.5, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.maxX - 1.5, y: rect.midY))
        return path
    }
}

/// iPad, This iPad: the iPhone it uses for internet, with Pair and Forget.
struct UpstreamPhoneCard: View {
    @ObservedObject var hotspot: HotspotModel
    @State private var pairing = false
    @State private var confirmForget = false

    var body: some View {
        PTSurface {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    PTSectionTitle("iPhone", icon: "iphone")
                    Spacer()
                    Button { pairing = true } label: {
                        Label(hotspot.upstream == nil ? "Pair" : "Pair again", systemImage: "qrcode").font(.caption.weight(.bold))
                    }
                    .buttonStyle(.bordered).buttonBorderShape(.capsule).tint(PTColor.tintText).controlSize(.small)
                }
                if let phone = hotspot.upstream {
                    HStack(spacing: 12) {
                        PTStatusDot(color: hotspot.phase == .online ? PTColor.tint : .secondary.opacity(0.5), live: hotspot.phase == .online)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(hotspot.status?.phoneName ?? phone.name).font(.subheadline.weight(.semibold))
                            Text(detail(phone)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Menu {
                            Button(role: .destructive) { confirmForget = true } label: { Label("Forget this iPhone", systemImage: "trash") }
                        } label: {
                            Image(systemName: "ellipsis.circle").foregroundStyle(.secondary).frame(width: 44, height: 44).contentShape(Rectangle())
                        }
                        .accessibilityLabel("More for \(phone.name)")
                    }
                    .frame(minHeight: 44)
                } else {
                    Text("Not paired yet. Pair to use your iPhone's internet over its hotspot without spending hotspot data.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Text("This iPad joins the iPhone's Personal Hotspot, and Passthrough sends its traffic out from the iPhone itself, not through the hotspot.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .sheet(isPresented: $pairing) { PairWithPhoneSheet(hotspot: hotspot) }
        .confirmationDialog("Forget \(hotspot.phoneName)?", isPresented: $confirmForget, titleVisibility: .visible) {
            Button("Forget", role: .destructive) { hotspot.forget() }
        } message: {
            Text("Internet through iPhone turns off. To use it again, pair again.")
        }
    }

    private func detail(_ phone: UpstreamPhone) -> String {
        var parts: [String] = []
        if hotspot.phase == .online {
            if let radio = hotspot.status?.radio { parts.append(radio) }
            if let battery = hotspot.status?.battery { parts.append("\(Int(battery * 100))% battery") }
            parts.insert("Connected", at: 0)
        } else {
            parts.append("Paired \(phone.pairedAt.formatted(.relative(presentation: .named)))")
        }
        return parts.joined(separator: " \u{00B7} ")
    }
}

/// The switch with its own pairing sheet, for places without one (the iPad tab).
struct HotspotPairingRow: View {
    @ObservedObject var hotspot: HotspotModel
    @State private var pairing = false

    var body: some View {
        HotspotRow(hotspot: hotspot) { pairing = true }
            .sheet(isPresented: $pairing) { PairWithPhoneSheet(hotspot: hotspot) }
    }
}
