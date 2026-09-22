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

    public init(perspective: Perspective, macName: String = "Mac", phoneName: String = "iPhone", linkUp: Bool = false, busy: Bool = false,
                radio: String? = nil, vpn: VPN? = nil, keepAwake: Bool = false, downRate: Double = 0, upRate: Double = 0, activeConnections: Int = 0) {
        self.perspective = perspective; self.macName = macName; self.phoneName = phoneName; self.linkUp = linkUp; self.busy = busy
        self.radio = radio; self.vpn = vpn; self.keepAwake = keepAwake; self.downRate = downRate; self.upRate = upRate
        self.activeConnections = activeConnections
    }
}

/// Animated picture of the path traffic takes: Mac ⟶ USB ⟶ iPhone ⟶ radio ⟶ (VPN) ⟶ Internet.
/// Particles ride the wires at a speed and density that follow live throughput
/// (teal toward the Mac, violet away from it); the VPN node slides in when the
/// layer is on, and a halo marks the Mac while keep-awake holds it up.
///
/// Cost: one `Canvas` redrawn by a `TimelineView` at ≤30 fps (15 fps when idle),
/// fully paused when nothing is connected or animating. No per-particle views.
public struct FlowMap: View {
    public var state: FlowMapState
    public var height: CGFloat

    @Environment(\.colorScheme) private var scheme
    @State private var clock = FlowClock()
    @State private var vpnChangedAt = Date.distantPast
    @State private var linkChangedAt = Date.distantPast
    @State private var settleTick = 0

    public init(state: FlowMapState, height: CGFloat = 120) {
        self.state = state
        self.height = height
    }

    private var transitioning: Bool {
        Date().timeIntervalSince(vpnChangedAt) < 0.8 || Date().timeIntervalSince(linkChangedAt) < 0.8
    }
    private var paused: Bool {
        !state.linkUp && !state.busy && !state.keepAwake && state.vpn == nil && !transitioning
    }
    private var interval: TimeInterval {
        (state.downRate + state.upRate) > 0 || state.busy || transitioning ? 1.0 / 30.0 : 1.0 / 15.0
    }

