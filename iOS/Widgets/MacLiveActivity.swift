import ActivityKit
import SwiftUI
import WidgetKit
import PassthroughUI
import PassthroughCore

/// The Live Activity a Step away starts: the Mac's awake time counting down
/// (on its own, without the app), and what the app last saw: running shells,
/// the VPN, and that a shell is waiting on a question (never which: it's on
/// the Lock Screen). Tapping it opens that shell. Once the Mac stops answering
/// or it goes stale, it says when it last heard instead of counting down.
struct MacLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: MacActivityAttributes.self) { context in
            LockScreenActivity(context: context)
                .activitySystemActionForegroundColor(PTColor.tintText)
                .widgetURL(link(context.state).url)
        } dynamicIsland: { context in
            let state = context.state
            let stale = context.isStale || !state.reachable
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label(context.attributes.macName, systemImage: "laptopcomputer")
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    AwakeTime(state: state, stale: stale).font(.subheadline.weight(.semibold)).foregroundStyle(PTColor.tint)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    if state.waitingSession != nil {
                        Label(Summary.needsYou, systemImage: "questionmark.bubble")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(PTColor.attention)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        Text(Summary.line(state))
                            .font(.caption).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            } compactLeading: {
                Image(systemName: "cup.and.saucer.fill").foregroundStyle(PTColor.tint)
            } compactTrailing: {
                if state.waitingSession != nil {
                    Circle().fill(PTColor.attention).frame(width: 10, height: 10)
                        .accessibilityLabel(Summary.needsYou)
                } else {
                    AwakeTime(state: state, stale: stale, compact: true).foregroundStyle(PTColor.tint)
                }
            } minimal: {
                if state.waitingSession != nil {
                    Circle().fill(PTColor.attention).frame(width: 10, height: 10)
                } else {
                    Image(systemName: "cup.and.saucer.fill").foregroundStyle(PTColor.tint)
                }
            }
            .widgetURL(link(state).url)
            .keylineTint(PTColor.tint)
        }
    }

    private func link(_ state: MacActivityAttributes.ContentState) -> AppLink {
        state.waitingSession.map(AppLink.session) ?? .mac
    }
}

/// Time left awake, counting down without updates; "Plugged in" or "Awake"
/// when there's no end; when it last heard from the Mac once that's out of date.
struct AwakeTime: View {
    let state: MacActivityAttributes.ContentState
    let stale: Bool
    var compact = false

    var body: some View {
        if stale {
            Text(compact ? Summary.time(state.updatedAt) : "Last heard \(Summary.time(state.updatedAt))")
                .monospacedDigit()
        } else if state.charging {
            Text(compact ? "On" : "Plugged in")
        } else if let until = state.awakeUntil, until > .now {
            Text(timerInterval: state.updatedAt...until, countsDown: true, showsHours: true)
                .monospacedDigit()
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: compact ? 56 : 90, alignment: .trailing)
        } else {
            Text("Awake")
        }
    }
}

enum Summary {
    static let needsYou = "A shell needs you"

    /// "2 shells running · VPN on · as of 12:24".
    static func line(_ state: MacActivityAttributes.ContentState) -> String {
        var parts = [state.runningShells == 1 ? "1 shell running" : "\(state.runningShells) shells running"]
        if state.vpnOn { parts.append("VPN on") }
        parts.append(state.reachable ? "as of \(time(state.updatedAt))" : "not answering")
        return parts.joined(separator: " · ")
    }

    static func time(_ date: Date) -> String { date.formatted(date: .omitted, time: .shortened) }
}

private struct LockScreenActivity: View {
    let context: ActivityViewContext<MacActivityAttributes>

    var body: some View {
        let state = context.state
        let stale = context.isStale || !state.reachable
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "cup.and.saucer.fill").foregroundStyle(PTColor.tintText)
                Text("\(context.attributes.macName) · away since \(Summary.time(context.attributes.startedAt))")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 0)
                if state.vpnOn {
                    Image(systemName: "lock.shield.fill").foregroundStyle(PTColor.tintText).accessibilityLabel("VPN on")
                }
            }
            HStack(alignment: .firstTextBaseline) {
                AwakeTime(state: state, stale: stale).font(.title2.weight(.bold))
                Text(stale ? "open Passthrough to update" : state.charging ? "" : "awake left").font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            if state.waitingSession != nil {
                Label(Summary.needsYou, systemImage: "questionmark.bubble")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(PTColor.attentionText)
            } else {
                Text(Summary.line(state)).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(16)
    }
}
