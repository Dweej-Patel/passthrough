import Charts
import SwiftUI
import PassthroughCore
import PassthroughUI

/// What happened on the Mac: since you stepped away (within a day), else the
/// last 24 hours. A summary up top, the battery meanwhile, then each event.
struct ActivityTab: View {
    @ObservedObject var shell: ShellModel
    @EnvironmentObject private var router: ShellRouter

    /// Step away records when it happened; older than a day, the timeline shows the last 24 hours.
    static let steppedAwayKey = "PTSteppedAwayAt"
    private var steppedAway: Date? {
        let at = UserDefaults.standard.double(forKey: Self.steppedAwayKey)
        guard at > 0, Date.now.timeIntervalSince1970 - at < 86_400 else { return nil }
        return Date(timeIntervalSince1970: at)
    }
    private var since: Date { steppedAway ?? .now - 86_400 }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    content
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .background(PTColor.background)
            .navigationTitle("Activity")
            .refreshable { load() }
        }
        .onAppear(perform: load)
        .onChange(of: shell.reach) { _, reach in if reach == .ready { load() } }
    }

    private func load() { shell.loadTimeline(since: since) }

    @ViewBuilder private var content: some View {
        if shell.timelineUnsupported {
            notice("Update Passthrough on your Mac to see what happened on it.", symbol: "arrow.down.circle")
        } else if let timeline = shell.timeline {
            summary(timeline)
            if timeline.battery.count > 1 { BatteryChart(samples: timeline.battery, floor: shell.macState?.batteryFloor) }
            if shell.reach != .ready {
                Label("As of \(timeline.loadedAt.formatted(date: .omitted, time: .shortened)). Your Mac can't be reached right now.",
                      systemImage: "clock")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            events(timeline)
        } else if shell.reach == .ready || shell.timelineLoading {
            ProgressView().frame(maxWidth: .infinity, minHeight: 120)
        } else {
            notice("Your Mac's timeline shows up here once this iPhone can reach it.", symbol: "clock")
        }
    }

    private func notice(_ text: String, symbol: String) -> some View {
        PTSurface {
            Label(text, systemImage: symbol)
                .font(.subheadline).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Summary

    private func summary(_ timeline: MacTimeline) -> some View {
        let away = steppedAway != nil
        let answered = timeline.events.filter { $0.kind == "answered" }.count
        let dropouts = timeline.events.filter { $0.warning == true && ($0.kind == "vpn" || $0.kind == "link") }.count
        let finished = timeline.events.filter { $0.kind == "shell" }.count
        return PTSurface {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(away ? "While you were away" : "Last 24 hours").font(.headline)
                    Text(away ? "Since \(timeline.since.formatted(date: .omitted, time: .shortened)), \(Self.span(from: timeline.since))"
                              : "\(timeline.events.count) events")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                HStack(spacing: 0) {
                    stat("\(finished)", finished == 1 ? "shell finished" : "shells finished")
                    stat("\(answered)", "answered")
                    stat("\(dropouts)", dropouts == 1 ? "dropout" : "dropouts", warning: dropouts > 0)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func stat(_ value: String, _ label: String, warning: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.title2.weight(.bold)).monospacedDigit()
                .foregroundStyle(warning ? PTColor.attentionText : .primary)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    /// "2 h 14 m ago".
    static func span(from date: Date) -> String {
        MacHomeView.duration(max(0, Int(Date.now.timeIntervalSince(date) / 60))) + " ago"
    }

    // MARK: Events

    @ViewBuilder private func events(_ timeline: MacTimeline) -> some View {
        if timeline.events.isEmpty {
            notice("Nothing happened on your Mac in this time.", symbol: "checkmark.circle")
        } else {
            PTSurface(padding: 6) {
                VStack(spacing: 0) {
                    let newestFirst = Array(timeline.events.reversed())
                    ForEach(Array(newestFirst.enumerated()), id: \.offset) { index, event in
                        EventRow(event: event, open: opener(for: event))
                        if index < newestFirst.count - 1 { Divider().padding(.leading, 56) }
                    }
                }
            }
        }
    }

    /// A shell event opens the terminal while the session runs, else its history.
    private func opener(for event: MacEvent) -> (() -> Void)? {
        guard let id = event.session else { return nil }
        if shell.sessions.contains(where: { $0.id == id && $0.running }) { return { router.terminal = .attach(id) } }
        return { router.showHistory = true }
    }
}

private struct EventRow: View {
    let event: MacEvent
    let open: (() -> Void)?

    var body: some View {
        let row = HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(event.warning == true ? PTColor.onAttention : PTColor.tintText)
                .frame(width: 30, height: 30)
                .background(event.warning == true ? PTColor.attention : PTColor.tint.opacity(0.16), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(Date(timeIntervalSince1970: event.t).formatted(date: .omitted, time: .shortened))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Text(event.title).font(.subheadline.weight(.semibold))
                if let detail = event.detail {
                    Text(detail)
                        .font(event.kind == "asked" ? .system(.caption, design: .monospaced) : .caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            if open != nil {
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary).padding(.top, 20)
            }
        }
        .padding(10)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)

        if let open {
            Button(action: open) { row }.buttonStyle(.plain)
        } else {
            row
        }
    }

    private var symbol: String {
        switch event.kind {
        case "awake": "cup.and.saucer.fill"
        case "vpn": event.warning == true ? "exclamationmark.shield.fill" : "lock.shield.fill"
        case "link": "cable.connector"
        case "power": "bolt.fill"
        case "sleep": "moon.zzz.fill"
        case "shell": event.warning == true ? "xmark" : "checkmark"
        case "asked": "questionmark"
        case "answered": "arrowshape.turn.up.left.fill"
        default: "circle.fill"
        }
    }
}

/// The Mac's battery over the timeline: one mint line, Keep awake's limit as a
/// dashed rule, and the exact level under your finger.
private struct BatteryChart: View {
    let samples: [BatterySample]
    let floor: Double?
    @State private var picked: Date?

    private func date(_ s: BatterySample) -> Date { Date(timeIntervalSince1970: s.t) }

    private var pickedSample: BatterySample? {
        guard let picked else { return nil }
        return samples.min { abs(date($0).timeIntervalSince(picked)) < abs(date($1).timeIntervalSince(picked)) }
    }

    var body: some View {
        PTSurface {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Battery").font(.headline)
                    Spacer()
                    Text(caption).font(.subheadline.monospacedDigit()).foregroundStyle(.secondary).contentTransition(.numericText())
                }
                Chart {
                    ForEach(samples, id: \.t) { s in
                        LineMark(x: .value("Time", date(s)), y: .value("Battery", s.level))
                            .foregroundStyle(PTColor.tint)
                            .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                            .interpolationMethod(.monotone)
                    }
                    if let floor {
                        RuleMark(y: .value("Limit", floor))
                            .foregroundStyle(Color.secondary.opacity(0.6))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    }
                    if let s = pickedSample {
                        RuleMark(x: .value("Time", date(s))).foregroundStyle(Color.secondary.opacity(0.4))
                        PointMark(x: .value("Time", date(s)), y: .value("Battery", s.level))
                            .foregroundStyle(PTColor.tint)
                            .symbolSize(70)
                    }
                }
                .chartYScale(domain: 0...1)
                .chartYAxis {
                    AxisMarks(values: [0, 0.5, 1]) { value in
                        AxisGridLine().foregroundStyle(Color.primary.opacity(0.06))
                        AxisValueLabel { Text("\(Int((value.as(Double.self) ?? 0) * 100))%") }
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 3)) { _ in
                        AxisValueLabel(format: .dateTime.hour().minute(), collisionResolution: .greedy)
                    }
                }
                // Room at the ends so the first and last times aren't cut off.
                .chartXScale(range: .plotDimension(padding: 20))
                .chartXSelection(value: $picked)
                .frame(height: 120)
                .accessibilityLabel("Battery over time")
                .accessibilityValue(summary)
            }
        }
    }

    private var caption: String {
        if let s = pickedSample {
            return "\(Int((s.level * 100).rounded()))% at \(date(s).formatted(date: .omitted, time: .shortened))"
        }
        return floor.map { "Keep awake stops at \(Int(($0 * 100).rounded()))%" } ?? ""
    }

    private var summary: String {
        guard let first = samples.first, let last = samples.last else { return "" }
        let low = samples.map(\.level).min() ?? first.level
        return "From \(Int(first.level * 100))% to \(Int(last.level * 100))%, lowest \(Int(low * 100))%."
    }
}
