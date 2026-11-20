namespace Passthrough.Core.Transport;

/// <summary>
/// Watches the adb server for Android phones on the cable, starting the server when platform-tools are
/// installed but it is not running. Only usable (authorised) devices are reported. Events fire on background threads.
/// </summary>
public sealed class AdbWatcher(AdbClient client, AdbLocator locator, IProcessRunner runner, TimeProvider time)
    : WatcherBase(WatchTransport.Adb, time)
{
    public const string NotInstalledHint = "Install Android platform-tools to use an Android phone.";
    public const string UnauthorizedHint = "Allow USB debugging on the phone.";

    private static readonly TimeSpan ServerStartInterval = TimeSpan.FromSeconds(60);
    private static readonly TimeSpan RetryDelay = TimeSpan.FromSeconds(5);
    private static readonly TimeSpan NotInstalledRetryDelay = TimeSpan.FromSeconds(30);

    protected override async Task RunAsync(CancellationToken ct)
    {
        while (!ct.IsCancellationRequested)
        {
            var delay = RetryDelay;
            var published = false;
            var adbPath = locator.Find();
            if (Status.State == WatchState.Idle || adbPath is not null && Status.State == WatchState.NotInstalled)
                SetStatus(new WatchStatus(WatchState.Starting));
            try
            {
                await AdbClient.EnsureServerAsync(client, adbPath, new ThrottledRunner(this), Time, ct);
                await foreach (var list in client.TrackDevicesAsync(ct))
                {
                    published = true;
                    Publish([.. list.Where(d => d.IsUsable).Select(d => PhoneDevice.FromAdb(d, client))]);
                    SetStatus(new WatchStatus(WatchState.Watching, HintFor(list)));
                }
                ReportError(new EndOfStreamException("adb ended the device watch"));
            }
            catch (OperationCanceledException) when (ct.IsCancellationRequested)
            {
                return;
            }
            catch (Exception e)
            {
                ReportError(e); // falls through to the status below
            }

            if (published) Publish([]);
            if (adbPath is null)
            {
                SetStatus(new WatchStatus(WatchState.NotInstalled, NotInstalledHint));
                delay = NotInstalledRetryDelay;
            }
            else
            {
                SetStatus(new WatchStatus(WatchState.Unavailable));
            }
            if (!await DelayAsync(delay, ct)) return;
        }
    }

    private static string? HintFor(IReadOnlyList<AdbDevice> devices)
    {
        if (devices.Any(d => d.State == "unauthorized")) return UnauthorizedHint;
        if (devices.Any(d => d.State.Contains("permission"))) return "adb can't access the Android phone. Replug the cable and choose File Transfer if asked.";
        if (devices.Any(d => d.State == "offline")) return "The Android phone is offline to adb. Replug the cable.";
        return null;
    }

    private readonly IProcessRunner _runner = runner;
    private long? _lastServerStart;

    /// <summary>Runs adb at most once per 60 s on the injected clock; a skipped start leaves the probe to fail, so the watcher reports Unavailable and retries later.</summary>
    private sealed class ThrottledRunner(AdbWatcher owner) : IProcessRunner
    {
        public Task<int> RunAsync(string exe, string args, CancellationToken ct)
        {
            if (owner._lastServerStart is { } last && owner.Time.GetElapsedTime(last) < ServerStartInterval)
                return Task.FromResult(-1);
            owner._lastServerStart = owner.Time.GetTimestamp();
            return owner._runner.RunAsync(exe, args, ct);
        }
    }
}
