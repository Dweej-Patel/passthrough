using System.Runtime.InteropServices;
using Passthrough.Core.Pipe;
using Passthrough.Core.Setup;
using Passthrough.Core.Shell;
using Passthrough.Core.Shell.Access;
using Passthrough.Core.Shell.Serving;
using Passthrough.Core.Shell.Sessions;
using Passthrough.Core.Storage;
using Passthrough.Windows.Pipes;
using Passthrough.Windows.Setup;
using Passthrough.Windows.Shell;

namespace Passthrough.Windows.Remote;

/// <summary>Where Remote access is, for the switch and the setup rows.</summary>
public enum RemoteAccessState
{
    Off,
    /// <summary>Not set up on this PC yet (or set up by stage 3, in the app): Turn on installs the background service.</summary>
    NeedsSetup,
    Starting,
    /// <summary>Phones can reach this PC through the service (directly, or through its relay once <see cref="RemoteAccess.HomeRelay"/> is known).</summary>
    On,
    /// <summary>It can't run here: <see cref="RemoteAccess.Problem"/> says why.</summary>
    Unavailable,
}

/// <summary>
/// Remote access in the tray app, from stage 4: the background service faces the network and holds the phones' keys;
/// this app runs the account's shells (ConPTY, as the user, never elevated) and serves them to the service over the
/// pipe. The switch installs the service or turns it off (one administrator prompt each). Settings reads and changes
/// the phones with access through the service. It is the <see cref="IAccessAdmin"/> the cable side asks what a grant
/// carries and gives the keys phones confirmed: both go to the service.
/// </summary>
public sealed class RemoteAccess : IAccessAdmin, IDisposable
{
    // Stage 3's settings and secrets in this account's own store: carried into the service once, then deleted.
    internal const string EnabledSetting = "remoteAccess";
    internal const string SecretKeySlot = "iroh.secretKey";
    internal const string RelayUrlSetting = "relayUrl";
    internal const string RelayTokenSlot = "relay.token";

    private readonly ISettingsStore _settings;
    private readonly ISecretStore _secrets;
    private readonly Action<string>? _log;
    private readonly Lock _lock = new();
    private readonly PipeSessionServer _server;
    private readonly PipeAccessAdmin _admin;
    private ServiceLink? _link;
    private IReadOnlyList<PipeDevice> _phones = [];
    private GrantContents? _grant;
    private string? _problem;
    private bool _busy;

    public RemoteAccess(ISettingsStore settings, ISecretStore secrets, string transcriptFolder, string computerName, Action<string>? log = null)
    {
        _settings = settings;
        _secrets = secrets;
        _log = log;
        Catalog = ShellCatalog.Discover(new ShellProbe());
        Transcripts = new TranscriptStore(transcriptFolder, log: log);
        PrivateFolder.Restrict(transcriptFolder, log);
        Sessions = new ShellSessionManager(Transcripts, Catalog.Resolve, start => new ConPty(start), UserEnvironment.Create, UserEnvironment.Home, log: log);
        Host = new LocalSessionHost(Sessions, Transcripts);
        _server = new PipeSessionServer(Host, HostStateNow, LockScreen, log);
        _admin = new PipeAccessAdmin(_server);
        _admin.Changed += () => _ = RefreshGrantAsync();
        _admin.AccessChanged += () => _ = RefreshPhonesAsync();
        _admin.NoticesChanged += () => _ = RefreshNoticesAsync();
        Reach = new Passthrough.Core.Trust.ComputerReachStore(secrets, new Passthrough.Windows.Trust.HelloSigner());
        _server.SavePass = KeepPassAsync;
        _ = Task.Run(async () =>
        {
            // Only with Windows Hello can this PC keep access to other computers; then phones are told its identity key.
            _canKeep = await new Passthrough.Windows.Trust.HelloSigner().IsAvailableAsync().ConfigureAwait(false);
            _server.PushState();
        });
        _server.LinkChanged += linked =>
        {
            if (linked) _ = Task.Run(AfterLinkAsync);
            StatusChanged?.Invoke();
        };
        // Old sessions go as the owner chose, now and every hour (also while Remote access is off).
        _pruner = new Timer(_ => PruneHistory(), null, TimeSpan.FromSeconds(30), TimeSpan.FromHours(1));
    }

