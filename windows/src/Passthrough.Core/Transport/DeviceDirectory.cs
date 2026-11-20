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
    private static readonly AsyncLocal<bool> InHandler = new();

    public DeviceDirectory(IEnumerable<IDeviceWatcher> watchers)
    {
        _watchers = [.. watchers];
        foreach (var watcher in _watchers)
        {
            var transport = watcher.Transport;
            watcher.DevicesChanged += list => Update(transport, list);
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

    /// <summary>Fires on a background dispatcher, once per phone arriving or leaving, in order, shortly after <see cref="Devices"/> changes. A handler that throws is ignored.</summary>
    public event Action<DeviceChange>? Changed;

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
        foreach (var watcher in _watchers) await watcher.StopAsync();
        if (InHandler.Value) return;
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
            InHandler.Value = true;
            try { Changed?.Invoke(change!); }
            catch (Exception) { } // one failing handler must not stop later changes reaching the others
            finally { InHandler.Value = false; }
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
