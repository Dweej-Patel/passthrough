using Passthrough.Core.Screen;

namespace Passthrough.Core.Setup;

/// <summary>What the elevated step may do to this PC's Remote Desktop (stage 5 plan, section 2).</summary>
public interface IRemoteDesktopSystem
{
    RemoteDesktopFacts Facts();

    /// <summary>Turns Remote Desktop on or off, leaving Windows' own firewall rules alone.</summary>
    void SetAllowed(bool on);

    /// <summary>Requires Network Level Authentication, or puts back <paramref name="prior"/> (the earlier value; null: none set).</summary>
    void SetNla(bool required, int? prior = null);

    /// <summary>TermService's start type now (2 automatic, 3 manual, 4 disabled), and changing it.</summary>
    int StartType();
    void SetStartType(int start);
    void StartService();

    /// <summary>The account is in Administrators or Remote Desktop Users (by SID, never by name).</summary>
    bool MayUseRemoteDesktop(string sid);
    void AddToRemoteDesktopUsers(string sid);
    void RemoveFromRemoteDesktopUsers(string sid);
}

/// <summary>
/// Screen's elevated steps (stage 5 plan, section 2, with its review): the mode is chosen once from what is found
/// before anything changes, and everything changed is written down so removal puts back exactly that.
/// <list type="bullet">
/// <item><c>closed</c> (Remote Desktop off, or on with nothing letting the network in): block rules first (in a firewall
/// group of their own, which no update touches), then NLA, the account, the service, and only then Remote Desktop on.</item>
/// <item><c>owner</c> (on and open by the owner's choice) and <c>policy</c>: nothing about Remote Desktop or the firewall
/// changes; only the consenting account may be added to Remote Desktop Users.</item>
/// </list>
/// </summary>
public static class RemoteDesktopSetupPlans
{
    /// <summary><c>--install --screen</c> and <c>--configure screen</c>: Screen set up, and the asking account's consent.</summary>
    public static IReadOnlyList<ISetupStep> SetUp(IRemoteDesktopSystem rdp) =>
    [
        new SetupStep("rdp-check", c =>
        {
            c.Before ??= SetupPlans.ReadState(c) ?? throw new SetupException("Remote access isn't set up on this PC.");
            c.State ??= c.Before;
            if (c.AskingAccount is null) throw new SetupException("Couldn't tell which account asked.");
            var facts = rdp.Facts();
            if (facts.EditionMayHost == false) throw new SetupException("Windows Home has no Remote Desktop. The shell works; the screen needs Windows Pro.");
            if (facts.PolicyDenies == true) throw new SetupException("Remote Desktop is turned off by a policy on this PC. Passthrough can't change that.");
            var mode = c.State.Rdp?.Mode ?? ExposureCheck.ModeFor(facts)
                ?? throw new SetupException("Passthrough can't keep Remote Desktop closed to the network here: Windows Firewall isn't on for every network, or another program manages it. Open Windows Security and turn the firewall on, then try again.");
            var setup = c.State.Rdp ?? new RemoteDesktopSetup
            {
                Mode = mode,
                SetUpAt = c.System.Time.GetUtcNow().ToUnixTimeSeconds(),
                Prior = new RemoteDesktopPrior { FDenyTSConnections = facts.Denied ? 1 : 0, UserAuthentication = facts.NlaRequired is { } n ? (n ? 1 : 0) : null, TermServiceStart = rdp.StartType(), AllowRuleBefore = facts.AllowRuleForPort },
                BlockedPort = facts.Port,
            };
            if (!setup.ConsentedBy.Contains(c.AskingAccount, StringComparer.OrdinalIgnoreCase)) setup = setup with { ConsentedBy = [.. setup.ConsentedBy, c.AskingAccount] };
            c.State = c.State with { Rdp = setup };
            return StepState.Skipped;
        }),
        // The port is blocked before it can open.
        new SetupStep("rdp-block", c =>
        {
            if (c.State!.Rdp!.Mode != RemoteDesktopSetup.Closed) return StepState.Skipped;
            var port = rdp.Facts().Port;
            var existing = c.System.Firewall.InGroup(ServiceDefinition.RemoteDesktopFirewallGroup);
            var wanted = ServiceDefinition.BlockRules(port);
            if (wanted.All(w => existing.Any(e => e with { Enabled = true } == w))) return StepState.Skipped;
            foreach (var name in existing.Select(r => r.Name).Distinct()) c.System.Firewall.Remove(name, ServiceDefinition.RemoteDesktopFirewallGroup);
            foreach (var rule in wanted) c.System.Firewall.Add(rule);
            c.State = c.State with { Rdp = c.State.Rdp with { BlockedPort = port } };
            return StepState.Done;
        }, c =>
        {
            if (c.Before?.Rdp is not null) return; // were there before this run: left
            foreach (var name in new[] { ServiceDefinition.BlockTcpRuleName, ServiceDefinition.BlockUdpRuleName }) c.System.Firewall.Remove(name, ServiceDefinition.RemoteDesktopFirewallGroup);
        }),
        new SetupStep("rdp-nla", c =>
        {
            if (c.State!.Rdp!.Mode != RemoteDesktopSetup.Closed || rdp.Facts().NlaRequired == true) return StepState.Skipped;
            rdp.SetNla(true);
            c.State = c.State with { Rdp = c.State.Rdp with { WeSetNla = true } };
            return StepState.Done;
        }, c => rdp.SetNla(false, c.State!.Rdp!.Prior.UserAuthentication)),
        new SetupStep("rdp-users", c =>
        {
            var sid = c.AskingAccount!;
            c.AddedUser = false;
            if (rdp.MayUseRemoteDesktop(sid)) return StepState.Skipped;
            rdp.AddToRemoteDesktopUsers(sid);
            c.AddedUser = true;
            c.State = c.State! with { Rdp = c.State.Rdp! with { AddedToRemoteDesktopUsers = [.. c.State.Rdp.AddedToRemoteDesktopUsers, sid] } };
            return StepState.Done;
        }, c => { if (c.AddedUser) rdp.RemoveFromRemoteDesktopUsers(c.AskingAccount!); }),
        new SetupStep("rdp-service", c =>
        {
            if (c.State!.Rdp!.Mode != RemoteDesktopSetup.Closed) return StepState.Skipped;
            if (rdp.StartType() == 4)
            {
                rdp.SetStartType(3);
                c.State = c.State with { Rdp = c.State.Rdp with { WeChangedStart = true } };
            }
            rdp.StartService();
            return StepState.Done;
        }, c => { if (c.State!.Rdp!.WeChangedStart) rdp.SetStartType(c.State.Rdp.Prior.TermServiceStart ?? 4); }),
        new SetupStep("rdp-on", c =>
        {
            if (c.State!.Rdp!.Mode != RemoteDesktopSetup.Closed || !rdp.Facts().Denied) return StepState.Skipped;
            rdp.SetAllowed(true);
            c.State = c.State with { Rdp = c.State.Rdp with { WeTurnedOn = true } };
            return StepState.Done;
        }, _ => rdp.SetAllowed(false)),
        new SetupStep("rdp-state", c =>
        {
            c.System.Files.Write(c.Machine.StateFile, c.State!.Encode());
            return StepState.Done;
        }, c => { if (c.Before is { } before) c.System.Files.Write(c.Machine.StateFile, before.Encode()); }),
        new SetupStep("reload", c => c.System.Service.SendControl(ServiceDefinition.ControlReload) ? StepState.Done : StepState.Skipped),
    ];