    public ShellCatalog Catalog { get; }
    public TranscriptStore Transcripts { get; }
    public ShellSessionManager Sessions { get; }
    public LocalSessionHost Host { get; }

    /// <summary>Fires, on any thread, when what a grant carries may have changed.</summary>
    public event Action? Changed;

    /// <summary>Fires, on any thread, when the state, the relay or the connected phones change: what the UI shows.</summary>
    public event Action? StatusChanged;

    /// <summary>
    /// Fires, after Turn on installed the service, with the launcher (the installed exe at the path that never changes):
    /// this copy should start the installed one with <c>--launch --handoff &lt;pid&gt;</c> and quit.
    /// </summary>
    public event Action<string>? HandOffWanted;

    /// <summary>Fires when the phones with access change.</summary>
    public event Action? PhonesChanged;

    // MARK: History (the transcripts stay in this account's profile; the service never reads them)

    internal const string HistoryDaysSetting = "shellHistoryDays";
    /// <summary>What "Keep shell history" offers, in days; 0 is Forever (then only the 2 GB cap applies).</summary>
    public static readonly IReadOnlyList<int> HistoryChoices = [7, 30, 365, 0];
    public const int DefaultHistoryDays = 30;
    private readonly Timer _pruner;

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

    public void DeleteHistory() => Transcripts.DeleteFinished();

    // MARK: The service

    /// <summary>The service is installed and Remote access turned on (HKLM, every account reads it).</summary>
    public bool Enabled => WindowsMachineRegistry.Read() is { Enabled: true };

    /// <summary>Installed (on or off).</summary>
    public static bool IsInstalled => WindowsMachineRegistry.Read() is not null;

    public RemoteAccessState State
    {
        get
        {
            lock (_lock) if (_busy) return RemoteAccessState.Starting;
            if (_problem is not null) return RemoteAccessState.Unavailable;
            if (WindowsMachineRegistry.Read() is not { } installed) return RemoteAccessState.NeedsSetup;
            if (!installed.Enabled) return RemoteAccessState.Off;
            return _link?.State switch
            {
                ServiceLinkState.Linked => RemoteAccessState.On,
                ServiceLinkState.Refused or ServiceLinkState.Impostor or ServiceLinkState.NotRunning => RemoteAccessState.Unavailable,
                _ => RemoteAccessState.Starting,
            };
        }
    }

    /// <summary>Why it can't run, in the words the setup row shows; null when nothing is wrong.</summary>
    public string? Problem => _problem ?? (_link?.State switch
    {
        ServiceLinkState.NotRunning => "Remote access isn't running. Turn it off and on again.",
        ServiceLinkState.Impostor => "Another program is answering for Passthrough's service. Restart this PC; if it comes back, see the log.",
        ServiceLinkState.Refused => _link.Refusal switch
        {
            PipeRefused.ReasonVersion => "Finish the update: turn Remote access off and on again from this copy.",
            PipeRefused.ReasonNotAllowed => "Remote access on this PC is set up for another account. An administrator can add yours by turning it on here.",
            PipeRefused.ReasonElevated => "Passthrough can't host shells when it runs as administrator. Close it and open it normally.",
            var other => $"The background service refused this copy of Passthrough ({other}).",
        },
        _ => null,
    });

    /// <summary>Stage 3 had Remote access on in this app: Turn on finishes moving it into the service.</summary>
    public bool NeedsFinishing => !IsInstalled && _settings.Get(EnabledSetting) == "true";

