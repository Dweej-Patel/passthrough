namespace Passthrough.Core.Transport;

/// <summary>A watcher's state, plus something the user must do (e.g. allow USB debugging) when there is one.</summary>
public sealed record WatchStatus(WatchState State, string? Hint = null);
