using System.Threading.Channels;
using Passthrough.Core.Control;
using Passthrough.Core.Protocol;
using Passthrough.Core.Storage;
using Passthrough.Core.Transport;

namespace Passthrough.Core.Session;

/// <summary>
/// The heart of the app (port of the device, pairing and reconnect parts of SessionCoordinator.swift): follows the
/// attached phones, keeps one control channel open to the active phone, pairs it with a code, reconnects it, and
/// forgets pairings.
/// <para>
/// Every state change runs as one work item on a single loop, in order: public calls, directory changes, watcher
/// status changes, every client's events and the reconnect timer all queue there, so nothing interleaves. Events
/// from a client that is no longer current are dropped.
/// </para>
/// </summary>
public sealed class HostSession : IAsyncDisposable
{
    /// <summary>How long after a channel drops the active phone is tried again.</summary>
    public static readonly TimeSpan ReconnectDelay = TimeSpan.FromSeconds(2);

    private const string AndroidEnabledKey = "androidEnabled";
    private const string IPadMessage = "Pairs once Remote shell is available.";
    private const string SaveFailedMessage = "Couldn't save the pairing on this PC. Try pairing again.";
    private const string OpenFailedMessage = "Couldn't read this PC's saved pairings or settings. Try again.";

    private readonly DeviceDirectory _directory;
    private readonly ISecretStore _secrets;
    private readonly ISettingsStore _settings;
    private readonly string _computerName;
    private readonly Func<PhoneDevice, ControlIdentity, ControlClient> _clientFactory;
    private readonly TimeProvider _time;
    private readonly Channel<(Func<Task> Work, TaskCompletionSource? Done)> _work =
        Channel.CreateUnbounded<(Func<Task>, TaskCompletionSource?)>(new UnboundedChannelOptions { SingleReader = true });
    private readonly Task _loop;
    private int _disposed;
    private volatile SessionState _state = new([], new WatchStatus(WatchState.Idle), new WatchStatus(WatchState.Idle));

    // Everything below is touched only by work items on the loop.
    private readonly List<PhoneDevice> _devices = [];
    private readonly List<Task> _readers = [];
    private string? _clientId;
    private bool _started;
    private bool _closed;
    private PhoneDevice? _active;
    private ControlClient? _client;
    private PhoneState _activeState;
    private DeviceStatus? _status;
    private long _rx;
    private long _tx;
    private int _connections;
    private string? _message;
    /// <summary>The active phone's channel failed for good (failed proof, other version, token not saved, store unreadable): no reconnect until it is re-attached or made active.</summary>
    private bool _held;
    private ITimer? _reconnect;
    private long _reconnectSeq;

    public HostSession(DeviceDirectory directory, ISecretStore secrets, ISettingsStore settings, string computerName,
        Func<PhoneDevice, ControlIdentity, ControlClient> clientFactory, TimeProvider time)
    {
        _directory = directory;
        _secrets = secrets;
        _settings = settings;
        _computerName = computerName;
        _clientFactory = clientFactory;
        _time = time;
        _loop = Task.Run(RunLoopAsync);
        // Both fire on background threads; never block them, just queue.
        _directory.Changed += change => Post(() => OnDeviceChangeAsync(change));
        foreach (var watcher in _directory.Watchers) watcher.StatusChanged += _ => Post(() => Task.CompletedTask);
    }

    /// <summary>The latest snapshot.</summary>
    public SessionState State => _state;

    /// <summary>
    /// Fires with a fresh snapshot after each change, on the session's background loop. A handler must not wait for a
    /// session call to finish (that call waits for the loop); marshal to the UI thread and return.
    /// </summary>
    public event Action<SessionState>? StateChanged;

    /// <summary>
    /// Fires, on the session's background loop, with an exception the session absorbed so it could keep going
    /// (a store or client factory failing in background work, a slot that could not be read). For logging.
    /// </summary>
    public event Action<Exception>? Error;

    private bool AndroidEnabled => _settings.Get(AndroidEnabledKey) != "false";

