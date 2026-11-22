using Passthrough.Core.Screen;
using Passthrough.Core.Setup;
using Passthrough.Core.Tests.Setup;
using Xunit;

namespace Passthrough.Core.Tests.Screen;

public sealed class ScreenTests
{
    /// <summary>A client's X.224 connection request with an RDP negotiation request for <paramref name="protocols"/>.</summary>
    internal static byte[] Request(uint protocols) =>
        [0x03, 0x00, 0x00, 0x13, 0x0E, 0xE0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x08, 0x00, (byte)protocols, 0x00, 0x00, 0x00];

    internal static byte[] Confirm(uint selected) =>
        [0x03, 0x00, 0x00, 0x13, 0x0E, 0xD0, 0x00, 0x00, 0x12, 0x34, 0x00, 0x02, 0x00, 0x08, 0x00, (byte)selected, 0x00, 0x00, 0x00];

    [Theory]
    [InlineData(0x0Bu, true)]  // mstsc and FreeRDP: TLS, CredSSP, CredSSP-EX
    [InlineData(0x02u, true)]
    [InlineData(0x08u, true)]
    [InlineData(0x01u, false)] // TLS alone: Windows' logon screen, no NLA
    [InlineData(0x00u, false)] // standard RDP security
    public void ARequestMustOfferNla(uint protocols, bool ok) => Assert.Equal(ok, RdpNegotiation.OffersNla(Request(protocols)));

    [Theory]
    [InlineData(0x02u, true)]
    [InlineData(0x08u, true)]
    [InlineData(0x01u, false)] // Remote Desktop without NLA chose TLS: closed
    public void RemoteDesktopMustChooseNla(uint selected, bool ok) => Assert.Equal(ok, RdpNegotiation.ChoseNla(Confirm(selected)));

    [Fact]
    public void ARequestWithoutANegotiationIsRefused()
    {
        byte[] legacy = [0x03, 0x00, 0x00, 0x0B, 0x06, 0xE0, 0x00, 0x00, 0x00, 0x00, 0x00];
        Assert.False(RdpNegotiation.OffersNla(legacy));
    }

    [Fact]
    public async Task TheFirstPdusAreCheckedBothWays()
    {
        var phone = new MemoryStream(Request(0x0B));
        var desktop = new Duplex(Confirm(0x02));
        var phoneOut = new MemoryStream();
        Assert.True(await RdpNegotiation.EnforceAsync(new Duplex(Request(0x0B), phoneOut), desktop, CancellationToken.None));
        Assert.Equal(Request(0x0B), desktop.Written.ToArray());
        Assert.Equal(Confirm(0x02), phoneOut.ToArray());
        Assert.False(await RdpNegotiation.EnforceAsync(new Duplex(Request(0x0B)), new Duplex(Confirm(0x01)), CancellationToken.None));
        Assert.False(await RdpNegotiation.EnforceAsync(new Duplex(Request(0x01)), new Duplex(Confirm(0x02)), CancellationToken.None));
        GC.KeepAlive(phone);
    }

    private sealed class Duplex(byte[] read, MemoryStream? written = null) : Stream
    {
        private readonly MemoryStream _read = new(read);
        public MemoryStream Written { get; } = written ?? new MemoryStream();
        public override bool CanRead => true;
        public override bool CanWrite => true;
        public override bool CanSeek => false;
        public override long Length => 0;
        public override long Position { get => 0; set { } }
        public override void Flush() { }
        public override int Read(byte[] buffer, int offset, int count) => _read.Read(buffer, offset, count);
        public override long Seek(long offset, SeekOrigin origin) => 0;
        public override void SetLength(long value) { }
        public override void Write(byte[] buffer, int offset, int count) => Written.Write(buffer, offset, count);
    }

    private sealed class Clock : TimeProvider
    {
        public DateTimeOffset Now = new(2026, 11, 21, 12, 0, 0, TimeSpan.Zero);
        public override DateTimeOffset GetUtcNow() => Now;
    }

