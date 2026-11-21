using System.Threading.Channels;
using Passthrough.Core.Control;
using Passthrough.Core.Protocol;
using Passthrough.Core.Storage;
using Passthrough.Core.Transport;

namespace Passthrough.Core.Session;

/// <summary>
/// The heart of the app (port of the device, pairing and reconnect parts of SessionCoordinator.swift): follows the
/// attached devices, keeps a control channel open to every one of them (iPads included), pairs each with a code,
/// reconnects them, and forgets pairings. One attached phone that can carry the PC's internet is marked active: it
/// decides the flyout's header and, later, which phone the PC goes online through. It no longer decides who has a
/// channel: each device's phone app serves this PC on its own, and shell grants go to every one (stage 3 of the
/// Windows plan, "a channel to every attached device").
/// <para>
/// Every state change runs as one work item on a single loop, in order: public calls, directory changes, watcher
/// status changes, every client's events and the reconnect timers all queue there, so nothing interleaves. Events
/// from a client that is no longer its device's current one are dropped.
/// </para>
/// </summary>
public sealed class HostSession : IAsyncDisposable
{
    /// <summary>
    /// How long after the <paramref name="failures"/>-th drop in a row a device is tried again: 2 s more each time,
    /// at most 30 s, as on the Mac. The count starts over on a welcome and on Try again.
    /// </summary>
    public static TimeSpan ReconnectDelay(int failures) => TimeSpan.FromSeconds(Math.Clamp(2 * failures, 2, 30));

    private const string AndroidEnabledKey = "androidEnabled";
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
    /// <summary>Each attached device's channel, by device id.</summary>
    private readonly Dictionary<string, DeviceChannel> _channels = [];
    /// <summary>Each attached device's attachment number (see <see cref="PhoneEntry.Attachment"/>).</summary>
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
    /// <summary>The device marked active (see the class summary), or null.</summary>
    private string? _activeId;
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
    /// Fires, on the session's background loop, with a line for the log when a device's channel ends for a new reason
    /// (a category, never phone-supplied text or a secret); the same reason again is not repeated until that device
    /// welcomes the PC or is tried again. Also when a paired phone says Passthrough was turned off on it.
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

    /// <summary>
    /// Marks an attached phone that can carry the PC's internet as the active one, and tries it again if its channel
    /// failed. Nothing for a device that is not attached or cannot carry the PC's internet.
    /// </summary>
    public Task MakeActiveAsync(string phoneId) => RunAsync(async () =>
    {
        if (_closed || _devices.FirstOrDefault(d => d.Id == phoneId) is not { CanRoute: true } device) return;
        _activeId = device.Id;
        if (_channels[device.Id].Client is null) await ReopenAsync(_channels[device.Id]);
    });

    /// <summary>
    /// "Try again" for a device whose channel failed or is waiting to reconnect: clears the hold and the failure
    /// message and opens a fresh channel to it. Nothing for a device that is not attached.
    /// </summary>
    public Task RetryAsync(string phoneId) => RunAsync(async () =>
    {
        if (_closed || !_channels.TryGetValue(phoneId, out var channel)) return;
        await ReopenAsync(channel);
    });

    /// <summary>
    /// Sends the six-digit code shown on a device, addressed by its id and the <see cref="PhoneEntry.Attachment"/> of
    /// the row it was typed into, and checked when the call runs on the loop: only to that device, still attached that
    /// same time, and unpaired (NotPaired, or Connecting with no stored token). A channel still opening holds the code
    /// until its welcome; with no channel (waiting to reconnect), or one that has just ended, a fresh one is opened at
    /// once. True only when a client took the code; false when it was not sent, so the caller can keep it.
    /// </summary>
    public Task<bool> SubmitCodeAsync(string phoneId, long attachment, string code) => RunAsync(async () =>
    {
        if (_closed || !_channels.TryGetValue(phoneId, out var ch) || AttachmentOf(ch.Device) != attachment) return false;
        var unpaired = ch.State == PhoneState.NotPaired || (ch.State == PhoneState.Connecting && !HasToken(ch.Device));
        if (!unpaired) return false;
        if (ch.Client is { } current && !await current.SubmitCodeAsync(code))
        {
            // The channel has ended but its Disconnected is still queued behind this call: drop it (its events no
            // longer count) and put the code on a fresh one, as during a back-off.
            ch.Client = null;
            await current.DisposeAsync();
        }
        else if (ch.Client is not null) return TookCode(ch, code);
        OpenClient(ch, keepState: true);
        // A fresh client takes the code unless the store failed (the device is Failed now, with Try again).
        return ch.Client is not null && await ch.Client.SubmitCodeAsync(code) && TookCode(ch, code);
    });

