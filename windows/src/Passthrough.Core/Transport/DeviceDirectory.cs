using System.Threading.Channels;

namespace Passthrough.Core.Transport;

/// <summary>
/// Tracks every watcher's phones in attach order and reports each change. Thread-safe: <see cref="Devices"/> is a snapshot,
/// and <see cref="Changed"/> is delivered in order from one dispatcher thread-pool loop, with no lock held, so a handler may block on a watcher or on <see cref="StopAsync"/>.
/// </summary>
public sealed class DeviceDirectory
{
    private readonly Lock _gate = new();
    private readonly Channel<(DeviceChange? Change, TaskCompletionSource? Barrier)> _changes = Channel.CreateUnbounded<(DeviceChange?, TaskCompletionSource?)>(new UnboundedChannelOptions { SingleReader = true });
    private readonly List<PhoneDevice> _devices = [];
    private readonly Dictionary<string, WatchTransport> _source = [];
    private readonly IReadOnlyList<IDeviceWatcher> _watchers;
    [ThreadStatic]
    private static bool _dispatching; // true only on the dispatcher thread while it is inside a Changed handler

    public DeviceDirectory(IEnumerable<IDeviceWatcher> watchers)
    {
        _watchers = [.. watchers];
        foreach (var watcher in _watchers)
        {
            var transport = watcher.Transport;
            watcher.DevicesChanged += list => Update(transport, list);
            watcher.Error += e => ReportError(new WatcherException(transport, e));
        }
        _ = Task.Run(DispatchAsync);
    }

    /// <summary>Attached phones, oldest first. A snapshot.</summary>
    public IReadOnlyList<PhoneDevice> Devices
    {
        get { lock (_gate) return [.. _devices]; }
    }

    public IReadOnlyList<IDeviceWatcher> Watchers => _watchers;

    public IDeviceWatcher? Watcher(WatchTransport t) => _watchers.FirstOrDefault(w => w.Transport == t);

    /// <summary>
    /// Fires on a background dispatcher, once per phone arriving or leaving, in order, shortly after <see cref="Devices"/>
    /// changes. Each handler is called on its own: one that throws is reported through <see cref="Error"/>, and the
    /// others still get the change.
    /// </summary>
    public event Action<DeviceChange>? Changed;

    /// <summary>
    /// Fires with a failure absorbed so discovery could keep going, for logging: a watcher's (wrapped in a
    /// <see cref="WatcherException"/> naming its transport, on that watcher's thread) or a <see cref="Changed"/>
    /// handler's (on the dispatcher). A handler that throws is ignored.
    /// </summary>
    public event Action<Exception>? Error;

    private void ReportError(Exception e)
    {
        foreach (var handler in Error?.GetInvocationList() ?? [])
        {
            try { ((Action<Exception>)handler)(e); }
            catch (Exception) { } // a failing logger must not stop discovery
        }
    }

    public void Start()
    {
        foreach (var watcher in _watchers) watcher.Start();
    }

    /// <summary>
    /// Stops every watcher, then waits until every change queued so far has been delivered to <see cref="Changed"/>, so no
    /// stale event arrives after it returns. Called from inside a <see cref="Changed"/> handler it does not wait for delivery
    /// (the dispatcher is busy running that handler).
    /// </summary>
    public async Task StopAsync()
    {
        var insideHandler = _dispatching; // read before any await: after one we may be on another thread
        foreach (var watcher in _watchers) await watcher.StopAsync();
        if (insideHandler) return;
        var barrier = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        _changes.Writer.TryWrite((null, barrier));
        await barrier.Task;
    }

    private async Task DispatchAsync()
    {
        await foreach (var (change, barrier) in _changes.Reader.ReadAllAsync())
        {
            if (barrier is not null)
            {
                barrier.TrySetResult();
                continue;
            }
            _dispatching = true;
            try
            {
                foreach (var handler in Changed?.GetInvocationList() ?? [])
                {
                    try { ((Action<DeviceChange>)handler)(change!); }
                    catch (Exception e) { ReportError(e); } // one failing handler must not keep the change from the others
                }
            }
            finally { _dispatching = false; }
        }
    }

    /// <summary>Detaches first, then attaches, so a replugged phone reads as a fresh arrival. Changes are queued under the lock so their order matches the state.</summary>
    private void Update(WatchTransport transport, IReadOnlyList<PhoneDevice> list)
    {
        lock (_gate)
        {
            var listed = list.Select(d => d.Id).ToHashSet();
            foreach (var gone in _devices.Where(d => _source[d.Id] == transport && !listed.Contains(d.Id)).ToList())
            {
                _devices.Remove(gone);
                _source.Remove(gone.Id);
                _changes.Writer.TryWrite((new DeviceChange.Detached(gone), null));
            }
            foreach (var added in list.Where(d => !_devices.Contains(d)))
            {
                _devices.Add(added);
                _source[added.Id] = transport;
                _changes.Writer.TryWrite((new DeviceChange.Attached(added), null));
            }
        }
    }
}
