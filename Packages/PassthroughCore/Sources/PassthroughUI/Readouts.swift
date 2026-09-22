import SwiftUI
import PassthroughCore

/// Large throughput number with a unit and direction glyph.
public struct RateReadout: View {
    let bytesPerSecond: Double
    let direction: Direction
    let size: CGFloat
    public enum Direction { case down, up }

    public init(_ bytesPerSecond: Double, direction: Direction, size: CGFloat = 34) {
        self.bytesPerSecond = bytesPerSecond; self.direction = direction; self.size = size
    }

    public var body: some View {
        let rate = ByteFormat.rate(bytesPerSecond)
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Image(systemName: direction == .down ? "arrow.down" : "arrow.up")
                .font(.system(size: size * 0.45, weight: .heavy))
                .foregroundStyle(direction == .down ? PTTheme.down : PTTheme.up)
            Text(rate.value)
                .font(PTTheme.mono(size, weight: .bold))
                .contentTransition(.numericText())
            Text(rate.unit)
                .font(PTTheme.display(size * 0.42, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .animation(.snappy(duration: 0.25), value: rate.value)
        .accessibilityLabel("\(direction == .down ? "Download" : "Upload") \(rate.value) \(rate.unit)")
    }
}

/// Label + value pair used in stat rows.
public struct StatCell: View {
    let title: String
    let value: String
    let tint: Color?
    public init(_ title: String, value: String, tint: Color? = nil) { self.title = title; self.value = value; self.tint = tint }
    public var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(PTTheme.mono(17, weight: .semibold)).foregroundStyle(tint ?? .primary)
                .contentTransition(.numericText())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Animated ring that idles grey, spins while connecting, and glows when live.
public struct StatusRing: View {
    public enum Mode: Equatable { case idle, busy, live, error }
    let mode: Mode
    let size: CGFloat
    let lineWidth: CGFloat
    @State private var spin = false
    @State private var breathe = false

    public init(mode: Mode, size: CGFloat = 180, lineWidth: CGFloat = 10) {
        self.mode = mode; self.size = size; self.lineWidth = lineWidth
    }

    public var body: some View {
        ZStack {
            Circle()
                .stroke(Color.primary.opacity(0.08), lineWidth: lineWidth)
            switch mode {
            case .idle:
                EmptyView()
            case .busy:
                Circle()
                    .trim(from: 0, to: 0.28)
                    .stroke(PTTheme.accentAngular, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(spin ? 360 : 0))
                    .animation(.linear(duration: 1.1).repeatForever(autoreverses: false), value: spin)
            case .live:
                Circle()
                    .stroke(PTTheme.accentAngular, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(spin ? 360 : 0))
                    .animation(.linear(duration: 6).repeatForever(autoreverses: false), value: spin)
                    .shadow(color: PTTheme.accentStart.opacity(breathe ? 0.55 : 0.25), radius: breathe ? 26 : 14)
                    .animation(.easeInOut(duration: 2.2).repeatForever(autoreverses: true), value: breathe)
            case .error:
                Circle()
                    .stroke(PTTheme.danger.opacity(0.8), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            }
        }
        .frame(width: size, height: size)
        .onAppear { spin = true; breathe = true }
    }
}

/// Six digit pairing code rendered as large tiles.
public struct PairingCodeTiles: View {
    let code: String
    let size: CGFloat
    public init(code: String, size: CGFloat = 52) { self.code = code; self.size = size }
    public var body: some View {
        HStack(spacing: size * 0.16) {
            ForEach(Array(code.enumerated()), id: \.offset) { index, ch in
                Text(String(ch))
                    .font(PTTheme.mono(size * 0.62, weight: .bold))
                    .frame(width: size, height: size * 1.25)
                    .background(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous).fill(.thinMaterial))
                    .overlay(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous).strokeBorder(PTTheme.accent, lineWidth: 1.5).opacity(0.7))
                if index == 2 { Spacer().frame(width: size * 0.2) }
            }
        }
    }
}

/// Diagnostics log list.
public struct LogList: View {
    let entries: [PassthroughLog.Entry]
    public init(entries: [PassthroughLog.Entry]) { self.entries = entries }
    public var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(entries) { entry in
                        HStack(alignment: .top, spacing: 8) {
                            Text(entry.date, format: .dateTime.hour().minute().second())
                                .font(.system(.caption2, design: .monospaced)).foregroundStyle(.tertiary)
                            Text(entry.message)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(color(for: entry.level))
                                .textSelection(.enabled)
                        }
                        .id(entry.id)
                    }
                }
                .padding(10)
            }
            .onChange(of: entries.count) { _, _ in
                if let last = entries.last { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func color(for level: PassthroughLog.Level) -> Color {
        switch level {
        case .debug: return .secondary
        case .info: return .primary
        case .warning: return PTTheme.warning
        case .error: return PTTheme.danger
        }
    }
}
