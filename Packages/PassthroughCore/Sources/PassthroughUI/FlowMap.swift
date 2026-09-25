import SwiftUI
import PassthroughCore

/// What the flow map shows. Build one from app state and hand it to `FlowMap`.
public struct FlowMapState: Equatable {
    public enum Perspective: Equatable { case mac, iphone }
    public struct VPN: Equatable {
        public var name: String
        public var engine: String
        public var connected: Bool
        public var blocked: Bool
        public init(name: String, engine: String, connected: Bool, blocked: Bool) {
            self.name = name; self.engine = engine; self.connected = connected; self.blocked = blocked
        }
    }

    public var perspective: Perspective
    public var macName: String
    public var phoneName: String
    /// SF Symbol for the phone node ("iphone.gen3", or "smartphone" for Android).
    public var phoneIcon: String
    /// The USB link carries traffic (passthrough connected / a Mac is served).
    public var linkUp: Bool
    /// Something is in progress (connecting, starting).
    public var busy: Bool
    /// The phone's radio label ("5G", "LTE", "Wi-Fi").
    public var radio: String?
    /// The VPN layer, when the user has turned it on (Mac only).
    public var vpn: VPN?
    public var keepAwake: Bool
    public var downRate: Double
    public var upRate: Double
    public var activeConnections: Int
    /// The VPN runs over the Mac's own Wi-Fi/Ethernet (passthrough off): the
    /// middle node becomes the local network instead of the iPhone.
    public var viaWiFi: Bool
    /// Label for that local network ("Wi-Fi", "Ethernet").
    public var localNetworkName: String
    /// The Mac and phone talk over the wireless link instead of the cable.
    public var wireless: Bool
    /// What carries that link ("Hotspot", "Peer-to-peer", "USB", "Wi-Fi network").
    public var wirelessCarrier: String?

    public init(perspective: Perspective, macName: String = "Mac", phoneName: String = "iPhone", phoneIcon: String = "iphone.gen3", linkUp: Bool = false, busy: Bool = false,
                radio: String? = nil, vpn: VPN? = nil, keepAwake: Bool = false, downRate: Double = 0, upRate: Double = 0, activeConnections: Int = 0,
                viaWiFi: Bool = false, localNetworkName: String = "Wi-Fi", wireless: Bool = false, wirelessCarrier: String? = nil) {
        self.perspective = perspective; self.macName = macName; self.phoneName = phoneName; self.phoneIcon = phoneIcon; self.linkUp = linkUp; self.busy = busy
        self.radio = radio; self.vpn = vpn; self.keepAwake = keepAwake; self.downRate = downRate; self.upRate = upRate
        self.activeConnections = activeConnections; self.viaWiFi = viaWiFi; self.localNetworkName = localNetworkName
        self.wireless = wireless
        self.wirelessCarrier = wirelessCarrier
    }
}

/// Animated picture of the path traffic takes: Mac ⟶ USB ⟶ iPhone ⟶ radio ⟶ (VPN) ⟶ Internet.
/// Streaks of light ride two lanes per hop (teal toward the Mac for download,
/// violet away for upload) at a speed and density that follow live throughput;
/// the VPN node slides in when the layer is on; a halo marks the Mac while
/// keep-awake holds it up.
///
/// Cost model: the per-frame layer is a `Canvas` drawing only paths (wires,
/// streaks, halo) under a `TimelineView` at ≤24 fps (12 when idle), paused
/// while nothing moves or the view isn't on screen. Nodes, icons and labels
/// live in an ordinary SwiftUI layer that re-renders only when state changes.
public struct FlowMap: View {
    public var state: FlowMapState
    public var height: CGFloat
    /// False when the hosting panel is hidden; stops the timeline entirely.
    public var active: Bool

    @Environment(\.colorScheme) private var scheme
    @State private var clock = FlowClock()
    @State private var vpnChangedAt = Date.distantPast
    @State private var linkChangedAt = Date.distantPast
    @State private var settleTick = 0

