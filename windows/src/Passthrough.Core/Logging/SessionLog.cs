using Passthrough.Core.Session;
using Passthrough.Core.Transport;

namespace Passthrough.Core.Logging;

/// <summary>
/// Log lines for a first run: what changed between two session snapshots (watcher states, phones attached and
/// detached, each phone's state), and the startup line. Phones are named by id and kind only, never by what the phone
/// says about itself.
/// </summary>
public static class SessionLog
{
    public static IReadOnlyList<string> Changes(SessionState? before, SessionState after)
    {
        var lines = new List<string>();
        Watcher(lines, "usbmux", before?.UsbMux, after.UsbMux);
        Watcher(lines, "adb", before?.Adb, after.Adb);

        var old = (before?.Phones ?? []).ToDictionary(p => p.Device.Id);
        var now = after.Phones.Select(p => p.Device.Id).ToHashSet();
        foreach (var gone in old.Values.Where(p => !now.Contains(p.Device.Id))) lines.Add($"detached {Name(gone)}");
        foreach (var p in after.Phones)
        {
            old.TryGetValue(p.Device.Id, out var was);
            if (was is null) lines.Add($"attached {Name(p)}");
            if (was is not null && was.State == p.State && was.IsActive == p.IsActive && (p.State != PhoneState.Failed || was.Message == p.Message)) continue;
            var line = $"{Name(p)}: {p.State}" + (p.IsActive ? ", active" : "");
            if (p.State == PhoneState.Failed && !string.IsNullOrEmpty(p.Message)) line += ": " + p.Message;
            lines.Add(line);
        }
        return lines;
    }

    /// <summary>"Passthrough 1.2.3 starting on {os} ({architecture}), {runtime}".</summary>
    public static string Startup(string appVersion, string os, string architecture, string runtime) =>
        $"Passthrough {appVersion} starting on {os} ({architecture}), {runtime}";

    private static void Watcher(List<string> lines, string name, WatchStatus? before, WatchStatus after)
    {
        if (after == (before ?? new WatchStatus(WatchState.Idle))) return;
        lines.Add($"{name} watcher: {after.State}" + (string.IsNullOrEmpty(after.Hint) ? "" : $" ({after.Hint})"));
    }

    private static string Name(PhoneEntry p) => $"{p.Device.Id} ({p.Device.Kind.Label()})";
}
