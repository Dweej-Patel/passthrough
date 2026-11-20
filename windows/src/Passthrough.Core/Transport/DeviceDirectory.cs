namespace Passthrough.Core.Transport;

/// <summary>
/// Tracks every watcher's phones in attach order and reports each change. Thread-safe: <see cref="Devices"/> is a snapshot,
/// and <see cref="Changed"/> fires on whichever background thread a watcher reported from, in order, with no lock held.
/// </summary>
public sealed class DeviceDirectory
{
    private readonly Lock _gate = new();
    private readonly Lock _eventGate = new();
    private readonly List<PhoneDevice> _devices = [];
    private readonly Dictionary<string, WatchTransport> _source = [];
    private readonly IReadOnlyList<IDeviceWatcher> _watchers;

    public DeviceDirectory(IEnumerable<IDeviceWatcher> watchers)
    {
        _watchers = [.. watchers];
        foreach (var watcher in _watchers)
        {
            var transport = watcher.Transport;
            watcher.DevicesChanged += list => Update(transport, list);
        }
    }

    /// <summary>Attached phones, oldest first. A snapshot.</summary>
    public IReadOnlyList<PhoneDevice> Devices
    {
        get { lock (_gate) return [.. _devices]; }
    }

    public IReadOnlyList<IDeviceWatcher> Watchers => _watchers;

    public IDeviceWatcher? Watcher(WatchTransport t) => _watchers.FirstOrDefault(w => w.Transport == t);

    /// <summary>Fires on a background thread, once per phone arriving or leaving, in order.</summary>
    public event Action<DeviceChange>? Changed;

    public void Start()
    {
        foreach (var watcher in _watchers) watcher.Start();
    }

    public async Task StopAsync()
    {
        foreach (var watcher in _watchers) await watcher.StopAsync();
    }

    /// <summary>Detaches first, then attaches, so a replugged phone reads as a fresh arrival.</summary>
    private void Update(WatchTransport transport, IReadOnlyList<PhoneDevice> list)
    {
        lock (_eventGate)
        {
            var changes = new List<DeviceChange>();
            lock (_gate)
            {
                var listed = list.Select(d => d.Id).ToHashSet();
                foreach (var gone in _devices.Where(d => _source[d.Id] == transport && !listed.Contains(d.Id)).ToList())
                {
                    _devices.Remove(gone);
                    _source.Remove(gone.Id);
                    changes.Add(new DeviceChange.Detached(gone));
                }
                foreach (var added in list.Where(d => !_devices.Contains(d)))
                {
                    _devices.Add(added);
                    _source[added.Id] = transport;
                    changes.Add(new DeviceChange.Attached(added));
                }
            }
            foreach (var change in changes) Changed?.Invoke(change);
        }
    }
}