    [Fact]
    public void QuickOpensAreCappedAndASessionThatWorksIsFree()
    {
        var clock = new Clock();
        var limit = new RelayRateLimit(clock);
        var tickets = new List<RelayRateLimit.Ticket>();
        for (var i = 0; i < 4; i++)
        {
            var t = limit.TryReserve("A", "phone", out var wait);
            Assert.NotNull(t);
            Assert.Equal(0, wait);
            clock.Now += TimeSpan.FromSeconds(5);
            limit.Closed(t!);
            tickets.Add(t!);
        }
        Assert.Null(limit.TryReserve("A", "phone", out var retry));
        Assert.InRange(retry, 1, 600);
        Assert.NotNull(limit.TryReserve("A", "other-phone", out _)); // per grant
        clock.Now += TimeSpan.FromMinutes(10);
        var long1 = limit.TryReserve("A", "phone", out _)!;
        clock.Now += TimeSpan.FromMinutes(1); // lasted over 30 s: stops counting
        for (var i = 0; i < 3; i++) limit.Closed(limit.TryReserve("A", "phone", out _)!);
        Assert.NotNull(limit.TryReserve("A", "phone", out _));
        GC.KeepAlive(long1);
    }

    [Fact]
    public void ARefusedOpenDoesntCount()
    {
        var limit = new RelayRateLimit();
        for (var i = 0; i < 10; i++) limit.Cancel(limit.TryReserve("A", "phone", out _)!);
        Assert.NotNull(limit.TryReserve("A", "phone", out _));
    }

    [Theory]
    [InlineData(0, 4)]
    [InlineData(10, 4)]
    [InlineData(3, 2)]
    [InlineData(1, 1)]
    public void TheCapStaysBelowWindowsLockout(int threshold, int cap) => Assert.Equal(cap, new RelayRateLimit { LockoutThreshold = threshold }.CapFor);

    [Fact]
    public void TwoViewsAPhoneFourInAll()
    {
        var views = new ScreenViewLimit();
        Assert.True(views.TryTake("a") && views.TryTake("a"));
        Assert.False(views.TryTake("a"));
        Assert.True(views.TryTake("b") && views.TryTake("b"));
        Assert.False(views.TryTake("c"));
        views.Release("a");
        Assert.True(views.TryTake("c"));
    }

    private static readonly RemoteDesktopFacts Closed = new()
    {
        EditionMayHost = true, Denied = false, Port = 3389, NlaRequired = true, ServiceRunning = true, FirewallOnEveryProfile = true,
        BlockRulesIntact = true, AllowRuleForPort = false, OverridingAllowRule = false, FirewallManagedElsewhere = false, LocalRulesIgnored = false,
    };

    private static readonly RemoteDesktopSetup Setup = new() { Mode = RemoteDesktopSetup.Closed, ConsentedBy = ["S-1-5-21-1"] };

    [Fact]
    public void TheVerdictTakesTheFirstThatHolds()
    {
        Assert.Equal("ready", RemoteDesktopVerdict.From(Closed, Setup, "S-1-5-21-1").Rdp);
        Assert.Equal("edition", RemoteDesktopVerdict.From(Closed with { EditionMayHost = false }, Setup).Rdp);
        Assert.Equal("policy", RemoteDesktopVerdict.From(Closed with { PolicyDenies = true }, Setup).Rdp);
        Assert.Equal("off", RemoteDesktopVerdict.From(Closed, null).Rdp);
        Assert.Equal("off", RemoteDesktopVerdict.From(Closed, Setup, "S-1-5-21-2").Rdp); // that account didn't consent
        Assert.Equal("off", RemoteDesktopVerdict.From(Closed with { Denied = true }, Setup).Rdp);
        Assert.Equal("exposed", RemoteDesktopVerdict.From(Closed with { FirewallOnEveryProfile = false }, Setup).Rdp);
        Assert.Equal("service", RemoteDesktopVerdict.From(Closed with { ServiceRunning = false }, Setup).Rdp);
        // NLA off is service, not exposed (RECONCILIATION), in every mode.
        Assert.Equal("service", RemoteDesktopVerdict.From(Closed with { NlaRequired = false, BlockRulesIntact = true }, Setup with { Mode = RemoteDesktopSetup.Owner }).Rdp);
        Assert.Equal("account", RemoteDesktopVerdict.From(Closed, Setup, "S-1-5-21-1", workAccount: true).Rdp);
    }

