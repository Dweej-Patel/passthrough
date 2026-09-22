import SwiftUI
import PassthroughCore

/// Sixty seconds of throughput: teal area for download, violet for upload.
/// Axes stay quiet; the peak value is the only label so the shape reads first.
///
/// Drawn with a `Canvas` (two smoothed paths, two gradient fills) rather than
/// Swift Charts: the chart re-laid out and animated its marks for most of
/// every second, which was the panel's single biggest CPU cost.
public struct ThroughputChart: View {
    let samples: [ThroughputSample]
    let height: CGFloat
    /// Number of samples the meter keeps; the newest sample sits at the right edge.
    let window: Int
    public init(samples: [ThroughputSample], height: CGFloat = 120, window: Int = 60) {
        self.samples = samples; self.height = height; self.window = window
    }

    private var hasTraffic: Bool { samples.contains { $0.down > 0 || $0.up > 0 } }
    private var peak: Double { max(samples.map { max($0.down, $0.up) }.max() ?? 0, 1024) }

    public var body: some View {
        ZStack(alignment: .topTrailing) {
            Canvas(rendersAsynchronously: false) { ctx, size in
                let downs = samples.map(\.down), ups = samples.map(\.up)
                let scale = peak * 1.15
                draw(ctx, size: size, values: downs, scale: scale, color: PTTheme.down, fillTop: 0.45, lineWidth: 2)
                draw(ctx, size: size, values: ups, scale: scale, color: PTTheme.up, fillTop: 0.35, lineWidth: 1.5)
            }
            if hasTraffic {
                let r = ByteFormat.rate(peak)
                Text("\(r.value) \(r.unit)").font(.caption2).foregroundStyle(.tertiary).padding(.trailing, 2)
            }
        }
        .frame(height: height)
        .accessibilityLabel("Throughput over the last minute")
    }

    /// Smooth line through the samples (Catmull-Rom → cubic Béziers) plus a
    /// gradient area beneath it. The newest sample sits at the right edge.
    private func draw(_ ctx: GraphicsContext, size: CGSize, values: [Double], scale: Double, color: Color, fillTop: Double, lineWidth: CGFloat) {
        guard values.count >= 2, scale > 0 else { return }
        let n = values.count
        let stepX = size.width / CGFloat(max(1, window - 1))
        let startX = size.width - stepX * CGFloat(n - 1)
        let inset: CGFloat = lineWidth
        func point(_ i: Int) -> CGPoint {
            let y = size.height - inset - CGFloat(min(1, values[i] / scale)) * (size.height - 2 * inset)
            return CGPoint(x: startX + stepX * CGFloat(i), y: y)
        }
        var line = Path()
        line.move(to: point(0))
        for i in 0..<(n - 1) {
            let p0 = point(max(0, i - 1)), p1 = point(i), p2 = point(i + 1), p3 = point(min(n - 1, i + 2))
            let c1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6)
            let c2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6)
            line.addCurve(to: p2, control1: c1, control2: c2)
        }
        var area = line
        area.addLine(to: CGPoint(x: point(n - 1).x, y: size.height))
        area.addLine(to: CGPoint(x: point(0).x, y: size.height))
        area.closeSubpath()
        ctx.fill(area, with: .linearGradient(Gradient(colors: [color.opacity(fillTop), color.opacity(0.02)]),
                                             startPoint: CGPoint(x: 0, y: 0), endPoint: CGPoint(x: 0, y: size.height)))
        ctx.stroke(line, with: .color(color), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
    }
}
