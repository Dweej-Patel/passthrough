namespace Passthrough.Core.Transport;

/// <summary>
/// Finds phones over one transport and reports the usable ones, restarting itself after failures until stopped.
/// Events may fire from background threads.
/// </summary>
public interface IDeviceWatcher
{
    WatchTransport Transport { get; }

    WatchStatus Status { get; }

    /// <summary>Every usable phone this watcher sees, oldest first. Fires on a background thread.</summary>
    event Action<IReadOnlyList<PhoneDevice>>? DevicesChanged;

    /// <summary>Fires on a background thread, only when the status actually changed.</summary>
    event Action<WatchStatus>? StatusChanged;

    /// <summary>Begins watching in the background. Does nothing when already started.</summary>
    void Start();

    /// <summary>Stops watching, then reports an empty device list and an idle status.</summary>
    Task StopAsync();
}
