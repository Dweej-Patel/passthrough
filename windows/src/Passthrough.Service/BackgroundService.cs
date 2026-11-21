using Passthrough.Core.Logging;
using Passthrough.Core.Setup;
using Passthrough.Core.Storage;
using Passthrough.Windows.Service;
using Passthrough.Windows.Setup;

namespace Passthrough.Service;

/// <summary>
/// The service while it runs, as its own account (<c>NT SERVICE\PassthroughService</c>). It refuses to run unless
/// Remote access is on and its data folder is still Passthrough's, and logs to <c>logs\service.log</c>.
/// </summary>
internal sealed class BackgroundService
{
    private readonly SetupMachine _machine = WindowsSetup.Machine();
    private LogBook? _log;

    public void Log(string message) => _log?.Info(message);

    public async Task<int> RunAsync(CancellationToken stopping)
    {
        _log = new LogBook(PhysicalFileSystem.Instance, Path.Combine(_machine.LogsFolder, "service.log"), TimeProvider.System);
        if (WindowsMachineRegistry.Read() is not { Enabled: true } installed)
        {
            Log("service: Remote access is off; not starting");
            return 1;
        }
        if (!Directory.Exists(_machine.StoreFolder))
        {
            Log("service: the data folder is missing; turn Remote access on again");
            return 2;
        }
        Log($"service: started (build {installed.Build}, pipe protocol {installed.PipeProtocol})");
        try { await Task.Delay(Timeout.Infinite, stopping).ConfigureAwait(false); }
        catch (OperationCanceledException) { }
        Log("service: stopped");
        _log.Flush();
        return 0;
    }

    public bool OnControl(ServiceControlEvent control)
    {
        switch (control.Control)
        {
            case ServiceControl.UserDefined when control.Code == ServiceDefinition.ControlReload:
                Log("service: asked to re-read its settings");
                return true;
            case ServiceControl.PowerEvent:
            case ServiceControl.SessionChange:
                return true;
            default:
                return control.Control is ServiceControl.Stop or ServiceControl.PreShutdown;
        }
    }
}