    public var body: some View {
        TimelineView(.animation(minimumInterval: interval, paused: paused)) { timeline in
            let now = timeline.date
            Canvas(rendersAsynchronously: false) { ctx, size in
                let vpnP = Self.progress(since: vpnChangedAt, now: now, target: state.vpn != nil)
                let linkP = Self.progress(since: linkChangedAt, now: now, target: state.linkUp)
                let travel = clock.advance(now: now, down: state.downRate, up: state.upRate)
                FlowRenderer(ctx: ctx, size: size, state: state, scheme: scheme, vpnProgress: vpnP, linkProgress: linkP,
                             travel: travel, t: now.timeIntervalSinceReferenceDate).draw()
            } symbols: {
                NodeSymbol(icon: "laptopcomputer", label: state.perspective == .iphone && state.activeConnections > 0 && state.macName == "Mac" ? "Mac" : state.macName,
                           tint: nodeTint(active: state.linkUp), dim: !state.linkUp && state.perspective == .iphone).tag(FlowSymbol.mac)
                NodeSymbol(icon: "iphone.gen3", label: state.phoneName, tint: nodeTint(active: state.linkUp || state.perspective == .iphone),
                           dim: !state.linkUp && state.perspective == .mac).tag(FlowSymbol.phone)
                NodeSymbol(icon: state.vpn?.blocked == true ? "exclamationmark.shield.fill" : "lock.shield.fill",
                           label: state.vpn.map { String($0.name.split(separator: "·").first ?? "VPN").trimmingCharacters(in: .whitespaces) } ?? "VPN",
                           tint: state.vpn?.blocked == true ? PTTheme.warning : (state.vpn?.connected == true ? PTTheme.success : Color.secondary),
                           dim: state.vpn?.connected != true).tag(FlowSymbol.vpn)
                NodeSymbol(icon: "globe", label: "Internet", tint: Color.secondary, dim: !state.linkUp).tag(FlowSymbol.internet)
                WireLabel("USB").tag(FlowSymbol.usbLabel)
                WireLabel(state.radio ?? "cellular").tag(FlowSymbol.radioLabel)
                Image(systemName: "lock.fill").font(.system(size: 9, weight: .bold)).foregroundStyle(PTTheme.up).tag(FlowSymbol.lock)
                Image(systemName: "cup.and.saucer.fill").font(.system(size: 10, weight: .bold)).foregroundStyle(PTTheme.warning).tag(FlowSymbol.cup)
                Image(systemName: "cable.connector.slash").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary).tag(FlowSymbol.unplugged)
            }
        }
        .frame(height: height)
        .onChange(of: state.vpn != nil) { _, _ in vpnChangedAt = Date(); settleLater() }
        .onChange(of: state.linkUp) { _, _ in linkChangedAt = Date(); settleLater() }
        .accessibilityLabel(accessibilityText)
    }

    private func nodeTint(active: Bool) -> Color { active ? PTTheme.accentStart : Color.secondary }

    /// Forces one re-evaluation after a transition so `paused` can flip back on.
    private func settleLater() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { settleTick += 1 }
    }

    private var accessibilityText: String {
        var s = state.linkUp ? "Traffic flows from \(state.macName) over USB to \(state.phoneName)" : "No traffic; USB link down"
        if let radio = state.radio { s += ", then over \(radio)" }
        if let vpn = state.vpn { s += vpn.connected ? ", encrypted through \(vpn.name)" : ", VPN \(vpn.name) connecting" }
        return s
    }

    /// 0…1 eased progress toward `target` since the last toggle.
    static func progress(since: Date, now: Date, target: Bool) -> Double {
        let raw = min(1, max(0, now.timeIntervalSince(since) / 0.55))
        let eased = 1 - pow(1 - raw, 3)
        return target ? eased : 1 - eased
    }
}

/// Symbols the canvas resolves (rendered once per frame, cached by SwiftUI).
enum FlowSymbol: Hashable { case mac, phone, vpn, internet, usbLabel, radioLabel, lock, cup, unplugged }

/// Integrates particle travel over time with smoothed speeds so rate changes
/// never make particles jump. A class so the canvas can update it while drawing.
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

/// All drawing for one frame.
struct FlowRenderer {
    let ctx: GraphicsContext
    let size: CGSize
    let state: FlowMapState
    let scheme: ColorScheme
    let vpnProgress: Double
    let linkProgress: Double
    let travel: (down: Double, up: Double)
    let t: Double

    private var nodeY: CGFloat { 30 }
    /// Nodes shrink a little as the VPN node slides in so four fit comfortably.
    private var nodeR: CGFloat { 22 - 3 * CGFloat(vpnProgress) }
    private var margin: CGFloat { state.perspective == .iphone ? 40 : 34 }
    /// Symbol images are 44 (circle) + 4 + ~12 (label) tall; this centres the circle on the wire.
    private var symbolOffset: CGFloat { 8 }

    /// Node x positions: 3 nodes (Mac, phone, Internet) morphing to 4 with the VPN inserted.
    private var xs: (mac: CGFloat, phone: CGFloat, vpn: CGFloat, internet: CGFloat) {
        let w = size.width
        func spread(_ n: Int, _ i: Int) -> CGFloat { margin + (w - 2 * margin) * CGFloat(i) / CGFloat(n - 1) }
        let p = CGFloat(vpnProgress)
        let mac = spread(3, 0)
        let phone = spread(3, 1) + (spread(4, 1) - spread(3, 1)) * p
        let internet = spread(3, 2)
        let vpn = spread(4, 2)
        return (mac, phone, vpn, internet)
    }