    /// <summary>
    /// Part of <c>--remove</c>, before the firewall and the data folder go: Remote Desktop as it was. It is turned off
    /// only when Passthrough turned it on and nothing lets the network in now (the owner may have chosen to use it since);
    /// and turned off before the block rules go, so a half-done removal never leaves the port open. If turning it off
    /// fails, the block rules stay.
    /// </summary>
    public static ISetupStep Restore(IRemoteDesktopSystem rdp) => new SetupStep("rdp-restore", c =>
    {
        var state = SetupPlans.ReadState(c);
        if (state?.Rdp is not { } setup) return RemoveBlockRules(c) ? StepState.Done : StepState.Skipped;
        var facts = rdp.Facts();
        foreach (var sid in setup.AddedToRemoteDesktopUsers) rdp.RemoveFromRemoteDesktopUsers(sid);
        // The owner chose to use it since only if a rule letting the network in is on now and wasn't at setup; a rule that
        // was there all along (blocked by ours until now) would open the port the moment our block rules go.
        var ownerOpenedIt = facts.AllowRuleForPort == true && setup.Prior.AllowRuleBefore != true;
        if (setup.WeTurnedOn && !ownerOpenedIt) rdp.SetAllowed(false); // throws: NLA and the block rules stay
        // NLA goes back only when Remote Desktop ends up off: one left on (the owner uses it) keeps requiring it.
        if (setup.WeSetNla && rdp.Facts().Denied) rdp.SetNla(false, setup.Prior.UserAuthentication);
        if (setup.WeChangedStart) rdp.SetStartType(setup.Prior.TermServiceStart ?? 4);
        RemoveBlockRules(c);
        return StepState.Done;
    });