    /// <summary>Starts the watchers (adb only when Android is enabled).</summary>
    public Task StartAsync() => RunAsync(() =>
    {
        if (_started || _closed) return Task.CompletedTask;
        _started = true;
        foreach (var watcher in _directory.Watchers)
            if (watcher.Transport != WatchTransport.Adb || AndroidEnabled) watcher.Start();
        return Task.CompletedTask;
    });

    /// <summary>Moves the control channel to an attached phone that can carry the PC's internet; tries again a phone whose channel failed.</summary>
    public Task MakeActiveAsync(string phoneId) => RunAsync(async () =>
    {
        if (_closed || _devices.FirstOrDefault(d => d.Id == phoneId) is not { CanRoute: true } device) return;
        if (device.Equals(_active) && _client is not null) return;
        await ActivateAsync(device);
    });

    /// <summary>
    /// "Try again" for a phone whose channel failed: when it is the active phone, clears the hold and the failure
    /// message and opens a fresh channel to it; otherwise makes it active. Nothing for a phone that is not attached
    /// or cannot carry the PC's internet.
    /// </summary>
    public Task RetryAsync(string phoneId) => RunAsync(async () =>
    {
        if (_closed || _devices.FirstOrDefault(d => d.Id == phoneId) is not { CanRoute: true } device) return;
        await ActivateAsync(device); // dropping the old channel clears the hold and the message
    });

    /// <summary>Sends the six-digit code shown on the active phone (held until its welcome when the channel is still opening).</summary>
    public Task SubmitCodeAsync(string code) => RunAsync(async () =>
    {
        if (_client is null || _activeState is not (PhoneState.Connecting or PhoneState.NotPaired)) return;
        _activeState = PhoneState.Pairing;
        _message = null;
        await _client.SubmitCodeAsync(code);
    });

    /// <summary>Deletes the phone's stored token; when it is the active phone, closes its channel and opens a fresh one, which asks to pair.</summary>
    public Task ForgetAsync(string phoneId) => RunAsync(async () =>
    {
        if (_devices.FirstOrDefault(d => d.Id == phoneId) is not { } device) return;
        _secrets.Delete(device.PairingSlot);
        if (!_closed && device.Equals(_active)) await ActivateAsync(device);
    });

    /// <summary>Remembers the choice; off stops the adb watcher (its phones leave), on starts it again.</summary>
    public Task SetAndroidEnabledAsync(bool on) => RunAsync(async () =>
    {
        _settings.Set(AndroidEnabledKey, on ? "true" : "false");
        if (_closed || _directory.Watcher(WatchTransport.Adb) is not { } adb) return;
        if (!on) await adb.StopAsync();
        else if (_started) adb.Start();
    });

    /// <summary>Closes the active phone's channel and stops the directory; later calls do nothing.</summary>
    public async ValueTask DisposeAsync()
    {
        if (Interlocked.Exchange(ref _disposed, 1) != 0) return;
        // Closed first, so phones leaving as the watchers stop do not open a channel to another one.
        await RunAsync(async () =>
        {
            _closed = true;
            await DropActiveAsync();
        });
        await _directory.StopAsync();
        _work.Writer.TryComplete();
        await _loop;
        await Task.WhenAll(_readers); // the loop is over: nothing else touches the list
    }

    private async Task RunLoopAsync()
    {
        await foreach (var (work, done) in _work.Reader.ReadAllAsync())
        {
            Exception? error = null;
            try { await work(); }
            catch (Exception e) { error = e; } // a failing store or factory must not stop the loop
            try { Publish(); }
            catch (Exception e) { ReportError(e); } // nor a failing snapshot: every item still completes
            if (error is null) done?.TrySetResult();
            else if (done is not null) done.TrySetException(error); // the caller sees it
            else ReportError(error); // nobody waits for background work: report it
        }
    }

    /// <summary>Queues work and waits for it (and for the state it produced) to be done. After disposal it does nothing.</summary>
    private Task RunAsync(Func<Task> work)
    {
        var done = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        return _work.Writer.TryWrite((work, done)) ? done.Task : Task.CompletedTask;
    }

    /// <summary>Queues work without waiting; safe from any thread, never blocks.</summary>
    private void Post(Func<Task> work) => _work.Writer.TryWrite((work, null));

