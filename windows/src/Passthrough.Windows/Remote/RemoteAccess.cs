using System.Runtime.InteropServices;
using Passthrough.Core.Shell;
using Passthrough.Core.Shell.Access;
using Passthrough.Core.Shell.Serving;
using Passthrough.Core.Shell.Sessions;
using Passthrough.Core.Storage;
using Passthrough.Windows.Iroh;
using Passthrough.Windows.Shell;

namespace Passthrough.Windows.Remote;

/// <summary>Where Remote access is, for the switch and the setup rows.</summary>
public enum RemoteAccessState
{
    Off,
    Starting,
    /// <summary>Phones can reach this PC (directly, or through its relay once <see cref="RemoteAccess.HomeRelay"/> is known).</summary>
    On,
    /// <summary>It can't run here: <see cref="RemoteAccess.Problem"/> says why.</summary>
    Unavailable,
}

/// <summary>
/// Remote access in the tray app (stage 3; the service takes the network side over in stage 4): the switch, this PC's
/// iroh identity, the phones allowed a shell, their sessions and the door they come in by. It is the
/// <see cref="IAccessAdmin"/> the cable side asks what a grant carries and gives the keys phones confirmed.
/// It never runs elevated: a phone's shell would run as administrator.
/// </summary>
public sealed class RemoteAccess : IAccessAdmin, IDisposable
{
    internal const string EnabledSetting = "remoteAccess";
    internal const string SecretKeySlot = "iroh.secretKey";
    internal const string RelayUrlSetting = "relayUrl";
    internal const string RelayTokenSlot = "relay.token";

    private readonly ISettingsStore _settings;
    private readonly ISecretStore _secrets;
    private readonly string _computerName;
    private readonly Action<string>? _log;
    private readonly Lock _lock = new();
    private IrohEndpoint? _endpoint;
    private IrohShellListener? _listener;
    private ShellGate? _gate;
    private RemoteAccessState _state = RemoteAccessState.Off;

    private readonly IrohRelay? _relayOverride;

    /// <param name="relayOverride">For tests: relays off, whatever the settings say.</param>
    public RemoteAccess(ISettingsStore settings, ISecretStore secrets, string transcriptFolder, string computerName, Action<string>? log = null,
        IrohRelay? relayOverride = null)
    {
        _relayOverride = relayOverride;
        _settings = settings;
        _secrets = secrets;
        _computerName = computerName;
        _log = log;
        Access = new ShellAccessStore(secrets, log: log);
        Catalog = ShellCatalog.Discover(new ShellProbe());
        Transcripts = new TranscriptStore(transcriptFolder, log: log);
        PrivateFolder.Restrict(transcriptFolder, log);
        Sessions = new ShellSessionManager(Transcripts, Catalog.Resolve, start => new ConPty(start), UserEnvironment.Create, UserEnvironment.Home, log: log);
        Sessions.Changed += () => _gate?.PushSessions();
        Access.Changed += () => PhonesChanged?.Invoke();
        // Old sessions go as the owner chose, now and every hour (also while Remote access is off).
        _pruner = new Timer(_ => PruneHistory(), null, TimeSpan.FromSeconds(30), TimeSpan.FromHours(1));
    }

    // MARK: History

    internal const string HistoryDaysSetting = "shellHistoryDays";
    /// <summary>What "Keep shell history" offers, in days; 0 is Forever (then only the 2 GB cap applies).</summary>
    public static readonly IReadOnlyList<int> HistoryChoices = [7, 30, 365, 0];
    public const int DefaultHistoryDays = 30;
    private readonly Timer _pruner;

    /// <summary>How many days finished sessions' transcripts are kept (0: forever, within 2 GB).</summary>
    public int HistoryDays
    {
        get => int.TryParse(_settings.Get(HistoryDaysSetting), out var days) && HistoryChoices.Contains(days) ? days : DefaultHistoryDays;
        set
        {
            if (!HistoryChoices.Contains(value)) throw new ArgumentOutOfRangeException(nameof(value));
            _settings.Set(HistoryDaysSetting, value.ToString(System.Globalization.CultureInfo.InvariantCulture));
            PruneHistory();
        }
    }

