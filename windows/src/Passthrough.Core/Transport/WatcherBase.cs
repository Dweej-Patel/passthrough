namespace Passthrough.Core.Transport;

/// <summary>
/// Shared start/stop, status, device publishing and error reporting for the cable watchers. Events fire on background
/// threads; each subscriber is called on its own, so one that throws is reported through <see cref="Error"/> and
/// reaches neither the others nor the watch loop. A run that faults is reported, its phones are withdrawn, and it is
/// started again after <see cref="FaultRetryDelay"/>.
/// </summary>
public abstract class WatcherBase(WatchTransport transport, TimeProvider time) : IDeviceWatcher
{
    /// <summary>How long a run that faulted waits, on the injected clock, before it starts over.</summary>
    public static readonly TimeSpan FaultRetryDelay = TimeSpan.FromSeconds(5);

    private readonly Lock _gate = new();
    private CancellationTokenSource? _cts;
    private Task? _run;
    private Task? _stopping;
    private WatchStatus _status = new(WatchState.Idle);
    private string? _lastError; // the failure last reported; cleared when watching, so a new failure after a recovery is reported

    protected TimeProvider Time { get; } = time;

    public WatchTransport Transport { get; } = transport;

    public WatchStatus Status
    {
        get { lock (_gate) return _status; }
    }

    public event Action<IReadOnlyList<PhoneDevice>>? DevicesChanged;

    public event Action<WatchStatus>? StatusChanged;

    public event Action<Exception>? Error;

    public void Start()
    {
        lock (_gate)
        {
            if (_cts is not null) return;
            _cts = new CancellationTokenSource();
            _lastError = null;
            var ct = _cts.Token;
            var prior = _stopping; // a run started right after a stop waits for that stop to finish, so the stop's Idle and empty list never land on it.
            _run = Task.Run(async () =>
            {
                if (prior is not null) await prior;
                await GuardedRunAsync(ct);
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

    /// <summary>Never throws: whatever the run did, the watcher ends Idle with no phones.</summary>
    private async Task StopCoreAsync(CancellationTokenSource cts, Task run, Task? prior)
    {
        await Task.Yield();
        try
        {
            if (prior is not null) await prior;
            await cts.CancelAsync();
            await run;
        }
        catch (OperationCanceledException) { }
        catch (Exception e) { ReportError(e); } // the guarded run does not throw; this is a last line
        finally
        {
            cts.Dispose();
            SetStatus(new WatchStatus(WatchState.Idle));
            Publish([]);
        }
    }

    /// <summary>Runs <see cref="RunAsync"/> until cancelled; a fault is reported, its phones withdrawn, and the run started again.</summary>
    private async Task GuardedRunAsync(CancellationToken ct)
    {
        while (!ct.IsCancellationRequested)
        {
            try
            {
                await RunAsync(ct);
                return;
            }
            catch (OperationCanceledException) when (ct.IsCancellationRequested)
            {
                return;
            }
            catch (Exception e)
            {
                ReportError(e);
                Publish([]);
                SetStatus(new WatchStatus(WatchState.Unavailable));
                if (!await DelayAsync(FaultRetryDelay, ct)) return;
            }
        }
    }

    /// <summary>The watch loop; ends when <paramref name="ct"/> is cancelled. Should not throw other than for cancellation; a fault is handled as described on the class.</summary>
    protected abstract Task RunAsync(CancellationToken ct);

    protected void Publish(IReadOnlyList<PhoneDevice> devices) => Raise(DevicesChanged, devices);

    protected void SetStatus(WatchStatus status)
    {
        lock (_gate)
        {
            if (_status == status) return;
            _status = status;
            if (status.State == WatchState.Watching) _lastError = null;
        }
        Raise(StatusChanged, status);
    }

    /// <summary>Reports a failure the watcher absorbed, unless it is the one last reported and the watcher has not watched since.</summary>
    protected void ReportError(Exception e)
    {
        var key = e.GetType().FullName + ": " + e.Message;
        lock (_gate)
        {
            if (key == _lastError) return;
            _lastError = key;
        }
        foreach (var handler in Error?.GetInvocationList() ?? [])
        {
            try { ((Action<Exception>)handler)(e); }
            catch (Exception) { } // a failing logger must not stop the watcher
        }
    }

    /// <summary>Calls each subscriber on its own; one that throws is reported and the rest still run.</summary>
    private void Raise<T>(Action<T>? handlers, T arg)
    {
        foreach (var handler in handlers?.GetInvocationList() ?? [])
        {
            try { ((Action<T>)handler)(arg); }
            catch (Exception e) { ReportError(e); }
        }
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