    /// <summary>The relay this PC is reachable through now, once known.</summary>
    public string? HomeRelay => _grant?.IrohRelay;

    public IReadOnlyList<PipeDevice> Phones { get { lock (_lock) return _phones; } }

    public IReadOnlyList<string> ConnectedPhones => [.. Phones.Where(p => p.Connections > 0).Select(p => p.Phone)];

    /// <summary>At launch: connects to the service when it is installed and on.</summary>
    public Task StartIfEnabledAsync()
    {
        if (UserEnvironment.IsElevated())
        {
            _problem = "Passthrough can't host shells when it runs as administrator. Close it and open it normally.";
            StatusChanged?.Invoke();
            return Task.CompletedTask;
        }
        if (_link is null)
        {
            var build = typeof(RemoteAccess).Assembly.GetCustomAttributes(typeof(System.Reflection.AssemblyInformationalVersionAttribute), false)
                .OfType<System.Reflection.AssemblyInformationalVersionAttribute>().FirstOrDefault()?.InformationalVersion ?? "dev";
            _link = new ServiceLink(_server, build, _log);
            _link.Changed += () => StatusChanged?.Invoke();
            _link.Start();
        }
        return Task.CompletedTask;
    }

    /// <summary>
    /// Turns Remote access on (installs or repairs the service, carrying over stage 3's relay, behind one prompt) or
    /// off. Returns what the person is told (null when it worked).
    /// </summary>
    public async Task<string?> SetEnabledAsync(bool on)
    {
        lock (_lock)
        {
            if (_busy) return null;
            _busy = true;
        }
        StatusChanged?.Invoke();
        try
        {
            SetupResult result;
            if (on)
            {
                var exe = Path.Combine(AppContext.BaseDirectory, ServiceDefinition.ExeName);
                if (!File.Exists(exe) || !File.Exists(Path.Combine(AppContext.BaseDirectory, ServiceDefinition.ManifestName)))
                    return "This copy of Passthrough can't set up its background service. Build it with scripts/build-windows.ps1, then turn Remote access on from that copy.";
                var input = new SetupInput
                {
                    RelayUrl = _settings.Get(RelayUrlSetting) is { Length: > 0 } url ? url : null,
                    RelayToken = _settings.Get(RelayUrlSetting) is { Length: > 0 } ? _secrets.Get(RelayTokenSlot) : null,
                };
                result = await ElevatedSetup.RunAsync(exe, [IsInstalled ? "--update" : "--install"], input, _ => { }, _log).ConfigureAwait(false);
                if (result.Result == SetupResult.Ok)
                {
                    // The service has the relay now; this account's copies go.
                    _settings.Set(RelayUrlSetting, "");
                    _secrets.Delete(RelayTokenSlot);
                    _settings.Set(EnabledSetting, "false");
                    await StartIfEnabledAsync().ConfigureAwait(false);
                    // From here the installed copy is this account's Passthrough: this one hands over to it.
                    if (InstalledExe() is { } launcher) HandOffWanted?.Invoke(launcher);
                }
            }
            else
            {
                if (InstalledExe() is not { } installed) return null;
                result = await ElevatedSetup.RunAsync(installed, ["--off"], new SetupInput(), _ => { }, _log).ConfigureAwait(false);
            }
            return Sentence(result);
        }
        finally
        {
            lock (_lock) _busy = false;
            StatusChanged?.Invoke();
            Changed?.Invoke();
        }
    }

    /// <summary>The service's exe at the path that never changes, when installed.</summary>
    private static string? InstalledExe() =>
        WindowsMachineRegistry.Read() is { InstallFolder: { Length: > 0 } folder } && Path.GetDirectoryName(folder.TrimEnd('\\')) is { } root
        && File.Exists(Path.Combine(root, ServiceDefinition.ExeName)) ? Path.Combine(root, ServiceDefinition.ExeName) : null;

