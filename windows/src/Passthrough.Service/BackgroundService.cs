using Passthrough.Core.Logging;
using Passthrough.Core.Pipe;
using Passthrough.Core.Setup;
using Passthrough.Core.Storage;
using Passthrough.Windows.Remote;
using Passthrough.Windows.Service;
using Passthrough.Windows.Setup;

namespace Passthrough.Service;

/// <summary>
/// The service while it runs, as its own account (<c>NT SERVICE\PassthroughService</c>). It refuses to run unless
/// Remote access is on and its data folder is still Passthrough's, holds the pipe for the accounts allowed to use it,
/// and logs to <c>logs\service.log</c>.
/// </summary>
internal sealed class BackgroundService
{
    private readonly SetupMachine _machine = WindowsSetup.Machine();
    private LogBook? _log;
    private InstallState _state = new();
    private (string InstallFolder, string Build, bool Enabled, int PipeProtocol) _installed;

    public void Log(string message) => _log?.Info(message);

    public TrayLinks? Trays { get; private set; }
    public ServiceRemote? Remote { get; private set; }
    private readonly SemaphoreSlim _reload = new(1, 1);

    /// <summary>
    /// What an administrator's <c>--configure</c> left for the service in its store folder (only administrators and the
    /// service can write there): a relay token to take into the service's own store, or a request for a new identity.
    /// </summary>
    internal const string PendingRelayToken = "relay-token.pending", PendingReset = "reset-identity.pending";

    public async Task<int> RunAsync(CancellationToken stopping)
    {
        _log = new LogBook(PhysicalFileSystem.Instance, Path.Combine(_machine.LogsFolder, "service.log"), TimeProvider.System);
        if (WindowsMachineRegistry.Read() is not { Enabled: true } installed)
        {
            Log("service: Remote access is off; not starting");
            return 1;
        }
        _installed = installed;
        if (!Directory.Exists(_machine.StoreFolder) || !ReadState())
        {
            Log("service: the data folder or install.json is missing; turn Remote access on again");
            return 2;
        }
        Log($"service: started (build {installed.Build}, pipe protocol {PipeProtocol.Version}, {_state.AllowedAccounts.Count} account(s))");
        Trays = new TrayLinks(() => _state.AllowedAccounts, () => new PipeWelcome { Build = _installed.Build, InstallFolder = _installed.InstallFolder }, Log);
        StartRemote();
        try { await Trays.RunAsync(stopping).ConfigureAwait(false); }
        catch (OperationCanceledException) { }
        Remote?.Dispose();
        Log("service: stopped");
        _log.Flush();
        return 0;
    }

    private void StartRemote()
    {
        var store = new Passthrough.Windows.Storage.ServiceSecretStore(_machine.StoreFolder);
        TakePending(store);
        // The local path needs Windows' TLS 1.3 server (Windows 11, Server 2022): below that, phones use iroh only.
        var tls = Environment.OSVersion.Version.Build >= ServiceDefinition.TlsListenerBuild
            ? new ServiceRemote.TlsOptions(Path.Combine(_machine.StoreFolder, "tls.cer"))
            : null;
        if (tls is null) Log("tls: this Windows has no TLS 1.3 server; phones use the built-in connection only");
        Remote = new ServiceRemote(store, _installed.InstallFolder, Trays!, () => _state.Relay.Url, Log, tls: tls, screenSetup: () => _state.Rdp,
            allowedAccounts: () => _state.AllowedAccounts);
        Trays!.Admin = Remote.Admin.Handle;
        Remote.Start();
    }

    private void TakePending(Passthrough.Core.Storage.ISecretStore store)
    {
        var token = Path.Combine(_machine.StoreFolder, PendingRelayToken);
        try
        {
            if (File.Exists(token))
            {
                var value = File.ReadAllText(token).Trim();
                if (value.Length == 0) store.Delete(ServiceRemote.RelayTokenSlot); else store.Set(ServiceRemote.RelayTokenSlot, value);
                File.Delete(token);
                Log("service: took the relay's token");
            }
            var reset = Path.Combine(_machine.StoreFolder, PendingReset);
            if (File.Exists(reset))
            {
                // A new identity: every phone knew this PC by the old one, so every phone's access goes too.
                store.Delete(ServiceRemote.IrohKeySlot);
                Passthrough.Windows.Net.ServiceIdentity.Forget(Path.Combine(_machine.StoreFolder, "tls.cer"));
                foreach (var slot in store.Slots().Where(s => s.StartsWith(Passthrough.Core.Shell.Access.AccessDirectory.SlotPrefix, StringComparison.Ordinal)))
                    store.Delete(slot);
                File.Delete(reset);
                Log("service: this PC's identity was reset; every phone needs the cable again");
            }
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { Log($"service: couldn't take what --configure left ({e.GetType().Name})"); }
    }

    private const int PbtApmSuspend = 4, PbtApmResumeAutomatic = 18;

    private void Going(Passthrough.Core.Shell.GoingAway.Signal signal, TimeSpan wait)
    {
        if (Remote is not { } remote) return;
        var installed = WindowsMachineRegistry.Read();
        var updating = WindowsMachineRegistry.IsUpdating();
        try { remote.GoingAwayAsync(signal, installed?.Enabled ?? false, updating).Wait(wait); }
        catch (AggregateException) { }
    }

    /// <summary>install.json: which accounts may use the service (only administrators can change it).</summary>
    private bool ReadState()
    {
        try
        {
            if (InstallState.Decode(File.ReadAllBytes(_machine.StateFile)) is not { } state) return false;
            _state = state;
            return true;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { return false; }
    }

    public bool OnControl(ServiceControlEvent control)
    {
        switch (control.Control)
        {
            case ServiceControl.UserDefined when control.Code == ServiceDefinition.ControlReload:
                // Only what administrators wrote is re-read (install.json, the pending files); a stray control changes nothing.
                Log(ReadState() ? "service: re-read its settings" : "service: couldn't re-read install.json");
                _ = Task.Run(async () =>
                {
                    await _reload.WaitAsync().ConfigureAwait(false);
                    try
                    {
                        Remote?.Dispose();
                        StartRemote();
                    }
                    finally { _reload.Release(); }
                });
                return true;
            case ServiceControl.PowerEvent when control.EventType == PbtApmSuspend:
                // Blocks Windows only this long: it gives a service about 2 s.
                Going(Passthrough.Core.Shell.GoingAway.Signal.Suspend, TimeSpan.FromSeconds(1.8));
                return true;
            case ServiceControl.PowerEvent when control.EventType == PbtApmResumeAutomatic:
                Remote?.Resumed();
                return true;
            case ServiceControl.PowerEvent:
            case ServiceControl.SessionChange:
                return true;
            case ServiceControl.PreShutdown:
                Going(Passthrough.Core.Shell.GoingAway.Signal.PreShutdown, TimeSpan.FromSeconds(2.5));
                return true;
            case ServiceControl.Stop:
                // --off and --remove set Enabled=0 before stopping: "turned off". An update says nothing.
                Going(Passthrough.Core.Shell.GoingAway.Signal.Stop, TimeSpan.FromSeconds(2.5));
                return true;
            default:
                return false;
        }
    }
}
