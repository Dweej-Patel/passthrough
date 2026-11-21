namespace Passthrough.Core.Screen;

/// <summary>Whether Remote Desktop can be relayed to now, and the row Settings shows (stage 5 plan, sections 1 and 3).</summary>
public sealed record RemoteDesktopVerdict(string Rdp, string RowState, string Text, string? Action = null, string? Reason = null)
{
    public const string Ready = "ready", Off = "off", Edition = "edition", Account = "account", Service = "service", Exposed = "exposed", PolicyOff = "policy";
    public const string Done = "done", Needed = "needed", Problem = "problem";

    public bool IsReady => Rdp == Ready;

    /// <summary>
    /// The first condition that holds wins. <paramref name="setup"/> is install.json's <c>rdp</c>; <paramref name="account"/>
    /// the account that granted the phone (null: the PC's row, for no phone in particular); <paramref name="workAccount"/>
    /// whether that account is a work (Entra-only) account.
    /// </summary>
    public static RemoteDesktopVerdict From(RemoteDesktopFacts facts, RemoteDesktopSetup? setup, string? account = null, bool workAccount = false)
    {
        if (facts.EditionMayHost == false)
            return new(Edition, Problem, "Windows Home has no Remote Desktop. The shell works; the screen needs Windows Pro.");
        if (facts.PolicyDenies == true)
            return new(PolicyOff, Problem, "Remote Desktop is turned off by a policy on this PC. Passthrough can't change that; the shell still works.");
        if (setup is null || (account is not null && !setup.ConsentedBy.Contains(account, StringComparer.OrdinalIgnoreCase)))
            return new(Off, Needed, "Not set up.", "Set up…");
        if (facts.Denied && facts.PolicyDenies != false)
            return new(Off, Problem, "Remote Desktop was turned off in Windows Settings.", "Turn on");
        if (setup.Mode == RemoteDesktopSetup.Closed && ExposureCheck.Evaluate(facts, setup.Mode) is { IsOpen: true } open)
            return new(Exposed, Problem, "Remote Desktop is open to the network. Passthrough won't relay to it until that is closed.", "Close it", open.Reason);
        if (!facts.ServiceRunning || facts.ServiceDisabled)
            return new(Service, Problem, "Remote Desktop isn't answering on this PC.", "Try again");
        // Without NLA a stranger reaches Windows' sign-in screen before proving anything: never relayed (RECONCILIATION).
        if (facts.NlaRequired != true)
            return new(Service, Problem, "Remote Desktop doesn't require Network Level Authentication, so Passthrough won't relay to it.", "Require it");
        if (workAccount)
            return new(Account, Problem, "Work accounts aren't supported yet.");
        return setup.Mode switch
        {
            RemoteDesktopSetup.Owner => new(Ready, Done, "Remote Desktop is on. It was open to your network before Passthrough and still is.", "Close it to the network"),
            RemoteDesktopSetup.Policy => new(Ready, Done, "Remote Desktop is turned on by a policy on this PC. Passthrough uses it as it is."),
            _ => new(Ready, Done, "Remote Desktop is on, for Passthrough only."),
        };
    }
}

/// <summary>
/// Whether Remote Desktop is open to the network (stage 5 plan, section 3). Only in mode <c>closed</c>, where
/// Passthrough promised it isn't: in the owner's or the policy's mode it is their choice and never "exposed".
/// Anything that can't be read counts as open.
/// </summary>
public sealed record ExposureCheck(bool IsOpen, bool OwnersChoice, string? Reason)
{
    public static readonly ExposureCheck Closed = new(false, false, null);

    public static ExposureCheck Evaluate(RemoteDesktopFacts facts, string mode)
    {
        if (mode != RemoteDesktopSetup.Closed) return new(false, true, null);
        string? reason =
            facts.ReadFailed ? "Passthrough couldn't read the firewall." :
            facts.FirewallOnEveryProfile != true ? "Windows Firewall is off for a network profile." :
            facts.FirewallManagedElsewhere != false ? "Another program manages this PC's firewall." :
            facts.LocalRulesIgnored != false ? "A policy makes Windows Firewall ignore Passthrough's rules." :
            facts.BlockRulesIntact != true ? "Passthrough's rules that keep Remote Desktop closed were changed or removed." :
            facts.OverridingAllowRule != false ? "A firewall rule lets Remote Desktop in past Passthrough's block." :
            facts.NlaRequired != true ? "Remote Desktop no longer requires Network Level Authentication." :
            null;
        return reason is null ? Closed : new(true, false, reason);
    }

    /// <summary>
    /// The mode the elevated step chooses from what it finds before changing anything: off (or on with nothing
    /// letting the network in, and Windows Firewall in charge) is <c>closed</c>; on and open is the owner's; on by
    /// policy is the policy's. Null: off by policy, or it can't keep it closed (the firewall isn't in charge).
    /// </summary>
    public static string? ModeFor(RemoteDesktopFacts facts)
    {
        if (facts.PolicyDenies == true) return null;
        if (facts.PolicyDenies == false) return RemoteDesktopSetup.Policy;
        var firewallInCharge = facts.FirewallOnEveryProfile == true && facts.FirewallManagedElsewhere == false && facts.LocalRulesIgnored == false;
        if (!facts.Denied && (facts.AllowRuleForPort != false || !firewallInCharge)) return RemoteDesktopSetup.Owner;
        return firewallInCharge ? RemoteDesktopSetup.Closed : null;
    }
}