    public init(state: FlowMapState, height: CGFloat = 96, active: Bool = true) {
        self.state = state
        self.height = height
        self.active = active
    }

    private var transitioning: Bool {
        Date().timeIntervalSince(vpnChangedAt) < 0.8 || Date().timeIntervalSince(linkChangedAt) < 0.8
    }
    private var paused: Bool {
        !active || (!state.linkUp && !state.busy && !state.keepAwake && state.vpn == nil && !transitioning)
    }
    private var interval: TimeInterval {
        (state.downRate + state.upRate) > 0 || state.busy || transitioning ? 1.0 / 24.0 : 1.0 / 12.0
    }

    public var body: some View {
        GeometryReader { geo in
            ZStack {
                TimelineView(.animation(minimumInterval: interval, paused: paused)) { timeline in
                    let now = timeline.date
                    Canvas(rendersAsynchronously: false) { ctx, size in
                        let vpnP = FlowGeometry.progress(since: vpnChangedAt, now: now, target: state.vpn != nil)
                        let linkP = FlowGeometry.progress(since: linkChangedAt, now: now, target: state.linkUp)
                        let travel = clock.advance(now: now, down: state.downRate, up: state.upRate)
                        FlowWires(ctx: ctx, geometry: FlowGeometry(state: state, width: size.width, vpnProgress: vpnP),
                                  state: state, scheme: scheme, linkProgress: linkP, travel: travel,
                                  t: now.timeIntervalSinceReferenceDate).draw()
                    }
                }
                FlowNodes(state: state, geometry: FlowGeometry(state: state, width: geo.size.width, vpnProgress: state.vpn != nil ? 1 : 0))
                    .animation(.easeOut(duration: FlowGeometry.transitionDuration), value: state.vpn != nil)
            }
        }
        .frame(height: height)
        .onChange(of: state.vpn != nil) { _, _ in vpnChangedAt = Date(); settleLater() }
        .onChange(of: state.linkUp) { _, _ in linkChangedAt = Date(); settleLater() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    /// Forces one re-evaluation after a transition so `paused` can flip back on.
    private func settleLater() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { settleTick += 1 }
    }

    private var accessibilityText: String {
        let link = state.wireless ? (state.wirelessCarrier ?? "the wireless link") : "USB"
        var s = state.linkUp ? "Traffic flows from \(state.macName) over \(link) to \(state.phoneName)" : "No traffic; \(link) down"
        if let radio = state.radio { s += ", then over \(radio)" }
        if let vpn = state.vpn { s += vpn.connected ? ", encrypted through \(vpn.name)" : ", VPN \(vpn.name) connecting" }
        return s
    }
}

/// Node positions shared by the wire canvas and the node layer.
struct FlowGeometry {
    static let transitionDuration: TimeInterval = 0.55
    static let nodeY: CGFloat = 30
    static let laneOffset: CGFloat = 3.5
    let state: FlowMapState
    let width: CGFloat
    let vpnProgress: Double

    /// Nodes shrink a little as the VPN node slides in so four fit comfortably.
    var nodeR: CGFloat { 22 - 3 * CGFloat(vpnProgress) }
    var margin: CGFloat { state.perspective == .iphone ? 40 : 34 }

    var mac: CGFloat { spread(3, 0) }
    var phone: CGFloat { spread(3, 1) + (spread(4, 1) - spread(3, 1)) * CGFloat(vpnProgress) }
    var vpn: CGFloat { spread(4, 2) }
    var internet: CGFloat { spread(3, 2) }
    var showVPN: Bool { vpnProgress > 0.01 }
    var radioMid: CGFloat { showVPN ? (phone + vpn) / 2 : (phone + internet) / 2 }

    private func spread(_ n: Int, _ i: Int) -> CGFloat { margin + (width - 2 * margin) * CGFloat(i) / CGFloat(n - 1) }

