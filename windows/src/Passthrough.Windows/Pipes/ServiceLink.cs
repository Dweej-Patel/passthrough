using Passthrough.Core.Pipe;
using Passthrough.Windows.Setup;

namespace Passthrough.Windows.Pipes;

/// <summary>Where the tray app's link to the service is, for the Background service row.</summary>
public enum ServiceLinkState
{
    /// <summary>Remote access isn't installed, or is turned off.</summary>
    Off,
    Connecting,
    /// <summary>Linked: the service reaches this account's shells.</summary>
    Linked,
    /// <summary>The service isn't running (it should be: <c>Start it</c>).</summary>
    NotRunning,
    /// <summary>The service refused this tray app: <see cref="ServiceLink.Refusal"/> says why (<c>version</c>: Finish the update).</summary>
    Refused,
    /// <summary>Something other than the service holds its pipe.</summary>
    Impostor,
}

/// <summary>
/// The tray app's link to the service (stage 4 plan, section 4): while Remote access is installed and on, it connects,
/// checks the pipe is the service's, says hello, and serves this account's shells over it; when the link drops it tries
/// again after 0.5, 1, 2, then every 5 seconds. Its sessions keep running meanwhile.
/// </summary>
public sealed class ServiceLink : IDisposable
{
    private static readonly TimeSpan[] Backoff = [TimeSpan.FromSeconds(0.5), TimeSpan.FromSeconds(1), TimeSpan.FromSeconds(2), TimeSpan.FromSeconds(5)];
    private readonly PipeSessionServer _server;
    private readonly string _build;
    private readonly Action<string>? _log;
    private readonly CancellationTokenSource _stop = new();
    private PipeLink? _link;
    private Task? _loop;

    public ServiceLink(PipeSessionServer server, string build, Action<string>? log = null)
    {
        _server = server;
        _build = build;
        _log = log;
    }

    public ServiceLinkState State { get; private set; } = ServiceLinkState.Off;

    /// <summary>Why the service refused (a <see cref="PipeRefused"/> reason) when <see cref="State"/> is <see cref="ServiceLinkState.Refused"/>.</summary>
    public string? Refusal { get; private set; }

    /// <summary>What the service said when it took this tray app.</summary>
    public PipeWelcome? Welcome { get; private set; }

    /// <summary>Fires, on any thread, when <see cref="State"/> changes.</summary>
    public event Action? Changed;

    public void Start() => _loop ??= Task.Run(RunAsync);

    private void Set(ServiceLinkState state, string? refusal = null)
    {
        if (State == state && Refusal == refusal) return;
        (State, Refusal) = (state, refusal);
        Changed?.Invoke();
    }

    private async Task RunAsync()
    {
        var attempt = 0;
        while (!_stop.IsCancellationRequested)
        {
            if (WindowsMachineRegistry.Read() is not { Enabled: true })
            {
                Set(ServiceLinkState.Off);
                await Wait(TimeSpan.FromSeconds(5)).ConfigureAwait(false);
                continue;
            }
            if (State is not (ServiceLinkState.Refused or ServiceLinkState.Impostor or ServiceLinkState.NotRunning)) Set(ServiceLinkState.Connecting);
            try
            {
                using var pipe = ServicePipe.Connect();
                Welcome = await PipeHandshakes.ClientAsync(pipe, new PipeHello { Build = _build, Pid = Environment.ProcessId }, _stop.Token).ConfigureAwait(false);
                attempt = 0;
                var link = new PipeLink(pipe, service: false, PipeSessionServer.LinkBacklogLimit, log: _log);
                _link = link;
                Set(ServiceLinkState.Linked);
                _log?.Invoke("service: linked");
                await _server.ServeAsync(link).ConfigureAwait(false);
                _log?.Invoke("service: the link dropped");
                Set(ServiceLinkState.Connecting);
            }
            catch (ServicePipe.NotThereException) { Set(ServiceLinkState.NotRunning); }
            catch (ServicePipe.ImpostorException e)
            {
                if (State != ServiceLinkState.Impostor) _log?.Invoke($"service: {e.Message}");
                Set(ServiceLinkState.Impostor);
            }
            catch (PipeRefusedException e)
            {
                if (State != ServiceLinkState.Refused) _log?.Invoke($"service: refused ({e.Refused.Reason})");
                Set(ServiceLinkState.Refused, e.Refused.Reason);
            }
            catch (Exception e) when (e is IOException or OperationCanceledException or System.ComponentModel.Win32Exception or UnauthorizedAccessException) { }
            await Wait(Backoff[Math.Min(attempt++, Backoff.Length - 1)]).ConfigureAwait(false);
        }
    }

    private async Task Wait(TimeSpan delay)
    {
        try { await Task.Delay(delay, _stop.Token).ConfigureAwait(false); }
        catch (OperationCanceledException) { }
    }

    public void Dispose()
    {
        _stop.Cancel();
        _link?.Close();
    }
}
