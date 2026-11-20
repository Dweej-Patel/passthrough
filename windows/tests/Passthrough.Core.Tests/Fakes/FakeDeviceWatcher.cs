using Passthrough.Core.Transport;

namespace Passthrough.Core.Tests.Fakes;

/// <summary>An in-memory watcher: the test reports its phones and status by hand.</summary>
public sealed class FakeDeviceWatcher(WatchTransport transport) : IDeviceWatcher
{
    private PhoneDevice[] _devices = [];
    private int _starts;
    private int _stops;

    public WatchTransport Transport { get; } = transport;

    public WatchStatus Status { get; private set; } = new(WatchState.Idle);

    public event Action<IReadOnlyList<PhoneDevice>>? DevicesChanged;

    public event Action<WatchStatus>? StatusChanged;

    public event Action<Exception>? Error;

    public int Starts => Volatile.Read(ref _starts);

    public int Stops => Volatile.Read(ref _stops);

    public void Start() => Interlocked.Increment(ref _starts);

    public Task StopAsync()
    {
        Interlocked.Increment(ref _stops);
        Report();
        SetStatus(new WatchStatus(WatchState.Idle));
        return Task.CompletedTask;
    }

    /// <summary>Replaces the whole list of phones this watcher sees.</summary>
    public void Report(params PhoneDevice[] devices)
    {
        _devices = devices;
        DevicesChanged?.Invoke(devices);
    }

    public void Attach(PhoneDevice device) => Report([.. _devices, device]);

    public void Detach(PhoneDevice device) => Report([.. _devices.Where(d => !d.Equals(device))]);

    public void Fail(Exception e) => Error?.Invoke(e);

    public void SetStatus(WatchStatus s)
    {
        if (s == Status) return;
        Status = s;
        StatusChanged?.Invoke(s);
    }
}