    private static string? Sentence(SetupResult result) => result.Result switch
    {
        SetupResult.Ok => null,
        SetupResult.Declined => "Nothing was changed.",
        _ when result.FailedStep is null => result.Error ?? "The setup stopped without saying why. See the log.",
        _ => $"Setting up stopped at {result.FailedStep}: {result.Error} " + (result.Undone ? "What it had changed was put back." : "Some of it could not be put back; see the log."),
    };

    // MARK: Relay and identity (machine-wide: each costs one administrator prompt)

    /// <summary>The relay set before the service held it (stage 3), until Turn on carries it over.</summary>
    public string? RelayUrl => _settings.Get(RelayUrlSetting) is { Length: > 0 } url ? url : null;

    public bool HasRelayToken => _secrets.Get(RelayTokenSlot) is { Length: > 0 };

    public static string? ValidRelayUrl(string? text) =>
        text?.Trim() is { } trimmed && SetupPlans.IsRelayUrl(trimmed) && Uri.TryCreate(trimmed, UriKind.Absolute, out var uri) ? uri.AbsoluteUri : null;

    /// <summary>
    /// Uses <paramref name="url"/> (null: n0's relays) with <paramref name="token"/> (null: keep it, "" none). Installed:
    /// the service is told, behind one prompt. Returns the sentence to show, or null when it worked.
    /// </summary>
    public async Task<string?> SetRelayAsync(string? url, string? token)
    {
        string? valid = null;
        if (url is not null && (valid = ValidRelayUrl(url)) is null) throw new ArgumentException("A relay is an https:// address.", nameof(url));
        if (InstalledExe() is not { } installed)
        {
            _settings.Set(RelayUrlSetting, valid ?? "");
            if (valid is null || token is { Length: 0 }) _secrets.Delete(RelayTokenSlot);
            else if (token is not null) _secrets.Set(RelayTokenSlot, token.Trim());
            return null;
        }
        var result = await ElevatedSetup.RunAsync(installed, ["--configure", "relay"], new SetupInput { RelayUrl = valid ?? "", RelayToken = token?.Trim() }, _ => { }, _log)
            .ConfigureAwait(false);
        Changed?.Invoke();
        return Sentence(result);
    }

    /// <summary>A new identity for this PC (one prompt): every phone's access goes, since they knew it by the old one.</summary>
    public async Task<string?> ResetIdentityAsync()
    {
        if (InstalledExe() is not { } installed) return "Remote access isn't set up on this PC.";
        var result = await ElevatedSetup.RunAsync(installed, ["--configure", "reset-identity"], new SetupInput(), _ => { }, _log).ConfigureAwait(false);
        Changed?.Invoke();
        return Sentence(result);
    }

    // MARK: Once linked

    /// <summary>
    /// The first time this account links: stage 3's phone records go to the service (records only: RECONCILIATION),
    /// and this account's copies of them and of its iroh key are deleted once the service has them.
    /// </summary>
    private async Task AfterLinkAsync()
    {
        var old = new ShellAccessStore(_secrets, log: _log);
        if (old.Phones is { Count: > 0 } records)
        {
            var reply = await _admin.HandOverAsync(records).ConfigureAwait(false);
            if (reply.Error is null)
            {
                foreach (var phone in records) old.Revoke(phone.PhoneId);
                _log?.Invoke($"remote access: handed {reply.Taken?.Count ?? 0} phone record(s) to the service; {reply.Refused?.Count ?? 0} belong to another account");
            }
            else _log?.Invoke($"remote access: couldn't hand the phones to the service ({reply.Error})");
        }
        if (_secrets.Get(SecretKeySlot) is not null)
        {
            // The service has an identity of its own; phones that knew this one need the cable once.
            _secrets.Delete(SecretKeySlot);
            _log?.Invoke("remote access: deleted this account's old iroh identity");
        }
        await RefreshPhonesAsync().ConfigureAwait(false);
        await RefreshGrantAsync().ConfigureAwait(false);
    }