    private async Task OnDeviceChangeAsync(DeviceChange change)
    {
        if (_closed) return;
        switch (change)
        {
            case DeviceChange.Attached a:
                if (!_devices.Contains(a.Device)) _devices.Add(a.Device);
                break;
            case DeviceChange.Detached d:
                _devices.Remove(d.Device);
                if (d.Device.Equals(_active)) await DropActiveAsync();
                break;
        }
        // The active phone stays while attached; otherwise the first one that can carry the PC's internet.
        if (_active is null && _devices.FirstOrDefault(d => d.CanRoute) is { } best) await ActivateAsync(best);
    }

    private async Task ActivateAsync(PhoneDevice device)
    {
        await DropActiveAsync();
        _active = device;
        OpenClient();
    }

    /// <summary>Closes the active phone's channel, cancels a pending reconnect, and leaves no phone active.</summary>
    private async Task DropActiveAsync()
    {
        CancelReconnect();
        var client = _client;
        _client = null;
        _active = null;
        _held = false;
        _activeState = PhoneState.Connecting;
        ClearStatus();
        _message = null;
        if (client is not null) await client.DisposeAsync();
    }

    /// <summary>
    /// Opens a channel to the active phone with the token its slot holds, if well-formed. Keeps the message (a pairing
    /// failure stays shown across a reconnect). <paramref name="keepState"/>: an unpaired phone stays NotPaired while the
    /// fresh channel opens, so the code box stays up.
    /// </summary>
    private void OpenClient(bool keepState = false)
    {
        CancelReconnect();
        var device = _active!;
        ControlClient client;
        try
        {
            _clientId ??= HostIdentity.ClientId(_settings);
            client = _clientFactory(device, new ControlIdentity(_clientId, _computerName, StoredToken(device)));
        }
        catch (Exception e)
        {
            // The slot or the settings could not be read or written (a locked file, a full disk): nothing to retry
            // on its own, but Try again may work once the store recovers.
            ReportError(e);
            ClearStatus();
            _activeState = PhoneState.Failed;
            _message = OpenFailedMessage;
            _held = true;
            return;
        }
        _client = client;
        if (!keepState) _activeState = PhoneState.Connecting;
        ClearStatus();
        _readers.RemoveAll(t => t.IsCompleted);
        _readers.Add(Task.Run(async () =>
        {
            await foreach (var e in client.Events.ReadAllAsync()) Post(() => OnClientEventAsync(client, e));
        }));
        _ = client.StartAsync(CancellationToken.None); // never faults; a failed open arrives as Disconnected
    }

    private async Task OnClientEventAsync(ControlClient client, ControlEvent e)
    {
        if (!ReferenceEquals(client, _client)) return; // a channel closed since: its events no longer count
        switch (e)
        {
            case ControlEvent.Welcomed { Paired: true }:
                _activeState = PhoneState.Paired;
                _message = null;
                break;
            case ControlEvent.Welcomed:
                if (_activeState != PhoneState.Pairing) _activeState = PhoneState.NotPaired; // a code may already be on its way
                break;
            case ControlEvent.PairedWith p:
                try
                {
                    _secrets.Set(_active!.PairingSlot, p.Token);
                }
                catch (Exception error)
                {
                    // Unsaved, the pairing is lost on the next channel: say so, and stop here, as for a failed proof.
                    ReportError(error);
                    _client = null; // its status and disconnect no longer count
                    ClearStatus();
                    _activeState = PhoneState.Failed;
                    _message = SaveFailedMessage;
                    _held = true;
                    await client.DisposeAsync();
                    break;
                }
                _activeState = PhoneState.Paired;
                _message = null;
                break;
            case ControlEvent.PairingFailed f:
                if (_activeState == PhoneState.Pairing) _activeState = PhoneState.NotPaired;
                _message = Describe(f.Reason, _active!.Kind.Label());
                if (f.Reason == PairingFailure.Locked)
                {
                    // The phone closes this channel; the code still works on a new one, so open that now (as the Mac does).
                    _client = null;
                    await client.DisposeAsync();
                    OpenClient(keepState: true);
                }
                break;
            case ControlEvent.StatusUpdate s:
                _activeState = PhoneState.Paired; // status flows only on a proved channel
                (_status, _rx, _tx, _connections) = (s.Status, s.Rx, s.Tx, s.Active);
                break;
            case ControlEvent.Disconnected d:
                _client = null;
                ClearStatus();
                if (d.Error is ControlException failure)
                {
                    // Retrying cannot fix a failed proof or another version; the stored token stays.
                    _activeState = PhoneState.Failed;
                    _message = failure.Message;
                    _held = true;
                }
                else
                {
                    _activeState = PhoneState.Connecting;
                    ScheduleReconnect();
                }
                await client.DisposeAsync(); // already over; this just waits for its background work
                break;
        }
    }

