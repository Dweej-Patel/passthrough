namespace Passthrough.Core.Transport;

/// <summary>Shared start/stop, status and device publishing for the cable watchers. Events fire on background threads.</summary>
public abstract class WatcherBase(WatchTransport transport, TimeProvider time) : IDeviceWatcher
{
    private readonly Lock _gate = new();
    private CancellationTokenSource? _cts;
    private Task? _run;
    private Task? _stopping;
    private WatchStatus _status = new(WatchState.Idle);

    protected TimeProvider Time { get; } = time;

    public WatchTransport Transport { get; } = transport;

    public WatchStatus Status
    {
        get { lock (_gate) return _status; }
    }

    public event Action<IReadOnlyList<PhoneDevice>>? DevicesChanged;

    public event Action<WatchStatus>? StatusChanged;

    public void Start()
    {
        lock (_gate)
        {
            if (_cts is not null) return;
            _cts = new CancellationTokenSource();
            var ct = _cts.Token;
            var prior = _stopping; // a run started right after a stop waits for that stop to finish, so the stop's Idle and empty list never land on it.
            _run = Task.Run(async () =>
            {
                if (prior is not null) await prior;
                await RunAsync(ct);
            });
        }
    }

    public Task StopAsync()
    {
        lock (_gate)
        {
            if (_cts is null) return _stopping ?? Task.CompletedTask; // already stopped, or a stop in flight: share it
            var cts = _cts;
            var run = _run!;
            var prior = _stopping;
            _cts = null;
            _run = null;
            return _stopping = StopCoreAsync(cts, run, prior);
        }
    }

    private async Task StopCoreAsync(CancellationTokenSource cts, Task run, Task? prior)
    {
        await Task.Yield();
        if (prior is not null) await prior;
        await cts.CancelAsync();
        try { await run; } catch (OperationCanceledException) { }
        cts.Dispose();
        SetStatus(new WatchStatus(WatchState.Idle));
        Publish([]);
    }

    /// <summary>The watch loop; ends when <paramref name="ct"/> is cancelled. Must not throw other than for cancellation.</summary>
    protected abstract Task RunAsync(CancellationToken ct);

    protected void Publish(IReadOnlyList<PhoneDevice> devices) => DevicesChanged?.Invoke(devices);

    protected void SetStatus(WatchStatus status)
    {
        lock (_gate)
        {
            if (_status == status) return;
            _status = status;
        }
        StatusChanged?.Invoke(status);
    }

    /// <summary>Waits on the injected clock; false when cancelled.</summary>
    protected async Task<bool> DelayAsync(TimeSpan delay, CancellationToken ct)
    {
        try
        {
            await Task.Delay(delay, Time, ct);
            return true;
        }
        catch (OperationCanceledException)
        {
            return false;
        }
    }
}
