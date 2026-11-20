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
    /// <summary>
    /// How long after the <paramref name="failures"/>-th drop in a row the active phone is tried again: 2 s more each
    /// time, at most 30 s, as on the Mac. The count starts over on a welcome and when a phone is made active.
    /// </summary>
    public static TimeSpan ReconnectDelay(int failures) => TimeSpan.FromSeconds(Math.Clamp(2 * failures, 2, 30));

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
    /// <summary>Each attached phone's attachment number (see <see cref="PhoneEntry.Attachment"/>).</summary>
    private readonly Dictionary<string, long> _attachments = [];
    private long _attachSeq;
    /// <summary>
    /// Whether each slot holds a well-formed token, as last read: a snapshot reads none, so the store (a file read and
    /// a DPAPI call on Windows) is touched on attach, on open and when the session itself writes or deletes the slot.
    /// </summary>
    private readonly Dictionary<string, bool> _hasToken = [];
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
    /// <summary>Drops in a row since the last welcome; sets the back-off.</summary>
    private int _failures;
    /// <summary>Why the last retryable channel ended, shown while the phone is tried again; cleared by a welcome.</summary>
    private string? _reason;
    /// <summary>The last line logged for the active phone, so a repeat is not logged again.</summary>
    private string? _lastLogged;
    /// <summary>When the current channel was opened (a <see cref="TimeProvider"/> timestamp).</summary>
    private long _openedAt;
    /// <summary>The current channel uses a credential Forget removes: opened with a stored token, or paired on it.</summary>
    private bool _channelHasCredential;
    /// <summary>The name last saved (or tried) for each slot, so a status tick does not write the settings again.</summary>
    private readonly Dictionary<string, string> _namesSaved = [];

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

    /// <summary>
    /// Fires, on the session's background loop, with a line for the log when the active phone's channel ends for a
    /// new reason (a category, never phone-supplied text or a secret); the same reason again is not repeated until
    /// the phone welcomes the PC or another phone is made active.
    /// </summary>
    public event Action<string>? Log;

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

    /// <summary>
    /// Sends the six-digit code shown on a phone, addressed by the phone's id and the <see cref="PhoneEntry.Attachment"/>
    /// of the row it was typed into, and checked when the call runs on the loop: only to that phone, still attached
    /// that same time, still active and unpaired (NotPaired, or Connecting with no stored token). A channel still
    /// opening holds the code until its welcome; with no channel (waiting to reconnect), or one that has just ended, a
    /// fresh one is opened at once. True only when a client took the code for that phone; false when it was not
    /// sent, so the caller can keep it.
    /// </summary>
    public Task<bool> SubmitCodeAsync(string phoneId, long attachment, string code) => RunAsync(async () =>
    {
        if (_closed || _active is not { } device || device.Id != phoneId || AttachmentOf(device) != attachment) return false;
        var unpaired = _activeState == PhoneState.NotPaired || (_activeState == PhoneState.Connecting && !HasToken(device));
        if (!unpaired) return false;
        if (_client is { } current && !await current.SubmitCodeAsync(code))
        {
            // The channel has ended but its Disconnected is still queued behind this call: drop it (its events no
            // longer count) and put the code on a fresh one, as during a back-off.
            _client = null;
            await current.DisposeAsync();
        }
        else if (_client is not null) return TookCode();
        OpenClient(keepState: true);
        // A fresh client takes the code unless the store failed (the phone is Failed now, with Try again).
        return _client is not null && await _client.SubmitCodeAsync(code) && TookCode();
    });

    private bool TookCode()
    {
        _activeState = PhoneState.Pairing;
        _message = null;
        _reason = null;
        return true;
    }

    /// <summary>Deletes an attached phone's stored token (see <see cref="ForgetSlotAsync"/>); nothing for a phone that is not attached.</summary>
    public Task ForgetAsync(string phoneId) => RunAsync(() =>
    {
        if (_devices.FirstOrDefault(d => d.Id == phoneId) is { } device) return ForgetAsyncCore(device.PairingSlot);
        return Task.CompletedTask;
    });

    /// <summary>
    /// Deletes the token in a slot, whether or not its phone is attached (a phone sold or lost). When it is the
    /// active phone's, closes its channel and opens a fresh one, which asks to pair. Forgetting a slot that holds
    /// nothing does nothing, so a second Forget is not an error.
    /// </summary>
    public Task ForgetSlotAsync(string pairingSlot) => RunAsync(() => ForgetAsyncCore(pairingSlot));

    /// <summary>The slots this PC holds a pairing token in, attached or not, sorted (empty after disposal).</summary>
    public async Task<IReadOnlyList<string>> PairedSlotsAsync() => await RunAsync(() => Task.FromResult(_secrets.Slots())) ?? [];

    private async Task ForgetAsyncCore(string slot)
    {
        _secrets.Delete(slot); // never read first: a slot that cannot be read can still be deleted
        _hasToken[slot] = false;
        ForgetName(slot);
        // Reopen the active phone's channel only if it uses a credential (opened with a token, or paired on it), or if
        // none is open (waiting or failed); an unpaired channel is left alone, so a second Forget changes nothing.
        if (!_closed && _active is { } active && active.PairingSlot == slot && (_channelHasCredential || _client is null))
            await ActivateAsync(active);
    }

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

    /// <summary>As <see cref="RunAsync(Func{Task})"/>, with the work's result; after disposal, <c>default</c>.</summary>
    private async Task<T?> RunAsync<T>(Func<Task<T>> work)
    {
        T? result = default;
        await RunAsync(async () => { result = await work(); });
        return result;
    }

    /// <summary>Queues work without waiting; safe from any thread, never blocks.</summary>
    private void Post(Func<Task> work) => _work.Writer.TryWrite((work, null));

    private async Task OnDeviceChangeAsync(DeviceChange change)
    {
        if (_closed) return;
        switch (change)
        {
            case DeviceChange.Attached a:
                if (!_devices.Contains(a.Device))
                {
                    _devices.Add(a.Device);
                    _attachments[a.Device.Id] = ++_attachSeq;
                    _hasToken.Remove(a.Device.PairingSlot); // read afresh for each attachment
                }
                break;
            case DeviceChange.Detached d:
                _devices.Remove(d.Device);
                _attachments.Remove(d.Device.Id);
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
        _reason = null;
        _failures = 0;
        _lastLogged = null;
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
            var token = StoredToken(device);
            _hasToken[device.PairingSlot] = token is not null;
            _clientId ??= HostIdentity.ClientId(_settings);
            client = _clientFactory(device, new ControlIdentity(_clientId, _computerName, token));
        }
        catch (Exception e)
        {
            _hasToken.TryAdd(device.PairingSlot, false); // the slot could not be read: counts as empty, reported once
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
        _openedAt = _time.GetTimestamp();
        _channelHasCredential = _hasToken[device.PairingSlot];
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
            case ControlEvent.Welcomed w:
                // The phone is there: the back-off and the last reason start over.
                (_failures, _reason, _lastLogged) = (0, null, null);
                if (w.Paired)
                {
                    _activeState = PhoneState.Paired;
                    _message = null;
                }
                else if (_activeState != PhoneState.Pairing) _activeState = PhoneState.NotPaired; // a code may already be on its way
                break;
            case ControlEvent.PairedWith p:
                try
                {
                    _secrets.Set(_active!.PairingSlot, p.Token);
                    _hasToken[_active.PairingSlot] = true;
                    _channelHasCredential = true;
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
                SaveName(_active!.PairingSlot, s.Status.DeviceName);
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
                    LogClosed(failure.Kind.ToString(), retrying: false);
                }
                else if (d.Error is null && _activeState == PhoneState.NotPaired
                    && _time.GetElapsedTime(_openedAt) >= ProtocolConstants.UnauthenticatedTimeout / 2)
                {
                    // The phone closes a channel that has not paired within 10 s unless a code is showing. The user may
                    // still be reading the code off the phone: a fresh channel at once, and the box stays (as on the
                    // Mac; not for a channel closed sooner, so something closing channels at once is not looped on).
                    await client.DisposeAsync();
                    OpenClient(keepState: true);
                    break;
                }
                else
                {
                    var category = DisconnectReason.Classify(d.Error);
                    _reason = DisconnectReason.Describe(category, _active!.Kind.Label());
                    _activeState = PhoneState.Connecting;
                    LogClosed(category.ToString(), retrying: true);
                    ScheduleReconnect();
                }
                await client.DisposeAsync(); // already over; this just waits for its background work
                break;
        }
    }

    private void ScheduleReconnect()
    {
        CancelReconnect();
        _failures++;
        var seq = _reconnectSeq;
        _reconnect = _time.CreateTimer(_ => Post(() =>
        {
            if (seq == _reconnectSeq && !_closed && !_held && _active is not null && _client is null) OpenClient();
            return Task.CompletedTask;
        }), null, ReconnectDelay(_failures), Timeout.InfiniteTimeSpan);
    }

    private void CancelReconnect()
    {
        _reconnectSeq++;
        _reconnect?.Dispose();
        _reconnect = null;
    }

    /// <summary>Logs why the active phone's channel ended, unless that was the last line logged for it.</summary>
    private void LogClosed(string category, bool retrying)
    {
        var line = $"{_active!.Id} ({_active.Kind.Label()}): channel closed: {category}" + (retrying ? "; retrying" : "");
        if (line == _lastLogged) return;
        _lastLogged = line;
        try { Log?.Invoke(line); }
        catch (Exception) { } // a failing logger must not stop the session
    }

    /// <summary>Keeps the name a paired phone gives itself beside its pairing (see <see cref="DeviceNames"/>); a failed write is reported once.</summary>
    private void SaveName(string slot, string? name)
    {
        if (string.IsNullOrWhiteSpace(name) || _namesSaved.GetValueOrDefault(slot) == name) return;
        _namesSaved[slot] = name;
        if (DeviceNames.Get(_settings, slot) == name) return;
        try { _settings.Set(DeviceNames.Key(slot), name); }
        catch (Exception e) { ReportError(e); }
    }

    private void ForgetName(string slot)
    {
        _namesSaved.Remove(slot);
        try
        {
            if (DeviceNames.Get(_settings, slot) is not null) _settings.Set(DeviceNames.Key(slot), "");
        }
        catch (Exception e) { ReportError(e); } // the token is gone; a name left behind only labels nothing
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
        var name = DeviceNames.Get(_settings, d.PairingSlot);
        if (!d.CanRoute) return new PhoneEntry(d, PhoneState.RemoteOnlyLater, false, null, 0, 0, 0, IPadMessage, HasToken(d), AttachmentOf(d), name);
        if (d.Equals(_active)) return new PhoneEntry(d, _activeState, true, _status, _rx, _tx, _connections, _message ?? _reason, HasToken(d), AttachmentOf(d), name);
        var hasToken = HasToken(d);
        return new PhoneEntry(d, hasToken ? PhoneState.Paired : PhoneState.NotPaired, false, null, 0, 0, 0, null, hasToken, AttachmentOf(d), name);
    }

    /// <summary>Whether the phone's slot holds a well-formed token (cached, see <see cref="_hasToken"/>); a slot that cannot be read counts as empty and is reported once.</summary>
    private bool HasToken(PhoneDevice d)
    {
        if (_hasToken.TryGetValue(d.PairingSlot, out var known)) return known;
        bool has;
        try { has = StoredToken(d) is not null; }
        catch (Exception e)
        {
            ReportError(e);
            has = false;
        }
        _hasToken[d.PairingSlot] = has;
        return has;
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

    private long AttachmentOf(PhoneDevice d) => _attachments.GetValueOrDefault(d.Id);

    private WatchStatus WatcherStatus(WatchTransport t) => _directory.Watcher(t)?.Status ?? new WatchStatus(WatchState.Idle);
}