    [Fact]
    public void TheOwnersOpenRemoteDesktopIsNeverExposed()
    {
        var open = Closed with { FirewallOnEveryProfile = false, BlockRulesIntact = false, AllowRuleForPort = true };
        Assert.Equal("ready", RemoteDesktopVerdict.From(open, Setup with { Mode = RemoteDesktopSetup.Owner }).Rdp);
        Assert.True(ExposureCheck.Evaluate(open, RemoteDesktopSetup.Closed).IsOpen);
        Assert.True(ExposureCheck.Evaluate(Closed with { ReadFailed = true }, RemoteDesktopSetup.Closed).IsOpen); // unknown counts as open
    }

    [Fact]
    public void TheModeIsChosenFromWhatIsThere()
    {
        Assert.Equal(RemoteDesktopSetup.Closed, ExposureCheck.ModeFor(Closed with { Denied = true }));
        Assert.Equal(RemoteDesktopSetup.Closed, ExposureCheck.ModeFor(Closed)); // on, but nothing lets the network in
        Assert.Equal(RemoteDesktopSetup.Owner, ExposureCheck.ModeFor(Closed with { AllowRuleForPort = true }));  // the owner's PC
        Assert.Equal(RemoteDesktopSetup.Policy, ExposureCheck.ModeFor(Closed with { PolicyDenies = false }));
        Assert.Null(ExposureCheck.ModeFor(Closed with { Denied = true, FirewallOnEveryProfile = false }));     // can't keep it closed
        Assert.Null(ExposureCheck.ModeFor(Closed with { PolicyDenies = true }));
    }

    /// <summary>A PC's Remote Desktop, in memory.</summary>
    private sealed class FakeRdp(RemoteDesktopFacts facts) : IRemoteDesktopSystem
    {
        public RemoteDesktopFacts State = facts;
        public int Start = 3;
        public readonly HashSet<string> Users = [];
        public readonly List<string> Calls = [];
        public bool OffFails;
        public RemoteDesktopFacts Facts() => State;
        public void SetAllowed(bool on)
        {
            Calls.Add(on ? "on" : "off");
            if (!on && OffFails) throw new SetupException("couldn't");
            State = State with { Denied = !on };
        }
        public void SetNla(bool required, int? prior = null) { Calls.Add("nla"); State = State with { NlaRequired = required || prior == 1 }; }
        public int StartType() => Start;
        public void SetStartType(int start) => Start = start;
        public void StartService() { Calls.Add("start"); State = State with { ServiceRunning = true }; }
        public bool MayUseRemoteDesktop(string sid) => Users.Contains(sid);
        public void AddToRemoteDesktopUsers(string sid) { Calls.Add("add-user"); Users.Add(sid); }
        public void RemoveFromRemoteDesktopUsers(string sid) { Calls.Add("remove-user"); Users.Remove(sid); }
    }

    private static (FakePc Pc, SetupResult Result) SetUp(FakeRdp rdp, FakePc? pc = null)
    {
        if (pc is null)
        {
            pc = new FakePc();
            pc.AddBuild();
            SetupEngine.Run(SetupPlans.InstallOrUpdate(false), new SetupContext { System = pc.System(), Source = FakePc.Source, AskingAccount = "S-1-5-21-1" }, _ => { });
        }
        var result = SetupEngine.Run(RemoteDesktopSetupPlans.SetUp(rdp), new SetupContext { System = pc.System(), Source = FakePc.Source, AskingAccount = "S-1-5-21-1" }, _ => { });
        return (pc, result);
    }

    private static readonly RemoteDesktopFacts Off = Closed with { Denied = true, NlaRequired = false, ServiceRunning = false, BlockRulesIntact = false };

    [Fact]
    public void OnAPcWithRemoteDesktopOffTheBlockComesBeforeTheDoorOpens()
    {
        var rdp = new FakeRdp(Off);
        var (pc, result) = SetUp(rdp);
        Assert.Equal(SetupResult.Ok, result.Result);
        Assert.Equal(2, pc.Rules.Count(r => r.Block && r.Group == ServiceDefinition.RemoteDesktopFirewallGroup));
        Assert.True(pc.Calls.IndexOf("add-rule") < pc.Calls.Count); // rules made
        Assert.Equal(["nla", "add-user", "start", "on"], rdp.Calls);
        var state = InstallState.Decode(pc.FileBytes[pc.System().Machine.StateFile])!.Rdp!;
        Assert.Equal((RemoteDesktopSetup.Closed, true, true), (state.Mode, state.WeTurnedOn, state.WeSetNla));
        Assert.Equal(["S-1-5-21-1"], state.ConsentedBy);
        Assert.Equal(["S-1-5-21-1"], state.AddedToRemoteDesktopUsers);
    }