    private static bool TookCode(DeviceChannel ch, string code)
    {
        // Before the welcome the client only holds the code; remember it until it goes out (see UnsentCode).
        ch.UnsentCode = ch.Welcomed ? null : code;
        ch.State = PhoneState.Pairing;
        ch.Message = null;
        ch.Reason = null;
        return true;
    }

    /// <summary>Deletes an attached device's stored token (see <see cref="ForgetSlotAsync"/>); nothing for a device that is not attached.</summary>
    public Task ForgetAsync(string phoneId) => RunAsync(() =>
    {
        if (_devices.FirstOrDefault(d => d.Id == phoneId) is { } device) return ForgetAsyncCore(device.PairingSlot);
        return Task.CompletedTask;
    });

    /// <summary>
    /// Deletes the token in a slot, whether or not its device is attached (a phone sold or lost). When an attached
    /// device uses it, closes its channel and opens a fresh one, which asks to pair. Forgetting a slot that holds
    /// nothing does nothing, so a second Forget is not an error.
    /// </summary>
    public Task ForgetSlotAsync(string pairingSlot) => RunAsync(() => ForgetAsyncCore(pairingSlot));

    /// <summary>The slots this PC holds a pairing token in, attached or not, sorted (empty after disposal). Only pairing tokens: other secrets are never listed as paired phones.</summary>
    public async Task<IReadOnlyList<string>> PairedSlotsAsync() =>
        await RunAsync(() => Task.FromResult<IReadOnlyList<string>>([.. _secrets.Slots().Where(PhoneDevice.IsPairingSlot)])) ?? [];

    private async Task ForgetAsyncCore(string slot)
    {
        _secrets.Delete(slot); // never read first: a slot that cannot be read can still be deleted
        _hasToken[slot] = false;
        ForgetName(slot);
        if (_closed) return;
        // Reopen a channel that uses the credential (opened with the token, or paired on it), or that has none open
        // (waiting or failed); an unpaired channel is left alone, so a second Forget changes nothing.
        foreach (var ch in _channels.Values.Where(c => c.Device.PairingSlot == slot).ToList())
            if (ch.HasCredential || ch.Client is null) await ReopenAsync(ch);
    }

    /// <summary>Remembers the choice; off stops the adb watcher (its phones leave), on starts it again.</summary>
    public Task SetAndroidEnabledAsync(bool on) => RunAsync(async () =>
    {
        _settings.Set(AndroidEnabledKey, on ? "true" : "false");
        if (_closed || _directory.Watcher(WatchTransport.Adb) is not { } adb) return;
        if (!on) await adb.StopAsync();
        else if (_started) adb.Start();
    });

