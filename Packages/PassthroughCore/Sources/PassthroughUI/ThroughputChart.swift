import SwiftUI
import Charts
import PassthroughCore

/// Sixty seconds of throughput: teal area for download, violet for upload.
/// Axes stay quiet; the peak value is the only label so the shape reads first.
public struct ThroughputChart: View {
    let samples: [ThroughputSample]
    let height: CGFloat
    public init(samples: [ThroughputSample], height: CGFloat = 120) {
        self.samples = samples; self.height = height
    }

    private var hasTraffic: Bool { samples.contains { $0.down > 0 || $0.up > 0 } }
    private var peak: Double { max(samples.map { max($0.down, $0.up) }.max() ?? 0, 1024) }

    public var body: some View {
        Chart {
            ForEach(samples) { s in
                AreaMark(x: .value("t", s.id), y: .value("down", s.down), series: .value("dir", "down"))
                    .foregroundStyle(LinearGradient(colors: [PTTheme.down.opacity(0.45), PTTheme.down.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                    .interpolationMethod(.monotone)
                LineMark(x: .value("t", s.id), y: .value("down", s.down), series: .value("dir", "down"))
                    .foregroundStyle(PTTheme.down)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
                    .interpolationMethod(.monotone)
                AreaMark(x: .value("t", s.id), y: .value("up", s.up), series: .value("dir", "up"))
                    .foregroundStyle(LinearGradient(colors: [PTTheme.up.opacity(0.35), PTTheme.up.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                    .interpolationMethod(.monotone)
                LineMark(x: .value("t", s.id), y: .value("up", s.up), series: .value("dir", "up"))
                    .foregroundStyle(PTTheme.up)
                    .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round))
                    .interpolationMethod(.monotone)
            }
        }
        .chartYScale(domain: 0...(peak * 1.15))
        .chartXAxis(.hidden)
        .chartYAxis {
            AxisMarks(values: hasTraffic ? [peak] : []) { _ in
                AxisValueLabel {
                    let r = ByteFormat.rate(peak)
                    Text("\(r.value) \(r.unit)").font(.caption2).foregroundStyle(.tertiary)
                }
            }
        }
        .chartLegend(.hidden)
        .frame(height: height)
        .animation(.linear(duration: 0.9), value: samples.last?.id)
        .accessibilityLabel("Throughput over the last minute")
    }
}
