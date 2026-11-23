using Passthrough.Core.Shell;
using Xunit;

namespace Passthrough.Core.Tests.Shell;

public sealed class GoingAwayTests
{
    [Theory]
    [InlineData(GoingAway.Signal.Suspend, true, false, "sleeping")]
    [InlineData(GoingAway.Signal.PreShutdown, true, false, "shutting_down")]
    [InlineData(GoingAway.Signal.Stop, false, false, "turned_off")]   // --off and --remove set Enabled=0 first
    [InlineData(GoingAway.Signal.Stop, true, true, null)]             // an update: the phone just reconnects
    [InlineData(GoingAway.Signal.Stop, false, true, null)]
    [InlineData(GoingAway.Signal.Stop, true, false, null)]            // any other stop
    public void EachSignalHasItsReason(GoingAway.Signal signal, bool enabled, bool updating, string? reason) =>
        Assert.Equal(reason, GoingAway.For(signal, enabled, updating)?.Reason);

    [Fact]
    public void SleepGetsLessThanWindowsGives() => Assert.True(GoingAway.For(GoingAway.Signal.Suspend, true, false)!.Value.Limit < TimeSpan.FromSeconds(2));

    [Theory]
    [InlineData(1800, true, false, 1800)]
    [InlineData(1800, true, true, 0)]   // held awake on mains
    [InlineData(600, false, true, 600)] // on battery Stay awake doesn't hold
    [InlineData(0, true, false, 0)]
    public void SleepAfterFollowsThePowerSource(int plan, bool mains, bool awake, int expected) =>
        Assert.Equal(expected, GoingAway.SleepAfter(plan, mains, awake));
}
