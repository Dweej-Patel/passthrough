import SwiftUI
import WidgetKit
import PassthroughCore
import PassthroughUI

/// The Mac at a glance, as the app last saw it: awake time counting down,
/// battery, and shells waiting on a question; once the Mac stops answering,
/// or after `MacSnapshot.staleAfter`, when it was last heard. Tapping it opens the Mac tab.
struct MacWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: MacSnapshot.widgetKind, provider: Provider()) { entry in
            MacWidgetView(snapshot: entry.snapshot, stale: entry.stale)
                .containerBackground(for: .widget) { PTColor.surface }
                .widgetURL(AppLink.mac.url)
        }
        .configurationDisplayName("Mac")
        .description("Your Mac's awake time and shells, as Passthrough last saw them.")
        .supportedFamilies([.systemSmall])
    }

    struct Entry: TimelineEntry {
        let date: Date
        let snapshot: MacSnapshot?

        /// Out of reach, or too long without word: say when it was last heard.
        var stale: Bool {
            guard let snapshot else { return false }
            return !snapshot.reachable || date >= snapshot.updatedAt + MacSnapshot.staleAfter
        }
    }

    struct Provider: TimelineProvider {
        func placeholder(in context: Context) -> Entry {
            Entry(date: .now, snapshot: MacSnapshot(macName: "MacBook Pro", reachable: true, awake: true, awakeUntil: .now + 11_400,
                                                    battery: 0.64, charging: false, vpnOn: false, runningShells: 2, waiting: 0, updatedAt: .now))
        }

        func getSnapshot(in context: Context, completion: @escaping (Entry) -> Void) {
            completion(context.isPreview ? placeholder(in: context) : Entry(date: .now, snapshot: MacSnapshot.load()))
        }

        func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> Void) {
            // The app reloads this whenever it learns something; the countdown
            // runs by itself meanwhile, until the snapshot goes stale.
            let snapshot = MacSnapshot.load()
            var entries = [Entry(date: .now, snapshot: snapshot)]
            if let snapshot, snapshot.updatedAt + MacSnapshot.staleAfter > .now {
                entries.append(Entry(date: snapshot.updatedAt + MacSnapshot.staleAfter, snapshot: snapshot))
            }
            completion(Timeline(entries: entries, policy: .never))
        }
    }
}

private struct MacWidgetView: View {
    let snapshot: MacSnapshot?
    let stale: Bool

    var body: some View {
        if let snapshot {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: snapshot.awake ? "cup.and.saucer.fill" : "laptopcomputer")
                        .foregroundStyle(snapshot.awake ? PTColor.tintText : .secondary)
                    if snapshot.waiting > 0 {
                        Spacer(minLength: 0)
                        Circle().fill(PTColor.attention).frame(width: 9, height: 9).accessibilityLabel("A shell needs you")
                    }
                }
                Spacer(minLength: 0)
                Group {
                    if stale {
                        Text("Last heard \(snapshot.updatedAt.formatted(date: .omitted, time: .shortened))")
                    } else if snapshot.awake, !snapshot.charging, let until = snapshot.awakeUntil, until > .now {
                        Text(timerInterval: snapshot.updatedAt...until, countsDown: true, showsHours: true).monospacedDigit()
                    } else {
                        Text(snapshot.awake ? (snapshot.charging ? "Plugged in" : "Awake") : "Sleeps as usual")
                    }
                }
                .font(.title3.weight(.bold))
                .minimumScaleFactor(0.7)
                .lineLimit(1)
                Text(detail(snapshot)).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                Text(snapshot.macName).font(.caption2.weight(.semibold)).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: "laptopcomputer").foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Text("Open Passthrough to see your Mac here.").font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private func detail(_ s: MacSnapshot) -> String {
        if s.waiting > 0 { return s.waiting == 1 ? "A shell needs you" : "\(s.waiting) shells need you" }
        var parts: [String] = []
        if let battery = s.battery { parts.append(MacFormat.percent(battery)) }
        parts.append(s.runningShells == 1 ? "1 shell" : "\(s.runningShells) shells")
        if stale { return parts.joined(separator: " · ") + (s.reachable ? "" : " · not answering") }
        return parts.joined(separator: " · ") + " · \(s.updatedAt.formatted(date: .omitted, time: .shortened))"
    }
}