    /// 0…1 eased progress toward `target` since the last toggle (cubic ease-out,
    /// matching the SwiftUI animation on the node layer).
    static func progress(since: Date, now: Date, target: Bool) -> Double {
        let raw = min(1, max(0, now.timeIntervalSince(since) / transitionDuration))
        let eased = 1 - pow(1 - raw, 3)
        return target ? eased : 1 - eased
    }
}

/// Integrates particle travel over time with smoothed speeds so rate changes
/// never make streaks jump. A class so the canvas can update it while drawing.
final class FlowClock {
    private var last: Date?
    private var speedDown = 0.0, speedUp = 0.0
    private(set) var travelDown = 0.0, travelUp = 0.0

    func advance(now: Date, down: Double, up: Double) -> (down: Double, up: Double) {
        let dt = min(0.1, max(0, now.timeIntervalSince(last ?? now)))
        last = now
        let k = 1 - exp(-dt * 4)
        speedDown += (Self.pixelsPerSecond(down) - speedDown) * k
        speedUp += (Self.pixelsPerSecond(up) - speedUp) * k
        travelDown += speedDown * dt
        travelUp += speedUp * dt
        return (travelDown, travelUp)
    }

    /// 2 KB/s ≈ crawl, 30 MB/s ≈ full speed; log-scaled so both ends stay readable.
    static func norm(_ bytesPerSecond: Double) -> Double {
        guard bytesPerSecond > 0 else { return 0 }
        return min(1, max(0, log10(1 + bytesPerSecond / 2000) / log10(1 + 30_000_000 / 2000)))
    }
    static func pixelsPerSecond(_ rate: Double) -> Double {
        rate <= 0 ? 0 : 36 + 260 * norm(rate)
    }
}

/// Per-frame drawing: only paths. No text, no symbols, no view layout.
struct FlowWires {
    let ctx: GraphicsContext
    let geometry: FlowGeometry
    let state: FlowMapState
    let scheme: ColorScheme
    let linkProgress: Double
    let travel: (down: Double, up: Double)
    let t: Double

    func draw() {
        let g = geometry
        let y = FlowGeometry.nodeY
        let r = g.nodeR
        let vpnLive = state.vpn?.connected == true && !(state.vpn?.blocked ?? false)
        let vpnBlocked = state.vpn?.blocked == true
        let linkAlpha = 0.25 + 0.75 * linkProgress
        let lane = FlowGeometry.laneOffset

        var segments: [(from: CGFloat, to: CGFloat, encrypted: Bool, carries: Bool)] = []
        segments.append((g.mac + r + 4, g.phone - r - 4, g.showVPN, state.linkUp))
        if g.showVPN {
            segments.append((g.phone + r + 4, g.vpn - r - 4, true, state.linkUp))
            segments.append((g.vpn + r + 4, g.internet - r - 4, false, state.linkUp && vpnLive))
        } else {
            segments.append((g.phone + r + 4, g.internet - r - 4, false, state.linkUp))
        }

        for seg in segments {
            func line(_ dy: CGFloat) -> Path {
                var p = Path(); p.move(to: CGPoint(x: seg.from, y: y + dy)); p.addLine(to: CGPoint(x: seg.to, y: y + dy)); return p
            }
            if seg.encrypted && state.vpn != nil {
                let sheath = vpnBlocked ? PTTheme.warning : PTTheme.up
                ctx.stroke(line(0), with: .color(sheath.opacity((vpnLive ? 0.20 : 0.10) * g.vpnProgress)), style: StrokeStyle(lineWidth: 16, lineCap: .round))
                if !vpnLive {
                    ctx.stroke(line(0), with: .color(sheath.opacity(0.6 * g.vpnProgress)), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [4, 5], dashPhase: CGFloat(-t * 20)))
                }
            }
            let neutral = Color.primary.opacity(scheme == .dark ? 0.16 : 0.12)
            if seg.carries {
                let tint = (scheme == .dark ? 0.30 : 0.38) * linkAlpha
                ctx.stroke(line(-lane), with: .color(PTTheme.down.opacity(tint)), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                ctx.stroke(line(lane), with: .color(PTTheme.up.opacity(tint)), style: StrokeStyle(lineWidth: 2, lineCap: .round))
            } else if seg.encrypted && state.vpn != nil {
                ctx.stroke(line(-lane), with: .color(neutral), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                ctx.stroke(line(lane), with: .color(neutral), style: StrokeStyle(lineWidth: 2, lineCap: .round))
            } else {
                ctx.stroke(line(0), with: .color(neutral), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [3, 6]))
            }
        }

        if state.linkUp {
            let carrying = segments.filter(\.carries)
            if let first = carrying.first, let last = carrying.last {
                let span = (from: first.from, to: last.to)
                let gaps: [ClosedRange<CGFloat>] = g.showVPN ? [(g.phone - r)...(g.phone + r), (g.vpn - r)...(g.vpn + r)] : [(g.phone - r)...(g.phone + r)]
                drawStream(span: span, gaps: gaps, y: y - lane, rate: state.downRate, travel: travel.down, towardMac: true, color: PTTheme.down)
                drawStream(span: span, gaps: gaps, y: y + lane, rate: state.upRate, travel: travel.up, towardMac: false, color: PTTheme.up)
            }
        } else if state.busy {
            let seg = segments[0]
            let len = seg.to - seg.from
            let phase = CGFloat((t * 0.7).truncatingRemainder(dividingBy: 1))
            let head = seg.from + len * phase
            streak(head: head, tail: max(seg.from, head - 18), y: y, color: PTTheme.accentStart, alpha: 0.7)
        }

        if state.keepAwake {
            let pulse = 0.5 + 0.5 * sin(t * 2.2)
            let hr = r + 6 + CGFloat(3 * pulse)
            let rect = CGRect(x: g.mac - hr, y: y - hr, width: 2 * hr, height: 2 * hr)
            ctx.stroke(Path(ellipseIn: rect), with: .color(PTTheme.warning.opacity(0.28 + 0.18 * pulse)), lineWidth: 2)
            ctx.fill(Path(ellipseIn: rect), with: .color(PTTheme.warning.opacity(0.05 + 0.04 * pulse)))
        }
    }

