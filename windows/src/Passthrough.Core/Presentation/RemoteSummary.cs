namespace Passthrough.Core.Presentation;

/// <summary>Where Remote access stands, as the flyout sees it (the tray's own state, without Windows types).</summary>
public enum RemoteMode
{
    /// <summary>Never set up on this PC: the flyout keeps the cable's header.</summary>
    NeedsSetup,
    Off,
    Starting,
    On,
    /// <summary>It can't run here; the problem says why.</summary>
    Unavailable,
}

public enum RemoteTone
{
    Idle,
    On,
    Attention,
}

/// <summary>A phone or computer with access, as the service lists it, and the shells it has open in this account.</summary>
/// <param name="Syncing">It is viewing the screen and its clipboard is synced with this account's.</param>
public sealed record RemoteDevice(string Id, string Name, bool IsComputer, int Connections, bool Viewing, int Shells, bool Syncing = false);

/// <summary>One device on this PC now: connected, with shells open, or viewing the screen.</summary>
public sealed record OnThisPc(string Id, string Name, bool IsComputer, int Shells, bool Viewing, bool Connected, bool Syncing = false)
{
    /// <summary>"Viewing the screen · syncing the clipboard · 2 shells open", "1 shell open", "Connected".</summary>
    public string Detail => string.Join(" · ", new[]
    {
        Viewing ? "Viewing the screen" : null,
        Viewing && Syncing ? "syncing the clipboard" : null,
        Shells switch { 0 => null, 1 => "1 shell open", var n => $"{n} shells open" },
        !Viewing && Shells == 0 ? "Connected" : null,
    }.OfType<string>());
}

/// <summary>The flyout's header from Remote access (not the cable), with what is on this PC now (stage 8 UX, option B).</summary>
public sealed record RemoteHeader(string Title, string Subtitle, RemoteTone Tone);

/// <summary>
/// What the flyout says about Remote access: the header above the tabs, who is on this PC now, the line that opens
/// Settings, and the Remote tab's title. Pure, so every state's words are tested.
/// </summary>
public static class RemoteSummary
{
    /// <summary>The devices on this PC now, viewers first, then by name.</summary>
    public static IReadOnlyList<OnThisPc> Here(IEnumerable<RemoteDevice> devices) =>
        [.. devices.Where(d => d.Connections > 0 || d.Shells > 0 || d.Viewing)
            .Select(d => new OnThisPc(d.Id, d.Name, d.IsComputer, d.Shells, d.Viewing, d.Connections > 0, d.Syncing))
            .OrderByDescending(d => d.Viewing).ThenBy(d => d.Name, StringComparer.CurrentCultureIgnoreCase)];

    /// <summary>The header; null while Remote access was never set up (the cable's header stays).</summary>
    public static RemoteHeader? Header(RemoteMode mode, string? problem, int phonesWithAccess, IReadOnlyList<OnThisPc> here)
    {
        switch (mode)
        {
            case RemoteMode.NeedsSetup: return null;
            case RemoteMode.Off: return new("Remote access is off", "Phones can't reach this PC", RemoteTone.Idle);
            case RemoteMode.Starting: return new("Remote access is starting…", "Phones can reach this PC in a moment", RemoteTone.Idle);
            case RemoteMode.Unavailable: return new("Remote access needs a look", problem ?? "Open Settings ▸ Remote access to see why", RemoteTone.Attention);
        }
        var viewers = here.Where(d => d.Viewing).ToList();
        // Who is viewing is the row under the notices (with Stop); the header says what that means here.
        if (viewers.Count > 0)
            return new("This PC's screen is in use", viewers.Count == 1 ? "Its own screen stays locked while it is" : $"By {viewers.Count} devices; its own screen stays locked", RemoteTone.On);
        var shells = here.Where(d => d.Shells > 0).ToList();
        if (shells.Count == 1)
            return new($"{shells[0].Name} has {Shells(shells[0].Shells)} open", "Stop ends them from the Remote tab", RemoteTone.On);
        if (shells.Count > 1)
            return new($"{Shells(shells.Sum(d => d.Shells))} open on this PC", $"From {shells.Count} devices", RemoteTone.On);
        if (here.Count == 1) return new($"{here[0].Name} is connected", "No shells open", RemoteTone.On);
        if (here.Count > 1) return new($"{here.Count} devices are connected", "No shells open", RemoteTone.On);
        return new("This PC is reachable", phonesWithAccess switch
        {
            0 => "Plug a paired phone in once to give it access",
            1 => "1 phone can reach it",
            var n => $"{n} phones can reach it",
        }, RemoteTone.On);
    }

    /// <summary>The header's one button, when there is something to do in Settings ▸ Remote access: turn it on, or fix it.</summary>
    public static string? HeaderAction(RemoteMode mode) => mode switch
    {
        RemoteMode.Off => "Turn on…",
        RemoteMode.Unavailable => "Fix…",
        _ => null,
    };

    /// <summary>The This PC tab's title: marked while a phone on the cable waits for its code or a retry.</summary>
    public static string ThisPcTabTitle(bool phoneWaits) => phoneWaits ? "This PC · Pair" : "This PC";

    /// <summary>The Remote tab's title: "Remote · 2" while two devices are on this PC.</summary>
    public static string TabTitle(IReadOnlyList<OnThisPc> here) => here.Count > 0 ? $"Remote · {here.Count}" : "Remote";

    /// <summary>The line that opens Settings ▸ Remote access: who can reach this PC.</summary>
    public static string ReachLine(RemoteMode mode, int phones, int computers) => mode switch
    {
        RemoteMode.NeedsSetup or RemoteMode.Off => "Turn on Remote access to reach this PC from your phones",
        _ when phones == 0 && computers == 0 => "No phone can reach this PC yet",
        _ => $"{Count(phones, "phone")}{(computers > 0 ? $" and {Count(computers, "computer")}" : "")} can reach this PC",
    };

    /// <summary>What Quit asks first, or null when quitting ends nothing a phone uses.</summary>
    public static string? QuitQuestion(bool enabled, int shells)
    {
        if (!enabled && shells == 0) return null;
        var ending = shells switch { 0 => "", 1 => "1 shell a phone opened ends. ", var n => $"{n} shells phones opened end. " };
        return enabled
            ? $"{ending}This PC's screen stays reachable from your phones until you turn Remote access off."
            : ending.TrimEnd();
    }

    private static string Shells(int n) => n == 1 ? "1 shell" : $"{n} shells";
    private static string Count(int n, string noun) => n == 1 ? $"1 {noun}" : $"{n} {noun}s";
}
