using Passthrough.Core.Logging;
using Passthrough.Core.Pipe;
using Passthrough.Core.Setup;
using Passthrough.Core.Storage;
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
        try { await Trays.RunAsync(stopping).ConfigureAwait(false); }
        catch (OperationCanceledException) { }
        Log("service: stopped");
        _log.Flush();
        return 0;
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
                // Only what administrators wrote is re-read (install.json); a stray control changes nothing.
                Log(ReadState() ? "service: re-read its settings" : "service: couldn't re-read install.json");
                return true;
            case ServiceControl.PowerEvent:
            case ServiceControl.SessionChange:
                return true;
            default:
                return control.Control is ServiceControl.Stop or ServiceControl.PreShutdown;
        }
    }
}
