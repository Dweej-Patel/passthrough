namespace Passthrough.Core.Screen;

/// <summary>
/// What this PC's Remote Desktop is, as read (stage 5 plan, section 1): plain values the Windows probe fills, so every
/// verdict is a test on any OS. Null means it couldn't be read.
/// </summary>
public sealed record RemoteDesktopFacts
{
    /// <summary>The edition may host Remote Desktop (Pro and up; Home can't).</summary>
    public bool? EditionMayHost { get; init; }
    /// <summary>The Terminal Services policy's <c>fDenyTSConnections</c>: true (off by policy), false (on by policy), null (no policy value).</summary>
    public bool? PolicyDenies { get; init; }
    /// <summary><c>fDenyTSConnections</c> in the Terminal Server key: true when Remote Desktop is off.</summary>
    public bool Denied { get; init; } = true;
    public int Port { get; init; } = 3389;
    /// <summary>Network Level Authentication required (policy over the setting).</summary>
    public bool? NlaRequired { get; init; }
    public bool ServiceRunning { get; init; }
    public bool ServiceDisabled { get; init; }
    /// <summary>Windows Firewall on for each of the domain, private and public profiles.</summary>
    public bool? FirewallOnEveryProfile { get; init; }
    /// <summary>Passthrough's two block rules are there, enabled, inbound, block, every profile, no program or address limit, on <see cref="Port"/>.</summary>
    public bool? BlockRulesIntact { get; init; }
    /// <summary>An enabled inbound allow rule for the port (Windows' own Remote Desktop rules, or any other).</summary>
    public bool? AllowRuleForPort { get; init; }
    /// <summary>An allow rule for the port that may override block rules (its secure flags).</summary>
    public bool? OverridingAllowRule { get; init; }
    /// <summary>A third-party firewall registered with Windows, or Windows Firewall not in charge of its own policy.</summary>
    public bool? FirewallManagedElsewhere { get; init; }
    /// <summary>A profile whose policy ignores local rules (<c>AllowLocalPolicyMerge = 0</c>).</summary>
    public bool? LocalRulesIgnored { get; init; }
    /// <summary>Any read failed: the check can't promise anything.</summary>
    public bool ReadFailed { get; init; }
    /// <summary>The first read that failed and how, for the service's log.</summary>
    public string? FailedRead { get; init; }
}

/// <summary>What the elevated step found and did, from install.json's <c>rdp</c> (null: Screen isn't set up).</summary>
public sealed record RemoteDesktopSetup
{
    public const string Closed = "closed", Owner = "owner", Policy = "policy";

    /// <summary><c>closed</c>: Passthrough keeps it blocked from the network; <c>owner</c>: it was open by the owner's choice and is left so; <c>policy</c>: a policy turns it on.</summary>
    public string Mode { get; init; } = Closed;
    public long SetUpAt { get; init; }
    /// <summary>The accounts that agreed (behind an administrator prompt) that their phones may reach the screen.</summary>
    public List<string> ConsentedBy { get; init; } = [];
    public RemoteDesktopPrior Prior { get; init; } = new();
    public bool WeTurnedOn { get; init; }
    public bool WeSetNla { get; init; }
    public bool WeChangedStart { get; init; }
    public List<string> AddedToRemoteDesktopUsers { get; init; } = [];
    public int BlockedPort { get; init; }
    /// <summary>The owner saw the note that their Remote Desktop is open to the network (mode owner), and answered it.</summary>
    public bool OwnerNoteAnswered { get; init; }
}

public sealed record RemoteDesktopPrior
{
    public int? FDenyTSConnections { get; init; }
    public int? UserAuthentication { get; init; }
    public int? TermServiceStart { get; init; }
}