    private static bool RemoveBlockRules(SetupContext c)
    {
        var rules = c.System.Firewall.InGroup(ServiceDefinition.RemoteDesktopFirewallGroup);
        foreach (var name in rules.Select(r => r.Name).Distinct()) c.System.Firewall.Remove(name, ServiceDefinition.RemoteDesktopFirewallGroup);
        return rules.Count > 0;
    }

    /// <summary><c>--configure screen-close</c> (owner mode: close it to the network) and <c>screen-open</c> (closed: let other Remote Desktop apps in again).</summary>
    public static IReadOnlyList<ISetupStep> ChangeMode(IRemoteDesktopSystem rdp, bool close) =>
    [
        new SetupStep("rdp-check", c =>
        {
            c.Before = SetupPlans.ReadState(c) ?? throw new SetupException("Remote access isn't set up on this PC.");
            if (c.Before.Rdp is not { } setup || setup.Mode == RemoteDesktopSetup.Policy) throw new SetupException("Screen isn't set up the way that needs.");
            c.State = c.Before with { Rdp = setup with { Mode = close ? RemoteDesktopSetup.Closed : RemoteDesktopSetup.Owner, OwnerNoteAnswered = true } };
            if (close && ExposureCheck.ModeFor(rdp.Facts() with { Denied = true }) != RemoteDesktopSetup.Closed)
                throw new SetupException("Passthrough can't keep Remote Desktop closed to the network here: Windows Firewall isn't on for every network, or another program manages it.");
            return StepState.Skipped;
        }),
        new SetupStep("rdp-rules", c =>
        {
            if (close)
            {
                foreach (var rule in ServiceDefinition.BlockRules(rdp.Facts().Port)) c.System.Firewall.Add(rule);
                if (rdp.Facts().NlaRequired != true)
                {
                    rdp.SetNla(true);
                    c.State = c.State! with { Rdp = c.State.Rdp! with { WeSetNla = true } };
                }
            }
            else
            {
                // Open to the network again, it keeps requiring NLA (removal puts the old value back once it is off).
                RemoveBlockRules(c);
            }
            return StepState.Done;
        }),
        new SetupStep("rdp-state", c =>
        {
            c.System.Files.Write(c.Machine.StateFile, c.State!.Encode());
            return StepState.Done;
        }, c => c.System.Files.Write(c.Machine.StateFile, c.Before!.Encode())),
        new SetupStep("reload", c => c.System.Service.SendControl(ServiceDefinition.ControlReload) ? StepState.Done : StepState.Skipped),
    ];
}