    private async Task RefreshPhonesAsync()
    {
        var phones = await _admin.ListAsync().ConfigureAwait(false);
        lock (_lock) _phones = phones;
        PhonesChanged?.Invoke();
        StatusChanged?.Invoke();
    }

    private async Task RefreshGrantAsync()
    {
        _grant = await _admin.GrantContentsAsync().ConfigureAwait(false);
        Changed?.Invoke();
        StatusChanged?.Invoke();
    }

    private PipeHostState HostStateNow() => new()
    {
        Shells = [.. Catalog.Shells],
        User = Environment.UserName,
        IdKey = _canKeep && Identity() is { } identity ? Convert.ToHexStringLower(identity.PublicKey) : null, // lowercase hex, as host.idKey is on the wire
    };

    private volatile bool _canKeep;
    private Passthrough.Windows.Trust.CngComputerIdentity? _identity;

    /// <summary>The computers this PC can reach (stage 7 a.5), sealed behind Windows Hello.</summary>
    public Passthrough.Core.Trust.ComputerReachStore Reach { get; }

    /// <summary>This account's identity key as a viewer, made on first need.</summary>
    public Passthrough.Core.Trust.IComputerIdentity? Identity()
    {
        try { return _identity ??= Passthrough.Windows.Trust.CngComputerIdentity.LoadOrCreate(); }
        catch (System.Security.Cryptography.CryptographicException e) { _log?.Invoke($"trust: no identity key ({e.HResult:X8})"); return null; }
    }

    /// <summary>A new shell on another computer this PC can reach, in a terminal (its own connection, signed with this PC's identity).</summary>
    public Task OpenShellAsync(Passthrough.Core.Trust.ReachableComputer computer) =>
        Identity() is { } identity ? Passthrough.Windows.Client.TermBridge.OpenAsync(computer, identity, null, _log) : Task.CompletedTask;

    /// <summary>Fires when this PC was handed access to another computer.</summary>
    public event Action<string>? ComputerReceived;

    /// <summary>A phone handed this account access to another computer: kept behind Windows Hello, after one confirmation.</summary>
    private async Task<string?> KeepPassAsync(PipeMessage m)
    {
        if (m.Pass is not { } pass) return ShellError.BadRequest.ToWire();
        var result = await Reach.SaveAsync(new Passthrough.Core.Trust.ReachableComputer
        {
            Credential = pass, HostKind = m.HostKind, Scopes = m.Scopes ?? [], Pending = m.Pending, From = m.Label, FromPhoneId = m.Phone,
            ReceivedAt = DateTimeOffset.UtcNow,
        }).ConfigureAwait(false);
        switch (result)
        {
            case Passthrough.Core.Trust.ComputerReachStore.SaveResult.Saved:
                _log?.Invoke("trust: kept access to another computer");
                ComputerReceived?.Invoke(pass.MacName);
                return null;
            case Passthrough.Core.Trust.ComputerReachStore.SaveResult.Conflict:
                return ShellError.PassConflict.ToWire();
            case Passthrough.Core.Trust.ComputerReachStore.SaveResult.NotUsable:
                return ShellError.BadRequest.ToWire();
            default:
                return ShellError.PassNotSaved.ToWire();
        }
    }

    private static ShellError? LockScreen() => Native.LockWorkStation() ? null : ShellError.BadRequest;

    // MARK: IAccessAdmin

    public async Task<GrantContents?> GrantContentsAsync() => _server.IsLinked ? await _admin.GrantContentsAsync().ConfigureAwait(false) : null;

    public async Task<bool> AddKeyAsync(string phoneId, string label, string pairingSlot, ReadOnlyMemory<byte> key)
    {
        var added = await _admin.AddKeyAsync(phoneId, label, pairingSlot, key).ConfigureAwait(false);
        await RefreshPhonesAsync().ConfigureAwait(false);
        return added;
    }

