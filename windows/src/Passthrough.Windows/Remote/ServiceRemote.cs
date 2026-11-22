using System.Runtime.InteropServices;
using Passthrough.Core.Pipe;
using Passthrough.Core.Shell;
using Passthrough.Core.Shell.Access;
using Passthrough.Core.Shell.Serving;
using Passthrough.Core.Storage;
using Passthrough.Windows.Iroh;
using Passthrough.Windows.Net;
using Passthrough.Windows.Power;
using Passthrough.Windows.Storage;

namespace Passthrough.Windows.Remote;

/// <summary>
/// The network side of Remote access, in the service (stage 4 plan, sections 6 and 8): the phones' keys per Windows
/// account, the service's own iroh identity (never one a user's programs could have read or planted: RECONCILIATION),
/// the gate, and the iroh door. Each proven phone reaches the shells of the account that owns it, through that
/// account's tray app.
/// </summary>
public sealed class ServiceRemote : IDisposable
{
    public const string IrohKeySlot = "iroh.key";
    public const string RelayTokenSlot = "relay.token";

    private readonly ISecretStore _secrets;
    private readonly ITrayHosts _trays;
    private readonly Func<string?> _relayUrl;
    private readonly string _hostName;
    private readonly Action<string> _log;
    private IrohEndpoint? _endpoint;
    private IrohShellListener? _listener;
    private readonly IrohRelay? _relayOverride;
    private readonly TlsOptions? _tls;
    private readonly LocalAdapters _adapters = new();
    private ServiceIdentity? _identity;
    private TlsListener? _tlsListener;
    private DnsSd? _dnsSd;
    private readonly PowerRequest? _connectedRequest, _awakeRequest;
    private readonly Timer _power;
    private DateTime _lastConnected = DateTime.MinValue;
    internal const string StayAwakeSlot = "settings.stayAwake";
    /// <summary>How long the PC is kept awake after the last phone goes.</summary>
    private static readonly TimeSpan AwakeAfterLast = TimeSpan.FromSeconds(60);

    /// <summary>Where the TLS identity lives and how the door is opened (null: no listener on the network, as on Windows 10).</summary>
    public sealed record TlsOptions(string CertificateFile, string KeyName = ServiceIdentity.KeyName, int Port = RemoteShell.DefaultPort, bool Advertise = true);

    /// <summary>Why the local path isn't open, in the words the setup row shows; null when it is (or wasn't asked for).</summary>
    public string? NetworkProblem { get; private set; }

    public ServiceRemote(ISecretStore secrets, string installFolder, ITrayHosts trays, Func<string?> relayUrl, Action<string> log, string? hostName = null, IrohRelay? relayOverride = null,
        TlsOptions? tls = null, Func<Passthrough.Core.Screen.RemoteDesktopSetup?>? screenSetup = null,
        Func<IReadOnlyCollection<string>>? allowedAccounts = null)
    {
        _secrets = secrets;
        _trays = trays;
        _relayUrl = relayUrl;
        _log = log;
        _hostName = hostName ?? HostName.Current();
        _tls = tls;
        _relayOverride = relayOverride;
        Directory = new AccessDirectory(_secrets, log: log);
        if (allowedAccounts is not null) Directory.IsAllowed = account => allowedAccounts().Contains(account, StringComparer.OrdinalIgnoreCase);
        IrohEndpoint.UseLibraryIn(installFolder);
        // Screen through Remote Desktop, when it is set up (install.json's rdp); a PC without it answers rdp_unavailable.
        RemoteDesktop = screenSetup is null ? null : new Passthrough.Windows.Screen.RemoteDesktopGate(screenSetup, IsWorkAccount, log);
        Gate = new ShellGate(HostFor, Directory, new HandshakeLimiter(TimeSpan.FromSeconds(10), TimeProvider.System), Hooks(), log: log);
        Gate.RelayRate.LockoutThreshold = LockoutThreshold();
        Notices.Changed += account =>
        {
            if (account is null) trays.TellAll(new PipeAdminEvent { What = PipeAdminEvent.Notice });
            else trays.Tell(account, new PipeAdminEvent { What = PipeAdminEvent.Notice });
        };
        Admin = new PipeAdminHandler(Directory, Grant, ConnectionsOf, Disconnect, log)
        {
            Board = Notices,
            PowerState = () => (StayAwake, SleepAfter(), PowerFacts.OnMains),
            EndScreen = (phone, reason) => Gate.DisconnectScreen(phone, reason),
            ScreenRow = account => RemoteDesktop?.Verdict(account) is { } v ? new PipeScreenRow(v.Rdp, v.RowState, v.Text, v.Action, v.Reason) : null,
            SetStayAwake = on =>
            {
                _secrets.Set(StayAwakeSlot, on ? "true" : "false");
                _log($"power: Stay awake while plugged in {(on ? "on" : "off")}");
                UpdatePower();
                Gate.PushHost();
            },
        };
        try
        {
            _connectedRequest = new PowerRequest("A phone is connected to this PC through Passthrough.");
            _awakeRequest = new PowerRequest("Stay awake while plugged in is on in Passthrough.");
        }
        catch (System.ComponentModel.Win32Exception e) { _log($"power: no power requests ({e.NativeErrorCode})"); }
        _power = new Timer(_ => UpdatePower(), null, TimeSpan.FromSeconds(5), TimeSpan.FromSeconds(5));
        trays.Changed += host =>
        {
            Gate.PushSessions(host);
            Gate.PushHost(host);
            Gate.PushState();
        };
        Directory.Replaced += Disconnect;
        Directory.Changed += account =>
        {
            trays.Tell(account, new PipeAdminEvent { What = PipeAdminEvent.Access });
            // What each phone may do is in host.access: a connected phone hears a change to Screen or Share at once.
            Gate.PushHost();
        };
    }