    /// One direction of flow: soft gradient streaks that fade in along the wire.
    private func drawStream(span: (from: CGFloat, to: CGFloat), gaps: [ClosedRange<CGFloat>], y: CGFloat,
                            rate: Double, travel: Double, towardMac: Bool, color: Color) {
        let len = Double(span.to - span.from)
        guard len > 10 else { return }
        let norm = FlowClock.norm(rate)
        let n = rate > 0 ? 1 + Int(4 * norm) : 1
        let spacing = len / Double(n)
        let streakLen = CGFloat(rate > 0 ? 14 + 22 * norm : 12)
        let alpha = rate > 0 ? 0.55 + 0.35 * norm : 0.22
        for i in 0..<n {
            var d = (travel + Double(i) * spacing + (rate > 0 ? 0 : (t * 14))).truncatingRemainder(dividingBy: len)
            if d < 0 { d += len }
            let head = towardMac ? span.to - CGFloat(d) : span.from + CGFloat(d)
            if gaps.contains(where: { $0.contains(head) }) { continue }
            let tail = towardMac ? min(span.to, head + streakLen) : max(span.from, head - streakLen)
            streak(head: head, tail: tail, y: y, color: color, alpha: alpha)
        }
    }

    private func streak(head: CGFloat, tail: CGFloat, y: CGFloat, color: Color, alpha: Double) {
        var path = Path()
        path.move(to: CGPoint(x: tail, y: y))
        path.addLine(to: CGPoint(x: head, y: y))
        let shading = GraphicsContext.Shading.linearGradient(
            Gradient(colors: [color.opacity(0), color.opacity(alpha)]),
            startPoint: CGPoint(x: tail, y: y), endPoint: CGPoint(x: head, y: y))
        ctx.stroke(path, with: shading, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
    }
}

/// Nodes, icons and labels: plain SwiftUI, re-rendered only when state changes.
private struct FlowNodes: View {
    let state: FlowMapState
    let geometry: FlowGeometry