    private void ScheduleReconnect()
    {
        CancelReconnect();
        var seq = _reconnectSeq;
        _reconnect = _time.CreateTimer(_ => Post(() =>
        {
            if (seq == _reconnectSeq && !_closed && !_held && _active is not null && _client is null) OpenClient();
            return Task.CompletedTask;
        }), null, ReconnectDelay, Timeout.InfiniteTimeSpan);
    }

    private void CancelReconnect()
    {
        _reconnectSeq++;
        _reconnect?.Dispose();
        _reconnect = null;
    }

    private void ClearStatus() => (_status, _rx, _tx, _connections) = (null, 0, 0, 0);

    /// <summary>The Mac's wording for a failed code (SessionCoordinator.swift), naming the device.</summary>
    private static string Describe(PairingFailure reason, string kind) => reason switch
    {
        PairingFailure.Expired => $"The code expired or wasn't generated yet. Tap Pair on the {kind} and try again.",
        PairingFailure.NotAuthenticated => "Not authenticated.",
        PairingFailure.UnsupportedVersion => $"The {kind} app is a different version. Update both apps.",
        PairingFailure.Locked => $"That code didn't match again. Check the digits on the {kind}, then type them once more.",
        PairingFailure.CodeWithdrawn =>
            $"Too many wrong codes were tried, so the {kind} withdrew that code. Tap Pair on the {kind} for a new one, then type it here.",
        _ => $"That code didn't match. Check the digits on the {kind}.",
    };

    /// <summary>Builds the snapshot and raises <see cref="StateChanged"/> when it differs from the last one.</summary>
    private void Publish()
    {
        if (_closed) return;
        var next = new SessionState([.. _devices.Select(EntryFor)], WatcherStatus(WatchTransport.UsbMux), WatcherStatus(WatchTransport.Adb));
        var last = _state;
        if (last.UsbMux == next.UsbMux && last.Adb == next.Adb && last.Phones.SequenceEqual(next.Phones)) return;
        _state = next;
        try { StateChanged?.Invoke(next); }
        catch (Exception) { } // a failing subscriber must not stop the session
    }

    private PhoneEntry EntryFor(PhoneDevice d)
    {
        if (!d.CanRoute) return new PhoneEntry(d, PhoneState.RemoteOnlyLater, false, null, 0, 0, 0, IPadMessage, HasToken(d));
        if (d.Equals(_active)) return new PhoneEntry(d, _activeState, true, _status, _rx, _tx, _connections, _message, HasToken(d));
        var hasToken = HasToken(d);
        return new PhoneEntry(d, hasToken ? PhoneState.Paired : PhoneState.NotPaired, false, null, 0, 0, 0, null, hasToken);
    }

    /// <summary>Whether the phone's slot holds a well-formed token; a slot that cannot be read counts as empty.</summary>
    private bool HasToken(PhoneDevice d)
    {
        try { return StoredToken(d) is not null; }
        catch (Exception e)
        {
            ReportError(e);
            return false;
        }
    }

    /// <summary>
    /// The phone's stored token, checked for format before use: anything else in the slot counts as no token (the
    /// slot is left alone; pairing again replaces it).
    /// </summary>
    private string? StoredToken(PhoneDevice d) =>
        _secrets.Get(d.PairingSlot) is { } token && PairingToken.IsWellFormed(token) ? token : null;

    private void ReportError(Exception e)
    {
        try { Error?.Invoke(e); }
        catch (Exception) { } // a failing logger must not stop the session
    }

    private WatchStatus WatcherStatus(WatchTransport t) => _directory.Watcher(t)?.Status ?? new WatchStatus(WatchState.Idle);
}