    public AccessDirectory Directory { get; }

    /// <summary>What the person at the PC should know, until they answer it.</summary>
    public NoticeBoard Notices { get; } = new();

    private DateTime _lastExposureCheck = DateTime.MinValue;
    private string? _lastVerdict;

    /// <summary>
    /// Every minute: is Remote Desktop open to the network where Passthrough promised it isn't? The notice follows.
    /// What phones are told (<c>host</c>'s <c>rdp</c>) is logged when it changes, with the read that failed if one did.
    /// </summary>
    private void CheckExposure()
    {
        if (DateTime.UtcNow - _lastExposureCheck < TimeSpan.FromSeconds(60)) return;
        _lastExposureCheck = DateTime.UtcNow;
        if (RemoteDesktop is null)
        {
            LogVerdict("screen: Screen isn't set up on this PC");
            return;
        }
        var verdict = RemoteDesktop.Verdict(null);
        var failed = RemoteDesktop.Facts().FailedRead;
        LogVerdict($"screen: Remote Desktop is {verdict.Rdp}{(verdict.Reason is { } why ? $": {why}" : "")}{(failed is null ? "" : $" (couldn't read {failed})")}");
        Notices.Exposed(Directory.Accounts, verdict.Rdp == Passthrough.Core.Screen.RemoteDesktopVerdict.Exposed ? verdict.Reason ?? "" : null);
    }

    private void LogVerdict(string line)
    {
        if (line == _lastVerdict) return;
        _lastVerdict = line;
        _log(line);
    }

    /// <summary>This PC's Remote Desktop, when Screen is set up.</summary>
    public Passthrough.Windows.Screen.RemoteDesktopGate? RemoteDesktop { get; }

    /// <summary>An Entra (work) account, from its SID alone: no tray app is needed to know it.</summary>
    internal static bool IsWorkAccount(string? sid) => sid?.StartsWith("S-1-12-1-", StringComparison.Ordinal) == true;

    /// <summary>Windows' account lockout threshold (0: none), so the relay's cap stays below it.</summary>
    private static int LockoutThreshold()
    {
        if (NetUserModalsGet(null, 3, out var buffer) != 0) return 0;
        try { return Marshal.ReadInt32(buffer, 8); } // USER_MODALS_INFO_3: duration, observation window, threshold
        finally { NetApiBufferFree(buffer); }
    }

    [DllImport("netapi32.dll", CharSet = CharSet.Unicode)]
    private static extern int NetUserModalsGet(string? server, int level, out IntPtr buffer);

    [DllImport("netapi32.dll")]
    private static extern int NetApiBufferFree(IntPtr buffer);

    /// <summary>This PC's iroh id, and where a phone on this PC reaches it (for tests).</summary>
    internal string? IrohId => _endpoint?.Id;
    internal IReadOnlyList<string> LoopbackAddresses => _endpoint?.LoopbackAddresses ?? [];
    public ShellGate Gate { get; }
    public PipeAdminHandler Admin { get; }

    /// <summary>A phone nobody granted reaches no account: its proof fails before this matters.</summary>
    private ISessionHost HostFor(string phoneId) => _trays.HostFor(Directory.Owner(phoneId) ?? "none");

    private PipeSessionHost? OwnerHost(string phoneId) => Directory.Owner(phoneId) is { } owner ? _trays.HostFor(owner) : null;

    private int ConnectionsOf(string phoneId) => Gate.ConnectedPhones.Count(p => p == phoneId);

    /// <summary>
    /// Ends a phone's or computer's connections and the sessions it opened. Its access is already gone by now (taken
    /// first, so a reconnect is refused), so its owner can't be looked up: its sessions are closed on every account's
    /// shells (an id belongs to one account; the others have none of its).
    /// </summary>
    private void Disconnect(string phoneId)
    {
        Gate.Disconnect(phoneId);
        foreach (var host in _trays.Hosts) host.CloseSessions(phoneId);
    }

    public void Start()
    {
        StartTls();
        if (!IrohEndpoint.IsAvailable)
        {
            _log("iroh: the bridge is missing from the install; phones can't connect from anywhere");
            return;
        }
        try
        {
            var relay = _relayOverride ?? (_relayUrl() is { Length: > 0 } url ? new IrohRelay(url, _secrets.Get(RelayTokenSlot)) : IrohRelay.N0);
            if (_secrets.Get(RelayTokenSlot) is { Length: > 0 } token) Passthrough.Core.Logging.LogText.Register(token);
            _endpoint = IrohEndpoint.Bind(SecretKey(), relay, IrohEndpoint.ShellAlpn);
            _listener = new IrohShellListener(_endpoint, Gate, _log);
            _listener.Failed += _ => _log("iroh: the listener stopped");
            _listener.Start();
            var endpoint = _endpoint;
            _ = Task.Run(() =>
            {
                if (endpoint.WaitOnline(TimeSpan.FromSeconds(30))) _trays.TellAll(new PipeAdminEvent { What = PipeAdminEvent.Grant });
            });
        }
        catch (Exception e) when (e is IrohException or IOException or DllNotFoundException)
        {
            _log($"iroh: couldn't start ({e.GetType().Name})");
        }
    }

    public bool StayAwake => _secrets.Get(StayAwakeSlot) == "true";

    /// <summary>What <c>host.sleepAfter</c> says: the sleep timer on the current power source, 0 while Stay awake holds it.</summary>
    private static int SleepAfter(bool stayAwake) => GoingAway.SleepAfter(PowerFacts.SleepAfterSeconds() ?? 0, PowerFacts.OnMains, stayAwake);

    private int SleepAfter() => SleepAfter(StayAwake);

    /// <summary>
    /// While a phone is connected (and for a minute after), the idle timer is held off; while Stay awake is on and the
    /// PC is on mains, too. Nothing in the power plan is changed, so there's nothing to put back.
    /// </summary>
    private void UpdatePower()
    {
        CheckExposure();
        if (Gate.ConnectedPhones.Count > 0) _lastConnected = DateTime.UtcNow;
        _connectedRequest?.Set(DateTime.UtcNow - _lastConnected < AwakeAfterLast);
        _awakeRequest?.Set(StayAwake && PowerFacts.OnMains);
    }

    /// <summary>
    /// Windows is about to sleep, shut down, or Remote access is being turned off: phones are told why, within the
    /// limit, and their connections closed. Before sleep the DNS-SD record goes too. Null reason: say nothing.
    /// </summary>
    public async Task GoingAwayAsync(GoingAway.Signal signal, bool enabled, bool updating)
    {
        if (GoingAway.For(signal, enabled, updating) is not { } going) return;
        if (signal == GoingAway.Signal.Suspend) _dnsSd?.Withdraw();
        _log($"service: telling phones {going.Reason}");
        await Gate.GoingAwayAsync(going.Reason, going.Limit, close: true).ConfigureAwait(false);
    }

    /// <summary>The PC woke: addresses may have changed; the DNS-SD record comes back.</summary>
    public void Resumed()
    {
        _adapters.Invalidate();
        if (_dnsSd is { } dnsSd && _tlsListener is { } listener) _ = Task.Run(() => dnsSd.RegisterAsync(_hostName, listener.Port, TimeSpan.FromSeconds(10)));
        UpdatePower();
    }

    /// <summary>The same network and Tailscale: TLS 1.3 on 7893, and the DNS-SD record phones look for.</summary>
    private void StartTls()
    {
        if (_tls is null) return;
        try { _identity = ServiceIdentity.LoadOrCreate(_tls.CertificateFile, _tls.KeyName, _log); }
        catch (Exception e) when (e is System.Security.Cryptography.CryptographicException or IOException or UnauthorizedAccessException)
        {
            // Never replaced over an error: a new key changes what every phone pins.
            NetworkProblem = $"This PC's key couldn't be opened ({e.HResult:X8}). Phones use the built-in connection instead.";
            _log($"tls: {NetworkProblem}");
            return;
        }
        try
        {
            _tlsListener = new TlsListener(Gate, _identity, _adapters, _tls.Port, _log);
            _tlsListener.Start();
        }
        catch (System.Net.Sockets.SocketException)
        {
            _tlsListener = null;
            NetworkProblem = $"Port {_tls.Port} is in use by another program. Phones use the built-in connection instead.";
            _log($"tls: {NetworkProblem}");
            return;
        }
        if (_tls.Advertise)
        {
            _dnsSd = new DnsSd(_log);
            var port = _tlsListener.Port;
            _ = Task.Run(() => _dnsSd.RegisterAsync(_hostName, port, TimeSpan.FromSeconds(10)));
        }
    }

    /// <summary>The port phones dial on the same network, once the listener is open (tests ask for any free one).</summary>
    internal int? TlsPort => _tlsListener?.Port;

    /// <summary>The certificate hash phones pin, once there is a listener.</summary>
    internal string? Pin => _tlsListener is null ? null : _identity?.Pin;

    /// <summary>Where phones dial on the same network and Tailscale: none until the listener is open.</summary>
    private IReadOnlyList<string> Addresses() => _tlsListener is null ? [] : AdapterPolicy.Advertised(_adapters.Facts);

    /// <summary>The service's own iroh key: made once, in its store, and never taken from a tray app.</summary>
    private byte[] SecretKey()
    {
        if (_secrets.Get(IrohKeySlot) is { } stored)
        {
            try { if (Convert.FromBase64String(stored) is { Length: 32 } key) return key; }
            catch (FormatException) { }
        }
        var fresh = IrohEndpoint.NewSecretKey();
        _secrets.Set(IrohKeySlot, Convert.ToBase64String(fresh));
        _log("iroh: made this PC's identity");
        return fresh;
    }

    /// <summary>
    /// What a grant carries now: the certificate and addresses of the listener on the network (the no-listener pin and
    /// none without one: RECONCILIATION), the host's name (the DNS-SD instance name), and the iroh identity.
    /// </summary>
    private GrantContents? Grant()
    {
        if (_endpoint is not { } endpoint && _tlsListener is null) return null;
        return new GrantContents
        {
            CertSHA256 = Pin ?? GrantContents.NoListenerPin,
            Port = _tlsListener?.Port ?? RemoteShell.DefaultPort,
            Addresses = Addresses(),
            HostName = _hostName,
            IrohId = _endpoint?.Id,
            IrohRelay = _endpoint?.HomeRelay,
            RelayToken = _endpoint is not null && _relayUrl() is { Length: > 0 } ? _secrets.Get(RelayTokenSlot) : null,
        };
    }

    private ShellGateHooks Hooks() => new()
    {
        MacInfo = () => _endpoint is { } endpoint
            ? new ShellEnvelope(ShellEnvelope.MacInfo)
            {
                IrohID = endpoint.Id,
                IrohRelay = endpoint.HomeRelay,
                RelayToken = _relayUrl() is { Length: > 0 } ? _secrets.Get(RelayTokenSlot) : null,
                // Where to dial this PC over TLS (protocol/README.md): never iroh's own addresses.
                Addresses = [.. Addresses()],
            }
            : null,
        Host = phone =>
        {
            var state = OwnerHost(phone)?.State;
            var screen = Directory.ScreenAllowed(phone);
            var rdp = RemoteDesktop?.Verdict(Directory.Owner(phone)).Rdp ?? "service";
            return new HostInfo
            {
                Kind = HostInfo.KindWindows,
                Os = RuntimeInformation.OSDescription,
                // The account's tray app is its link to a Windows session: without it, "Sign in to…".
                SignedIn = state is not null,
                App = state is not null,
                Shells = state?.Shells ?? [],
                Screens = rdp == Passthrough.Core.Screen.RemoteDesktopVerdict.Ready ? [HostInfo.ScreenRdp] : [],
                Rdp = rdp,
                Access = new HostAccess { Shell = true, Screen = screen, Share = Directory.MayShare(phone) },
                Lock = true,
                User = screen ? state?.User : null,
                // This account can keep access to other computers (stage 7): phones may hand it some.
                IdKey = state?.IdKey,
                SleepAfter = SleepAfter(),
                Display = state?.Display,
            }.Cleaned();
        },
        State = phone => OwnerHost(phone)?.State is { } state
            ? new HostState { Battery = state.Battery, Charging = state.Charging, Locked = state.Locked, Control = false }
            : new HostState { Control = false },
        Label = phone => Directory.Owner(phone) is { } owner ? Directory.For(owner).Phones.FirstOrDefault(p => p.PhoneId == phone)?.Label ?? "A phone" : "A phone",
        Lock = phone => OwnerHost(phone)?.Lock() ?? ShellError.SignedOut,
        RemoteDesktop = RemoteDesktop,
        AccountOf = phone => Directory.Owner(phone),
        ViewStarted = v => _log($"screen: \"{v.Label}\" ({Short(v.PhoneId)}) account …{Tail(v.Account)} opened a view"),
        ViewEnded = v =>
        {
            if (v.Account is { } owner && v.End is { } end)
                Notices.Viewed(owner, v.PhoneId, v.Label, v.Start, end, t => t.ToLocalTime().ToString("HH:mm", System.Globalization.CultureInfo.CurrentCulture));
            ViewLog(v);
        },
        SaveComputerPass = (phone, label, m) => OwnerHost(phone) is { } owner ? owner.SavePassAsync(phone, label, m) : Task.FromResult<ShellError?>(ShellError.SignedOut),
        ComputerGranted = (phone, c) =>
        {
            if (Directory.Owner(c.Id) is not { } owner) return;
            Notices.Add(owner, c.ScreenPending == true ? PipeNotice.ComputerScreenPending : PipeNotice.ComputerGranted, c.ScreenPending == true
                ? $"{phone} gave {c.Name} access to this PC's shell. Let it see the screen too? Windows still asks for your password."
                : $"{phone} gave {c.Name} access to this PC's {(c.Shell == true ? "shell" : "screen")}.", c.Id);
        },
        Event = e => _log($"shell: {e}"),
    };

    private void ViewLog(Passthrough.Core.Screen.RelayRecord v) => _log($"screen: \"{v.Label}\" ({Short(v.PhoneId)}) account …{Tail(v.Account)} view ended after {(v.End - v.Start)?.ToString(@"h\:mm\:ss")}; {v.BytesOut / 1e6:F1} MB out, {v.BytesIn / 1e6:F1} MB in; ended by {v.EndedBy}");

    private static string Short(string id) => id.Length > 8 ? id[..8] : id;
    private static string Tail(string? sid) => sid?.Split('-')[^1] ?? "?";

    public void Dispose()
    {
        _power.Dispose();
        _connectedRequest?.Dispose();
        _awakeRequest?.Dispose();
        _dnsSd?.Dispose();
        _tlsListener?.Dispose();
        _identity?.Dispose();
        Gate.Stop();
        _listener?.Dispose();
        _endpoint?.Dispose();
    }
}