    private var vpnLabel: String {
        guard let vpn = state.vpn else { return "VPN" }
        return String(vpn.name.split(separator: "·").first ?? "VPN").trimmingCharacters(in: .whitespaces)
    }
    private var vpnTint: Color {
        guard let vpn = state.vpn else { return .secondary }
        return vpn.blocked ? PTTheme.warning : (vpn.connected ? PTTheme.success : .secondary)
    }

    var body: some View {
        let g = geometry
        let y = FlowGeometry.nodeY
        let active = PTTheme.accentStart
        ZStack {
            NodeView(icon: "laptopcomputer", label: state.macName, tint: state.linkUp ? active : .secondary,
                     dim: !state.linkUp && state.perspective == .iphone, radius: g.nodeR)
                .position(x: g.mac, y: y + 8)
            if state.viaWiFi {
                NodeView(icon: "wifi.router", label: state.localNetworkName, tint: state.linkUp ? active : .secondary,
                         dim: !state.linkUp, radius: g.nodeR)
                    .position(x: g.phone, y: y + 8)
            } else {
                NodeView(icon: state.phoneIcon, label: state.phoneName, tint: (state.linkUp || state.perspective == .iphone) ? active : .secondary,
                         dim: !state.linkUp && state.perspective == .mac, radius: g.nodeR)
                    .position(x: g.phone, y: y + 8)
            }
            if state.vpn != nil {
                NodeView(icon: state.vpn?.blocked == true ? "exclamationmark.shield.fill" : "lock.shield.fill", label: vpnLabel,
                         tint: vpnTint, dim: state.vpn?.connected != true, radius: g.nodeR)
                    .position(x: g.vpn, y: y + 8)
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
                Image(systemName: "lock.fill").font(.system(size: 9, weight: .bold)).foregroundStyle(PTTheme.up)
                    .position(x: g.radioMid, y: y - 12)
                    .transition(.opacity)
            }
            NodeView(icon: "globe", label: "Internet", tint: .secondary, dim: !state.linkUp, radius: g.nodeR)
                .position(x: g.internet, y: y + 8)
            WireLabel(state.viaWiFi ? state.localNetworkName : (state.wireless ? (state.wirelessCarrier ?? "Wireless") : "USB")).position(x: (g.mac + g.phone) / 2, y: y + 15)
            if !state.viaWiFi { WireLabel(state.radio ?? "cellular").position(x: g.radioMid, y: y + 15) }
            if state.keepAwake {
                Image(systemName: "cup.and.saucer.fill").font(.system(size: 10, weight: .bold)).foregroundStyle(PTTheme.warning)
                    .position(x: g.mac + g.nodeR - 2, y: y - g.nodeR + 2)
            }
            if !state.linkUp && !state.busy && state.perspective == .mac && !state.viaWiFi {
                Image(systemName: state.wireless ? "wifi.slash" : "cable.connector.slash").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
                    .position(x: (g.mac + g.phone) / 2, y: y - 12)
            }
        }
    }
}

private struct NodeView: View {
    let icon: String
    let label: String
    let tint: Color
    let dim: Bool
    let radius: CGFloat
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                Circle().fill(Color.primary.opacity(scheme == .dark ? 0.10 : 0.06))
                Circle().strokeBorder(tint.opacity(dim ? 0.2 : 0.5), lineWidth: 1.2)
                Image(systemName: icon).font(.system(size: 17, weight: .semibold)).foregroundStyle(tint)
            }
            .frame(width: radius * 2, height: radius * 2)
            Text(label).font(.system(size: 9.5, weight: .medium, design: .rounded)).lineLimit(1).foregroundStyle(.secondary)
                .frame(width: 66)
        }
        .opacity(dim ? 0.55 : 1)
    }
}

private struct WireLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.uppercased()).font(.system(size: 8, weight: .semibold, design: .rounded)).tracking(0.8)
            .foregroundStyle(.tertiary)
    }
}