    /// <summary>Closes every channel and stops the directory; later calls do nothing.</summary>
    public async ValueTask DisposeAsync()
    {
        if (Interlocked.Exchange(ref _disposed, 1) != 0) return;
        // Closed first, so devices leaving as the watchers stop open nothing.
        await RunAsync(async () =>
        {
            _closed = true;
            foreach (var ch in _channels.Values.ToList()) await CloseChannelAsync(ch);
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
                if (_devices.Contains(a.Device)) break;
                _devices.Add(a.Device);
                _attachments[a.Device.Id] = ++_attachSeq;
                _hasToken.Remove(a.Device.PairingSlot); // read afresh for each attachment
                var ch = new DeviceChannel(a.Device);
                _channels[a.Device.Id] = ch;
                OpenClient(ch);
                break;
            case DeviceChange.Detached d:
                _devices.Remove(d.Device);
                _attachments.Remove(d.Device.Id);
                if (_channels.Remove(d.Device.Id, out var gone)) await CloseChannelAsync(gone);
                if (_activeId == d.Device.Id) _activeId = null;
                break;
        }
        // The active marker stays while its phone is attached; otherwise the first one that can carry the PC's internet.
        _activeId ??= _devices.FirstOrDefault(d => d.CanRoute)?.Id;
    }

    /// <summary>Closes a device's channel and starts a fresh one, clearing its hold, message and back-off.</summary>
    private async Task ReopenAsync(DeviceChannel ch)
    {
        await CloseChannelAsync(ch);
        OpenClient(ch);
    }

    /// <summary>Closes a device's channel, cancels a pending reconnect, and forgets its state.</summary>
    private static async Task CloseChannelAsync(DeviceChannel ch)
    {
        var client = ch.Client;
        ch.Reset();
        if (client is not null) await client.DisposeAsync();
    }

    /// <summary>
    /// Opens a channel to a device with the token its slot holds, if well-formed. Keeps the message (a pairing
    /// failure stays shown across a reconnect). <paramref name="keepState"/>: an unpaired device stays NotPaired while
    /// the fresh channel opens, so the code box stays up.
    /// </summary>
    private void OpenClient(DeviceChannel ch, bool keepState = false)
    {
        ch.CancelReconnect();
        var device = ch.Device;
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
            ch.ClearStatus();
            ch.State = PhoneState.Failed;
            ch.Message = OpenFailedMessage;
            ch.Held = true;
            return;
        }
        ch.Client = client;
        ch.OpenedAt = _time.GetTimestamp();
        ch.HasCredential = _hasToken[device.PairingSlot];
        ch.Welcomed = false;
        if (!keepState) ch.State = ch.UnsentCode is null ? PhoneState.Connecting : PhoneState.Pairing;
        ch.ClearStatus();
        // A code an earlier channel never got to send: this one holds it until its welcome.
        if (ch.UnsentCode is { } code) _ = client.SubmitCodeAsync(code); // completes at once; true on a fresh client
        _readers.RemoveAll(t => t.IsCompleted);
        _readers.Add(Task.Run(async () =>
        {
            await foreach (var e in client.Events.ReadAllAsync()) Post(() => OnClientEventAsync(ch, client, e));
        }));
        _ = client.StartAsync(CancellationToken.None); // never faults; a failed open arrives as Disconnected
    }