    func draw() {
        let x = xs
        let y = nodeY
        let showVPN = vpnProgress > 0.01
        let vpnLive = state.vpn?.connected == true && !(state.vpn?.blocked ?? false)
        let vpnBlocked = state.vpn?.blocked == true
        let linkAlpha = 0.25 + 0.75 * linkProgress

        // Wires
        var segments: [(from: CGFloat, to: CGFloat, encrypted: Bool, carries: Bool)] = []
        segments.append((x.mac + nodeR + 4, x.phone - nodeR - 4, showVPN, state.linkUp))
        if showVPN {
            segments.append((x.phone + nodeR + 4, x.vpn - nodeR - 4, true, state.linkUp))
            segments.append((x.vpn + nodeR + 4, x.internet - nodeR - 4, false, state.linkUp && vpnLive))
        } else {
            segments.append((x.phone + nodeR + 4, x.internet - nodeR - 4, false, state.linkUp))
        }

        for seg in segments {
            var path = Path()
            path.move(to: CGPoint(x: seg.from, y: y))
            path.addLine(to: CGPoint(x: seg.to, y: y))
            if seg.encrypted && state.vpn != nil {
                let sheath = vpnBlocked ? PTTheme.warning : PTTheme.up
                ctx.stroke(path, with: .color(sheath.opacity((vpnLive ? 0.22 : 0.12) * vpnProgress)), style: StrokeStyle(lineWidth: 11, lineCap: .round))
                if !vpnLive {
                    ctx.stroke(path, with: .color(sheath.opacity(0.7 * vpnProgress)), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [4, 5], dashPhase: CGFloat(-t * 20)))
                }
            }
            let base = Color.primary.opacity(scheme == .dark ? 0.16 : 0.12)
            if seg.carries || (seg.encrypted && state.vpn != nil) {
                ctx.stroke(path, with: .color(base.opacity(linkAlpha)), style: StrokeStyle(lineWidth: 2, lineCap: .round))
            } else {
                ctx.stroke(path, with: .color(base), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [3, 6]))
            }
        }

        // Particles: teal toward the Mac (down), violet away (up); each stream on its own lane.
        if state.linkUp {
            let carrying = segments.filter(\.carries)
            if let first = carrying.first, let last = carrying.last {
                let span = (from: first.from, to: last.to)
                // Gaps where nodes sit: particles hide inside nodes so they appear to pass through.
                let gaps: [ClosedRange<CGFloat>] = showVPN ? [(x.phone - nodeR)...(x.phone + nodeR), (x.vpn - nodeR)...(x.vpn + nodeR)] : [(x.phone - nodeR)...(x.phone + nodeR)]
                drawStream(span: span, gaps: gaps, y: y, rate: state.downRate, travel: travel.down, towardMac: true, color: PTTheme.down)
                drawStream(span: span, gaps: gaps, y: y, rate: state.upRate, travel: travel.up, towardMac: false, color: PTTheme.up)
            }
        } else if state.busy {
            // Connecting: a single scout pulse walks the USB wire.
            let seg = segments[0]
            let len = seg.to - seg.from
            let phase = CGFloat((t * 0.7).truncatingRemainder(dividingBy: 1))
            let head = seg.from + len * phase
            streak(head: head, tail: max(seg.from, head - 18), y: y, color: PTTheme.accentStart, alpha: 0.7)
        }

        // Keep-awake halo on the Mac.
        if state.keepAwake {
            let pulse = 0.5 + 0.5 * sin(t * 2.2)
            let r = nodeR + 6 + CGFloat(3 * pulse)
            ctx.stroke(Path(ellipseIn: CGRect(x: x.mac - r, y: y - r, width: 2 * r, height: 2 * r)),
                       with: .color(PTTheme.warning.opacity(0.28 + 0.18 * pulse)), lineWidth: 2)
            ctx.fill(Path(ellipseIn: CGRect(x: x.mac - r, y: y - r, width: 2 * r, height: 2 * r)), with: .color(PTTheme.warning.opacity(0.05 + 0.04 * pulse)))
        }

        // Nodes
        place(.mac, at: CGPoint(x: x.mac, y: y))
        place(.phone, at: CGPoint(x: x.phone, y: y))
        if showVPN {
            var c = ctx
            c.opacity = vpnProgress
            let s = 0.7 + 0.3 * vpnProgress
            c.translateBy(x: x.vpn, y: y)
            c.scaleBy(x: s, y: s)
            c.translateBy(x: -x.vpn, y: -y)
            if let sym = c.resolveSymbol(id: FlowSymbol.vpn) { c.draw(sym, at: CGPoint(x: x.vpn, y: y + symbolOffset)) }
        }
        place(.internet, at: CGPoint(x: x.internet, y: y))
        if state.keepAwake, let cup = ctx.resolveSymbol(id: FlowSymbol.cup) {
            ctx.draw(cup, at: CGPoint(x: x.mac + nodeR - 2, y: y - nodeR + 2))
        }
        if !state.linkUp && !state.busy && state.perspective == .mac, let sym = ctx.resolveSymbol(id: FlowSymbol.unplugged) {
            ctx.draw(sym, at: CGPoint(x: (x.mac + x.phone) / 2, y: y - 12))
        }

        // Wire labels below the wires, rate tags above the USB wire.
        let labelY = y + 15
        if let usb = ctx.resolveSymbol(id: FlowSymbol.usbLabel) { ctx.draw(usb, at: CGPoint(x: (x.mac + x.phone) / 2, y: labelY)) }
        let radioMid = showVPN ? (x.phone + x.vpn) / 2 : (x.phone + x.internet) / 2
        if let radio = ctx.resolveSymbol(id: FlowSymbol.radioLabel) { ctx.draw(radio, at: CGPoint(x: radioMid, y: labelY)) }
        if showVPN, state.vpn != nil, let lock = ctx.resolveSymbol(id: FlowSymbol.lock) {
            // A small lock above the encrypted radio hop; the engine is named in the VPN row.
            var c = ctx; c.opacity = vpnProgress
            c.draw(lock, at: CGPoint(x: radioMid, y: y - 12))
        }
    }

    private func place(_ id: FlowSymbol, at point: CGPoint) {
        if let sym = ctx.resolveSymbol(id: id) { ctx.draw(sym, at: CGPoint(x: point.x, y: point.y + symbolOffset)) }
    }

    /// One direction of flow: soft gradient streaks that fade in along the wire,
    /// so the traffic reads as light moving through the cable rather than dots.
    private func drawStream(span: (from: CGFloat, to: CGFloat), gaps: [ClosedRange<CGFloat>], y: CGFloat,
                            rate: Double, travel: Double, towardMac: Bool, color: Color) {
        let len = Double(span.to - span.from)
        guard len > 10 else { return }
        let norm = FlowClock.norm(rate)
        let n = rate > 0 ? 1 + Int(4 * norm) : 1
        let spacing = len / Double(n)
        let streakLen = CGFloat(rate > 0 ? 14 + 22 * norm : 12)
        let alpha = rate > 0 ? 0.42 + 0.3 * norm : 0.16
        for i in 0..<n {
            var d = (travel + Double(i) * spacing + (rate > 0 ? 0 : (t * 14))).truncatingRemainder(dividingBy: len)
            if d < 0 { d += len }
            let head = towardMac ? span.to - CGFloat(d) : span.from + CGFloat(d)
            if gaps.contains(where: { $0.contains(head) }) { continue }
            let tail = towardMac ? min(span.to, head + streakLen) : max(span.from, head - streakLen)
            streak(head: head, tail: tail, y: y, color: color, alpha: alpha)
        }
    }

    /// A short line whose colour fades from nothing at the tail to `alpha` at the head.
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

// MARK: - Symbols

private struct NodeSymbol: View {
    let icon: String
    let label: String
    let tint: Color
    let dim: Bool
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                Circle().fill(Color.primary.opacity(scheme == .dark ? 0.10 : 0.06))
                Circle().strokeBorder(tint.opacity(dim ? 0.2 : 0.5), lineWidth: 1.2)
                Image(systemName: icon).font(.system(size: 17, weight: .semibold)).foregroundStyle(tint)
            }
            .frame(width: 44, height: 44)
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