    /// <summary>Deletes what is past the retention (and past 2 GB, oldest first); a session still recording stays.</summary>
    public int PruneHistory()
    {
        try
        {
            var days = HistoryDays;
            var removed = Transcripts.Prune(days == 0 ? null : DateTimeOffset.UtcNow.AddDays(-days));
            if (removed > 0) _log?.Invoke($"shell: deleted {removed} old session transcript(s)");
            return removed;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { return 0; }
    }

    /// <summary>Deletes every finished session's transcript (Delete shell history); running ones keep recording.</summary>
    public void DeleteHistory() => Transcripts.DeleteFinished();

    // MARK: Relay and identity

    /// <summary>The custom relay's URL, or null for n0's public relays.</summary>
    public string? RelayUrl => _settings.Get(RelayUrlSetting) is { Length: > 0 } url ? url : null;

    /// <summary>Whether a relay token is kept (never shown back).</summary>
    public bool HasRelayToken => _secrets.Get(RelayTokenSlot) is { Length: > 0 };

    /// <summary>
    /// A relay URL Passthrough accepts: https, a host, nothing after the path (no query or fragment, where a token
    /// would end up logged). Null for one that isn't.
    /// </summary>
    public static string? ValidRelayUrl(string? text) =>
        Uri.TryCreate(text?.Trim(), UriKind.Absolute, out var uri) && uri.Scheme == Uri.UriSchemeHttps && uri.Host.Length > 0
        && uri.Query.Length == 0 && uri.Fragment.Length == 0 && uri.UserInfo.Length == 0 ? uri.AbsoluteUri : null;

    /// <summary>
    /// Uses <paramref name="url"/> (null: n0's relays) with <paramref name="token"/> (null: keep the one kept, "" none).
    /// Running, it restarts on the new relay; phones learn it at their next connection and plug-in.
    /// </summary>
    public async Task SetRelayAsync(string? url, string? token)
    {
        string? valid = null;
        if (url is not null && (valid = ValidRelayUrl(url)) is null) throw new ArgumentException("A relay is an https:// address.", nameof(url));
        _settings.Set(RelayUrlSetting, valid ?? "");
        if (valid is null || token is { Length: 0 }) _secrets.Delete(RelayTokenSlot);
        else if (token is not null)
        {
            Passthrough.Core.Logging.LogText.Register(token.Trim());
            _secrets.Set(RelayTokenSlot, token.Trim());
        }
        await RestartAsync().ConfigureAwait(false);
    }

    /// <summary>
    /// A new iroh identity for this PC: every phone's access is taken away (their keys, connections and shells), since
    /// they knew it by the old id. Each gets access again the next time it is plugged in with Remote access on.
    /// </summary>
    public async Task ResetIdentityAsync()
    {
        foreach (var phone in Access.Phones.ToList()) Revoke(phone.PhoneId);
        _secrets.Delete(SecretKeySlot);
        _log?.Invoke("remote access: this PC's identity was reset");
        await RestartAsync().ConfigureAwait(false);
    }

    private async Task RestartAsync()
    {
        if (!Enabled) { Changed?.Invoke(); return; }
        await StopAsync().ConfigureAwait(false);
        await StartAsync().ConfigureAwait(false);
    }

    public ShellAccessStore Access { get; }
    public ShellCatalog Catalog { get; }
    public TranscriptStore Transcripts { get; }
    public ShellSessionManager Sessions { get; }

    /// <summary>Fires, on any thread, when what a grant carries may have changed.</summary>
    public event Action? Changed;

    /// <summary>Fires, on any thread, when the state, the relay or the connected phones change: what the UI shows.</summary>
    public event Action? StatusChanged;

    /// <summary>Fires when the phones with access change.</summary>
    public event Action? PhonesChanged;

    public bool Enabled => _settings.Get(EnabledSetting) == "true";

    public RemoteAccessState State { get { lock (_lock) return _state; } }

    /// <summary>Why it can't run, in the words the setup row shows; null when nothing is wrong.</summary>
    public string? Problem { get; private set; }

    /// <summary>The relay this PC is reachable through now, once known.</summary>
    public string? HomeRelay => _endpoint?.HomeRelay;

    public IReadOnlyList<string> ConnectedPhones => _gate?.ConnectedPhones ?? [];

    /// <summary>Turns Remote access on or off and remembers it. Off drops every phone's connection; their sessions keep running until quit.</summary>
    public Task SetEnabledAsync(bool on)
    {
        _settings.Set(EnabledSetting, on ? "true" : "false");
        return on ? StartAsync() : StopAsync();
    }

    /// <summary>Starts it if the switch is on (at launch).</summary>
    public Task StartIfEnabledAsync() => Enabled ? StartAsync() : Task.CompletedTask;

    private async Task StartAsync()
    {
        lock (_lock)
        {
            if (_state is RemoteAccessState.On or RemoteAccessState.Starting) return;
            _state = RemoteAccessState.Starting;
        }
        StatusChanged?.Invoke();
        try
        {
            if (UserEnvironment.IsElevated()) throw new RemoteAccessException("Passthrough is running as administrator, so it won't host shells: a phone's would run as administrator too. Start it normally.");
            if (!ConPty.IsAvailable) throw new RemoteAccessException("This copy of Passthrough is missing its terminal (conpty.dll). Reinstall it.");
            if (!IrohNative.IsAvailable) throw new RemoteAccessException("This copy of Passthrough is missing its network library (passthrough_iroh.dll). Reinstall it.");
            var key = SecretKey();
            var relay = Relay();
            var endpoint = await Task.Run(() => IrohEndpoint.Bind(key, relay, IrohEndpoint.ShellAlpn)).ConfigureAwait(false);
            var gate = new ShellGate(Sessions, Transcripts, Access, new HandshakeLimiter(TimeSpan.FromSeconds(10), TimeProvider.System), Hooks(endpoint), log: _log);
            var listener = new IrohShellListener(endpoint, gate, _log);
            listener.Failed += _ => { lock (_lock) _state = RemoteAccessState.Unavailable; Problem = "Remote access stopped unexpectedly. Turn it off and on again."; StatusChanged?.Invoke(); };
            lock (_lock)
            {
                if (_state != RemoteAccessState.Starting) { listener.Dispose(); endpoint.Dispose(); return; } // turned off meanwhile
                (_endpoint, _gate, _listener) = (endpoint, gate, listener);
                _state = RemoteAccessState.On;
            }
            Problem = null;
            listener.Start();
            _log?.Invoke("remote access: on");
            StatusChanged?.Invoke();
            Changed?.Invoke();
            // Once it has a home relay, grants carry it: phones away from this network reach it through there.
            _ = Task.Run(() => { if (endpoint.WaitOnline(TimeSpan.FromSeconds(30))) { Changed?.Invoke(); StatusChanged?.Invoke(); } });
        }
        catch (Exception e) when (e is RemoteAccessException or IrohException or IOException or DllNotFoundException or System.ComponentModel.Win32Exception)
        {
            lock (_lock) _state = RemoteAccessState.Unavailable;
            Problem = e is RemoteAccessException ? e.Message : "Remote access couldn't start. See the log for details.";
            _log?.Invoke($"remote access: couldn't start ({e.GetType().Name}: {e.Message})");
            StatusChanged?.Invoke();
        }
    }

    private Task StopAsync()
    {
        IrohShellListener? listener;
        IrohEndpoint? endpoint;
        lock (_lock)
        {
            (listener, endpoint) = (_listener, _endpoint);
            (_listener, _endpoint, _gate) = (null, null, null);
            _state = RemoteAccessState.Off;
        }
        Problem = null;
        listener?.Stop();
        endpoint?.Dispose();
        _log?.Invoke("remote access: off");
        StatusChanged?.Invoke();
        Changed?.Invoke();
        return Task.CompletedTask;
    }

    /// <summary>This PC's iroh secret key: made once and kept, so its id (what phones dial) never changes.</summary>
    private byte[] SecretKey()
    {
        if (_secrets.Get(SecretKeySlot) is { } stored)
        {
            try { if (Convert.FromBase64String(stored) is { Length: 32 } key) return key; }
            catch (FormatException) { }
        }
        var fresh = IrohEndpoint.NewSecretKey();
        _secrets.Set(SecretKeySlot, Convert.ToBase64String(fresh));
        return fresh;
    }

    private IrohRelay Relay()
    {
        // Whatever the log is given, this token never reaches it (LogText removes it by value).
        if (_secrets.Get(RelayTokenSlot) is { Length: > 0 } token) Passthrough.Core.Logging.LogText.Register(token);
        return RelayChoice();
    }

    private IrohRelay RelayChoice() => _relayOverride ??
        (_settings.Get(RelayUrlSetting) is { Length: > 0 } url ? new IrohRelay(url, _secrets.Get(RelayTokenSlot)) : IrohRelay.N0);

    private ShellGateHooks Hooks(IrohEndpoint endpoint) => new()
    {
        MacInfo = () => new ShellEnvelope(ShellEnvelope.MacInfo)
        {
            IrohID = endpoint.Id,
            IrohRelay = endpoint.HomeRelay,
            RelayToken = _settings.Get(RelayUrlSetting) is { Length: > 0 } ? _secrets.Get(RelayTokenSlot) : null,
            Addresses = [.. endpoint.DirectAddresses],
        },
        Host = phone => new HostInfo
        {
            Kind = HostInfo.KindWindows,
            Os = RuntimeInformation.OSDescription,
            SignedIn = true,
            App = true,
            Shells = [.. Catalog.Shells],
            Screens = [],
            Rdp = "service",
            Access = new HostAccess { Shell = true, Screen = Access.ScreenAllowed(phone) },
            Lock = true,
            User = Environment.UserName,
        }.Cleaned(),
        Label = phone => Access.Phones.FirstOrDefault(p => p.PhoneId == phone)?.Label ?? "A phone",
        Lock = _ => Native.LockWorkStation() ? null : ShellError.BadRequest,
        Event = e => _log?.Invoke($"shell: {e}"),
    };

    // MARK: IAccessAdmin

    public Task<GrantContents?> GrantContentsAsync()
    {
        IrohEndpoint? endpoint;
        lock (_lock) endpoint = _state == RemoteAccessState.On ? _endpoint : null;
        if (endpoint is null) return Task.FromResult<GrantContents?>(null);
        var custom = _settings.Get(RelayUrlSetting) is { Length: > 0 };
        return Task.FromResult<GrantContents?>(new GrantContents
        {
            // No listener of its own until stage 4: phones reach this PC over iroh only.
            CertSHA256 = GrantContents.NoListenerPin,
            HostName = _computerName,
            IrohId = endpoint.Id,
            IrohRelay = endpoint.HomeRelay,
            RelayToken = custom ? _secrets.Get(RelayTokenSlot) : null,
            // No addresses before a listener exists: a phone that saw some would try TCP to them (RECONCILIATION).
        });
    }

    public Task<bool> AddKeyAsync(string phoneId, string label, string pairingSlot, ReadOnlyMemory<byte> key) =>
        Task.Run(() => Access.Record(new ShellPhone { PhoneId = phoneId, Label = label, PairingSlot = pairingSlot, Key = key.ToArray(), GrantedAt = DateTimeOffset.UtcNow }));

    public Task RevokeSlotAsync(string pairingSlot) => Task.Run(() =>
    {
        // Keys first, so a reconnect is already refused; then what is connected, and what it opened.
        var (_, removed) = Access.RevokeSlot(pairingSlot);
        foreach (var phone in removed) Disconnect(phone.PhoneId);
    });

    /// <summary>Takes one phone's access away: its key, its connections, its sessions.</summary>
    public void Revoke(string phoneId)
    {
        Access.Revoke(phoneId);
        Disconnect(phoneId);
    }

    /// <summary>Ends a phone's connections and the sessions it opened, keeping its access (Stop).</summary>
    public void Disconnect(string phoneId)
    {
        if (_gate is { } gate) gate.Disconnect(phoneId);
        else Sessions.CloseSessions(phoneId);
        StatusChanged?.Invoke();
    }

    public void SetScreenAllowed(string phoneId, bool allowed)
    {
        Access.SetScreenAllowed(phoneId, allowed);
        _gate?.PushHost();
    }

    public void Dispose()
    {
        _pruner.Dispose();
        StopAsync();
        Sessions.CloseAll();
    }

    private static class Native
    {
        [DllImport("user32.dll", SetLastError = true)]
        public static extern bool LockWorkStation();
    }
}

/// <summary>Remote access can't start, for a reason the person can act on.</summary>
public sealed class RemoteAccessException(string message) : Exception(message);