    private async Task OnClientEventAsync(DeviceChannel ch, ControlClient client, ControlEvent e)
    {
        // A channel closed since, or a device that left: its events no longer count.
        if (!ReferenceEquals(client, ch.Client) || !_channels.TryGetValue(ch.Device.Id, out var current) || current != ch) return;
        var device = ch.Device;
        switch (e)
        {
            case ControlEvent.Welcomed w:
                // The device is there: the back-off and the last reason start over.
                (ch.Failures, ch.Reason, ch.LastLogged) = (0, null, null);
                ch.Welcomed = true;
                ch.UnsentCode = null; // the client sent a held code with its answer to this welcome
                if (w.Paired)
                {
                    ch.State = PhoneState.Paired;
                    ch.Message = null;
                }
                else if (ch.State != PhoneState.Pairing) ch.State = PhoneState.NotPaired; // a code may already be on its way
                break;
            case ControlEvent.PairedWith p:
                try
                {
                    _secrets.Set(device.PairingSlot, p.Token);
                    _hasToken[device.PairingSlot] = true;
                    ch.HasCredential = true;
                }
                catch (Exception error)
                {
                    // Unsaved, the pairing is lost on the next channel: say so, and stop here, as for a failed proof.
                    ReportError(error);
                    ch.Client = null; // its status and disconnect no longer count
                    ch.ClearStatus();
                    ch.State = PhoneState.Failed;
                    ch.Message = SaveFailedMessage;
                    ch.Held = true;
                    await client.DisposeAsync();
                    break;
                }
                ch.State = PhoneState.Paired;
                ch.Message = null;
                break;
            case ControlEvent.PairingFailed f:
                if (ch.State == PhoneState.Pairing) ch.State = PhoneState.NotPaired;
                ch.Message = Describe(f.Reason, device.Kind.Label());
                if (f.Reason == PairingFailure.Locked)
                {
                    // The phone closes this channel; the code still works on a new one, so open that now (as the Mac does).
                    ch.Client = null;
                    await client.DisposeAsync();
                    OpenClient(ch, keepState: true);
                }
                break;
            case ControlEvent.StatusUpdate s:
                ch.State = PhoneState.Paired; // status flows only on a proved channel
                (ch.Status, ch.Rx, ch.Tx, ch.Connections) = (s.Status, s.Rx, s.Tx, s.Active);
                SaveName(device.PairingSlot, s.Status.DeviceName);
                break;
            case ControlEvent.Goodbye:
                // The phone's user turned Passthrough off; the phone closes next. Logged, as on the Mac.
                WriteLog($"{device.Id} ({device.Kind.Label()}): Passthrough was turned off on the phone");
                break;
            case ControlEvent.Disconnected d:
                ch.Client = null;
                ch.ClearStatus();
                if (d.Error is ControlException failure)
                {
                    // Retrying cannot fix a failed proof or another version; the stored token stays.
                    ch.UnsentCode = null;
                    ch.State = PhoneState.Failed;
                    ch.Message = failure.Message;
                    ch.Held = true;
                    LogClosed(ch, failure.Kind.ToString(), retrying: false);
                }
                else if (d.Error is null && ch.State == PhoneState.NotPaired
                    && _time.GetElapsedTime(ch.OpenedAt) >= ProtocolConstants.UnauthenticatedTimeout / 2)
                {
                    // The phone closes a channel that has not paired within 10 s unless a code is showing. The user may
                    // still be reading the code off the phone: a fresh channel at once, and the box stays (as on the
                    // Mac; not for a channel closed sooner, so something closing channels at once is not looped on).
                    await client.DisposeAsync();
                    OpenClient(ch, keepState: true);
                    break;
                }
                else
                {
                    var category = DisconnectReason.Classify(d.Error);
                    ch.Reason = DisconnectReason.Describe(category, device.Kind);
                    // A code that never reached the phone waits for the next channel: the row stays Pairing.
                    ch.State = ch.UnsentCode is null ? PhoneState.Connecting : PhoneState.Pairing;
                    LogClosed(ch, category.ToString(), retrying: true);
                    ScheduleReconnect(ch);
                }
                await client.DisposeAsync(); // already over; this just waits for its background work
                break;
        }
    }

    private void ScheduleReconnect(DeviceChannel ch)
    {
        ch.CancelReconnect();
        ch.Failures++;
        var seq = ch.ReconnectSeq;
        ch.Reconnect = _time.CreateTimer(_ => Post(() =>
        {
            if (seq == ch.ReconnectSeq && !_closed && !ch.Held && ch.Client is null
                && _channels.TryGetValue(ch.Device.Id, out var current) && current == ch)
                OpenClient(ch);
            return Task.CompletedTask;
        }), null, ReconnectDelay(ch.Failures), Timeout.InfiniteTimeSpan);
    }

    /// <summary>Logs why a device's channel ended, unless that was the last line logged for it.</summary>
    private void LogClosed(DeviceChannel ch, string category, bool retrying)
    {
        var line = $"{ch.Device.Id} ({ch.Device.Kind.Label()}): channel closed: {category}" + (retrying ? "; retrying" : "");
        if (line == ch.LastLogged) return;
        ch.LastLogged = line;
        WriteLog(line);
    }

    private void WriteLog(string line)
    {
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
        var ch = _channels[d.Id];
        return new PhoneEntry(d, ch.State, d.Id == _activeId, ch.Status, ch.Rx, ch.Tx, ch.Connections, ch.Message ?? ch.Reason,
            HasToken(d), AttachmentOf(d), name);
    }

    /// <summary>Whether the device's slot holds a well-formed token (cached, see <see cref="_hasToken"/>); a slot that cannot be read counts as empty and is reported once.</summary>
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
    /// The device's stored token, checked for format before use: anything else in the slot counts as no token (the
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