    [Fact]
    public void AnUpdateKeepsTheBlockRules()
    {
        var (pc, _) = SetUp(new FakeRdp(Off));
        pc.AddBuild("0.9.1+def");
        Assert.Equal(SetupResult.Ok, SetupEngine.Run(SetupPlans.InstallOrUpdate(true), new SetupContext { System = pc.System(), Source = FakePc.Source, AskingAccount = "S-1-5-21-1" }, _ => { }).Result);
        Assert.Equal(2, pc.Rules.Count(r => r.Block));
        Assert.NotNull(InstallState.Decode(pc.FileBytes[pc.System().Machine.StateFile])!.Rdp);
    }

    [Fact]
    public void TheOwnersOpenRemoteDesktopIsLeftAsItIs()
    {
        var rdp = new FakeRdp(Closed with { AllowRuleForPort = true, NlaRequired = true });
        var (pc, result) = SetUp(rdp);
        Assert.Equal(SetupResult.Ok, result.Result);
        Assert.DoesNotContain(pc.Rules, r => r.Block);
        Assert.Equal(["add-user"], rdp.Calls);
        Assert.Equal(RemoteDesktopSetup.Owner, InstallState.Decode(pc.FileBytes[pc.System().Machine.StateFile])!.Rdp!.Mode);
    }

    [Fact]
    public void RemovingPutsRemoteDesktopBackAndOnlyWhatPassthroughChanged()
    {
        var rdp = new FakeRdp(Off);
        var (pc, _) = SetUp(rdp);
        rdp.Calls.Clear();
        var result = SetupEngine.Run(SetupPlans.RemoveAll(rdp), new SetupContext { System = pc.System(), Source = FakePc.Source }, _ => { }, continuePastFailure: true);
        Assert.Equal(SetupResult.Ok, result.Result);
        // Off first: NLA goes back only once nothing can reach Remote Desktop without it.
        Assert.Equal(["remove-user", "off", "nla"], rdp.Calls);
        Assert.True(rdp.State.Denied);
        Assert.Empty(pc.Rules);
    }

    [Fact]
    public void RemovingLeavesNlaRequiredWhenRemoteDesktopStaysOn()
    {
        var rdp = new FakeRdp(Off);
        var (pc, _) = SetUp(rdp);
        // The owner opened Remote Desktop to the network since: it stays on, so it keeps requiring NLA.
        rdp.State = rdp.State with { AllowRuleForPort = true };
        rdp.Calls.Clear();
        SetupEngine.Run(SetupPlans.RemoveAll(rdp), new SetupContext { System = pc.System(), Source = FakePc.Source }, _ => { }, continuePastFailure: true);
        Assert.DoesNotContain("nla", rdp.Calls);
        Assert.False(rdp.State.Denied);
    }

    [Fact]
    public void IfRemoteDesktopCantBeTurnedOffTheBlockRulesStay()
    {
        var rdp = new FakeRdp(Off);
        var (pc, _) = SetUp(rdp);
        rdp.OffFails = true;
        var result = SetupEngine.Run(SetupPlans.RemoveAll(rdp), new SetupContext { System = pc.System(), Source = FakePc.Source }, _ => { }, continuePastFailure: true);
        Assert.Equal("rdp-restore", result.FailedStep);
        Assert.Equal(2, pc.Rules.Count(r => r.Block));
    }

    [Fact]
    public void RemoteDesktopTheOwnerNowUsesIsLeftOn()
    {
        var rdp = new FakeRdp(Off);
        var (pc, _) = SetUp(rdp);
        rdp.State = rdp.State with { AllowRuleForPort = true }; // the owner turned Windows' rules on since
        SetupEngine.Run(SetupPlans.RemoveAll(rdp), new SetupContext { System = pc.System(), Source = FakePc.Source }, _ => { }, continuePastFailure: true);
        Assert.False(rdp.State.Denied);
    }
}