    public async Task RevokeSlotAsync(string pairingSlot)
    {
        await _admin.RevokeSlotAsync(pairingSlot).ConfigureAwait(false);
        await RefreshPhonesAsync().ConfigureAwait(false);
    }

    /// <summary>Takes one phone's access away: its key, its connections, its sessions.</summary>
    public async Task RevokeAsync(string phoneId)
    {
        await _admin.RevokeAsync(phoneId).ConfigureAwait(false);
        Sessions.CloseSessions(phoneId);
        await RefreshPhonesAsync().ConfigureAwait(false);
    }

    /// <summary>Ends a phone's connections and the sessions it opened, keeping its access (Stop).</summary>
    public async Task DisconnectAsync(string phoneId)
    {
        await _admin.DisconnectAsync(phoneId).ConfigureAwait(false);
        Sessions.CloseSessions(phoneId);
        await RefreshPhonesAsync().ConfigureAwait(false);
    }

    private IReadOnlyList<PipeNotice> _notices = [];

    /// <summary>What the service wants the person at the PC to know, until they answer it.</summary>
    public IReadOnlyList<PipeNotice> Notices { get { lock (_lock) return _notices; } }

    /// <summary>Fires, on any thread, when <see cref="Notices"/> changes.</summary>
    public event Action? NoticesChanged;

    private async Task RefreshNoticesAsync()
    {
        var notices = await _admin.NoticesAsync().ConfigureAwait(false);
        lock (_lock) _notices = notices;
        NoticesChanged?.Invoke();
    }

    /// <summary>Answers a notice: OK, or its action first (Allow screen: the phone may see the screen).</summary>
    public async Task AnswerNoticeAsync(PipeNotice notice, bool act)
    {
        if (act && notice.Kind == PipeNotice.Granted && notice.Subject is { } phone) await SetScreenAllowedAsync(phone, true).ConfigureAwait(false);
        await _admin.AnswerNoticeAsync(notice.Id).ConfigureAwait(false);
        await RefreshNoticesAsync().ConfigureAwait(false);
    }

    /// <summary>The Screen row for this account, from the service.</summary>
    public async Task<PipeScreenRow?> ScreenRowAsync() => (await _admin.ScreenAsync().ConfigureAwait(false)).ScreenRow;

    /// <summary>
    /// Screen's setup, its consent for this account, and the owner's choices about an open Remote Desktop: one
    /// administrator prompt each (<c>--configure screen</c>, <c>screen-close</c>, <c>screen-open</c>).
    /// </summary>
    public async Task<string?> ConfigureScreenAsync(string what)
    {
        if (InstalledExe() is not { } installed) return "Remote access isn't set up on this PC.";
        var result = await ElevatedSetup.RunAsync(installed, ["--configure", what], new SetupInput(), _ => { }, _log).ConfigureAwait(false);
        StatusChanged?.Invoke();
        return Sentence(result);
    }

    public Task<PipeAdminReply> StopScreenAsync(string phoneId) => _admin.StopScreenAsync(phoneId);

    /// <summary>"May share access with other computers" for a phone (stage 7).</summary>
    public async Task SetMayShareAsync(string phoneId, bool on)
    {
        await _admin.SetMayShareAsync(phoneId, on).ConfigureAwait(false);
        await RefreshPhonesAsync().ConfigureAwait(false);
    }

    /// <summary>Stay awake while plugged in and the sleep timer, from the service.</summary>
    public Task<PipeAdminReply> PowerAsync() => _admin.PowerAsync();

    public Task<PipeAdminReply> SetStayAwakeAsync(bool on) => _admin.SetStayAwakeAsync(on);

    public async Task SetScreenAllowedAsync(string phoneId, bool allowed)
    {
        await _admin.SetScreenAsync(phoneId, allowed).ConfigureAwait(false);
        await RefreshPhonesAsync().ConfigureAwait(false);
    }

    public void Dispose()
    {
        _pruner.Dispose();
        _link?.Dispose();
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
