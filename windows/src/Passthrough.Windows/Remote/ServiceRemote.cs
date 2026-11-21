using System.Runtime.InteropServices;
using Passthrough.Core.Pipe;
using Passthrough.Core.Shell;
using Passthrough.Core.Shell.Access;
using Passthrough.Core.Shell.Serving;
using Passthrough.Core.Storage;
using Passthrough.Windows.Iroh;
using Passthrough.Windows.Net;
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

    /// <summary>Where the TLS identity lives and how the door is opened (null: no listener on the network, as on Windows 10).</summary>
    public sealed record TlsOptions(string CertificateFile, string KeyName = ServiceIdentity.KeyName, int Port = RemoteShell.DefaultPort, bool Advertise = true);

    /// <summary>Why the local path isn't open, in the words the setup row shows; null when it is (or wasn't asked for).</summary>
    public string? NetworkProblem { get; private set; }

    public ServiceRemote(ISecretStore secrets, string installFolder, ITrayHosts trays, Func<string?> relayUrl, Action<string> log, string? hostName = null, IrohRelay? relayOverride = null,
        TlsOptions? tls = null)
    {
        _secrets = secrets;
        _trays = trays;
        _relayUrl = relayUrl;
        _log = log;
        _hostName = hostName ?? HostName.Current();
        _tls = tls;
        _relayOverride = relayOverride;
        Directory = new AccessDirectory(_secrets, log: log);
        IrohEndpoint.UseLibraryIn(installFolder);
        Gate = new ShellGate(HostFor, Directory, new HandshakeLimiter(TimeSpan.FromSeconds(10), TimeProvider.System), Hooks(), log: log);
        Admin = new PipeAdminHandler(Directory, Grant, ConnectionsOf, Disconnect, log);
        trays.Changed += host =>
        {
            Gate.PushSessions(host);
            Gate.PushHost(host);
            Gate.PushState();
        };
        Directory.Changed += account => trays.Tell(account, new PipeAdminEvent { What = PipeAdminEvent.Access });
    }

    public AccessDirectory Directory { get; }

    /// <summary>This PC's iroh id, and where a phone on this PC reaches it (for tests).</summary>
    internal string? IrohId => _endpoint?.Id;
    internal IReadOnlyList<string> LoopbackAddresses => _endpoint?.LoopbackAddresses ?? [];
    public ShellGate Gate { get; }
    public PipeAdminHandler Admin { get; }

    /// <summary>A phone nobody granted reaches no account: its proof fails before this matters.</summary>
    private ISessionHost HostFor(string phoneId) => _trays.HostFor(Directory.Owner(phoneId) ?? "none");

    private PipeSessionHost? OwnerHost(string phoneId) => Directory.Owner(phoneId) is { } owner ? _trays.HostFor(owner) : null;

    private int ConnectionsOf(string phoneId) => Gate.ConnectedPhones.Count(p => p == phoneId);

    private void Disconnect(string phoneId) => Gate.Disconnect(phoneId);

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
            return new HostInfo
            {
                Kind = HostInfo.KindWindows,
                Os = RuntimeInformation.OSDescription,
                // The account's tray app is its link to a Windows session: without it, "Sign in to…".
                SignedIn = state is not null,
                App = state is not null,
                Shells = state?.Shells ?? [],
                Screens = [],
                Rdp = "service",
                Access = new HostAccess { Shell = true, Screen = screen },
                Lock = true,
                User = screen ? state?.User : null,
            }.Cleaned();
        },
        State = phone => OwnerHost(phone)?.State is { } state
            ? new HostState { Battery = state.Battery, Charging = state.Charging, Locked = state.Locked, Control = false }
            : new HostState { Control = false },
        Label = phone => Directory.Owner(phone) is { } owner ? Directory.For(owner).Phones.FirstOrDefault(p => p.PhoneId == phone)?.Label ?? "A phone" : "A phone",
        Lock = phone => OwnerHost(phone)?.Lock() ?? ShellError.SignedOut,
        Event = e => _log($"shell: {e}"),
    };

    public void Dispose()
    {
        _dnsSd?.Dispose();
        _tlsListener?.Dispose();
        _identity?.Dispose();
        Gate.Stop();
        _listener?.Dispose();
        _endpoint?.Dispose();
    }
}
