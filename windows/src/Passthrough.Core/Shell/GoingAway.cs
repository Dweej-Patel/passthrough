namespace Passthrough.Core.Shell;

/// <summary>What the service tells phones as it goes, for each thing Windows says (stage 4 plan, section 9).</summary>
public static class GoingAway
{
    public const string Sleeping = "sleeping", TurnedOff = "turned_off", ShuttingDown = "shutting_down";

    public enum Signal { Suspend, PreShutdown, Stop }

    /// <summary>
    /// The reason and how long to give the lines, or null for none: an update or a plain stop says nothing, so the
    /// phone just reconnects. Suspend: Windows gives about 2 s.
    /// </summary>
    public static (string Reason, TimeSpan Limit)? For(Signal signal, bool enabled, bool updating) => signal switch
    {
        Signal.Suspend => (Sleeping, TimeSpan.FromSeconds(1.5)),
        Signal.PreShutdown => (ShuttingDown, TimeSpan.FromSeconds(2)),
        Signal.Stop when updating => null,
        Signal.Stop when !enabled => (TurnedOff, TimeSpan.FromSeconds(2)),
        _ => null,
    };

    /// <summary>
    /// What <c>host.sleepAfter</c> says (seconds on the current power source; 0 never, or held awake): the plan's sleep
    /// timer, unless Stay awake holds it on mains.
    /// </summary>
    public static int SleepAfter(int planSeconds, bool onMains, bool stayAwake) => onMains && stayAwake ? 0 : Math.Max(0, planSeconds);
}
