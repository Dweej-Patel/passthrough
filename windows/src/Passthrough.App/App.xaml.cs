using System.Reflection;
using System.Runtime.InteropServices;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Passthrough.App.Platform;
using Passthrough.App.Storage;
using Passthrough.Core.Control;
using Passthrough.Core.Desktop;
using Passthrough.Core.Logging;
using Passthrough.Core.Protocol;
using Passthrough.Core.Session;
using Passthrough.Core.Storage;
using Passthrough.Core.Transport;
using Passthrough.Windows.Cable;
using Passthrough.Windows.Remote;

namespace Passthrough.App;

/// <summary>Starts the session and the tray icon. There are no windows until the icon is clicked.</summary>
public partial class App : Application
{
    /// <summary>How long Quit waits for the session to close its channel and stop the watchers before exiting anyway.</summary>
    private static readonly TimeSpan QuitLimit = TimeSpan.FromSeconds(3);

    private Mutex? _singleInstance;
    private HostSession? _session;
    private RemoteAccess? _remote;
    private TrayIcon? _tray;
    private FlyoutWindow? _flyout;
    private SettingsWindow? _settings;
    private bool _shuttingDown;
    /// <summary>The last snapshot logged; touched only by <see cref="HostSession.StateChanged"/>, which runs on the session's loop, in order.</summary>
    private SessionState? _logged;

    public App()
    {
        NativeMethods.RestrictDllSearch();
        InitializeComponent();
        // Windows open, hide and close as the app needs; only Quit (or a failed start) ends the process.
        DispatcherShutdownMode = DispatcherShutdownMode.OnExplicitShutdown;
        UnhandledException += (_, e) =>
        {
            LogFile.Error(e.Exception);
            LogFile.Flush();
            // No tray icon yet: part of startup failed outside OnLaunched's try (an async callback). Without an icon there
            // is no Quit, so treat it as a failed start.
            if (_tray is not null || _shuttingDown) return;
            e.Handled = true;
            _ = FailStartupAsync(e.Exception);
        };
        AppDomain.CurrentDomain.UnhandledException += (_, e) =>
        {
            if (e.ExceptionObject is Exception ex) LogFile.Error(ex);
            LogFile.Flush();
        };
        TaskScheduler.UnobservedTaskException += (_, e) => LogFile.Error(e.Exception);
    }

    protected override async void OnLaunched(LaunchActivatedEventArgs args)
    {
        // One copy per Windows user session; a second launch just exits.
        _singleInstance = new Mutex(initiallyOwned: true, @"Local\Passthrough.App", out var isFirst);
        if (!isFirst)
        {
            _singleInstance.Dispose();
            _singleInstance = null;
            Exit();
            return;
        }

        try
        {
            LogFile.Write(SessionLog.Startup(
                typeof(App).Assembly.GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion ?? "?",
                Environment.OSVersion.VersionString, RuntimeInformation.ProcessArchitecture.ToString(), RuntimeInformation.FrameworkDescription));

            var settings = new JsonSettingsStore(PhysicalFileSystem.Instance, Path.Combine(AppFolder.Path, "settings.json"));
            if (settings.Notice is { } notice) LogFile.Write(notice);
            RepairStartAtLogin();
            var secrets = new DpapiSecretStore(Path.Combine(AppFolder.Path, "secrets"));
            var runner = new ProcessRunner();
            // PATH and the Android variables are read afresh on every search, from the user's and the machine's stored
            // environment too, so platform-tools installed while the app runs are found without a restart.
            var locator = new AdbLocator(
                new EnvironmentSources(
                    Process: Environment.GetEnvironmentVariable,
                    User: name => Environment.GetEnvironmentVariable(name, EnvironmentVariableTarget.User),
                    Machine: name => Environment.GetEnvironmentVariable(name, EnvironmentVariableTarget.Machine)),
                File.Exists, ";", "adb.exe", '\\');
            var adb = new AdbWatcher(new AdbClient(ByteStreamConnector.Tcp("127.0.0.1", 5037)), locator, runner, TimeProvider.System);
            adb.AdbPathChanged += path => LogFile.Write($"adb: {path ?? "not found"}"); // on each search that finds it elsewhere, or not at all
            var directory = new DeviceDirectory(new IDeviceWatcher[]
            {
                new UsbMuxWatcher(new UsbMuxClient(ByteStreamConnector.Tcp("127.0.0.1", 27015)), TimeProvider.System),
                adb,
            });
            directory.Error += LogFile.Error; // watcher failures (adb that won't start, a daemon that falls silent), once each

            // Remote access: phones' shells on this PC, through the background service (which faces the network and holds their keys).
            _remote = new RemoteAccess(settings, secrets, Path.Combine(AppFolder.Path, "ShellHistory"), Environment.MachineName, LogFile.Write);
            _session = new HostSession(
                directory, secrets, settings, Environment.MachineName,
                // The cable peer check: only a channel whose far end is Apple's device service or this user's adb carries a shell grant.
                (device, identity) => new ControlClient(
                    ct => device.Connect(ProtocolConstants.ControlPort, ct), identity, device.Kind.Label(), TimeProvider.System,
                    stream => CablePeerCheck.Check(stream, device.Kind)),
                TimeProvider.System, _remote);
            _session.Error += LogFile.Error;
            _session.Log += LogFile.Write;
            _session.StateChanged += LogChanges;

            var viewModel = new SessionViewModel(_session, settings, DispatcherQueue.GetForCurrentThread(),
                settings.Get("androidEnabled") != "false", settings.Notice);
            // The icon first: if the flyout fails to build, the failure path below still has something to take down.
            _tray = new TrayIcon(ToggleFlyout, ShowSettings, Quit);
            _flyout = new FlyoutWindow(viewModel, ShowSettings, Quit);
            var remote = _remote;
            remote.NoticesChanged += () => viewModel.ShowNotices(remote.Notices);
            viewModel.AnswerNotice = remote.AnswerNoticeAsync;

            await _session.StartAsync();
            await _remote.StartIfEnabledAsync();
        }
        catch (Exception e)
        {
            LogFile.Error(e);
            await FailStartupAsync(e);
        }
    }

    /// <summary>Never leaves an invisible process holding the mutex: says what failed, takes down what was made, exits.</summary>
    private async Task FailStartupAsync(Exception e)
    {
        if (_shuttingDown) return;
        try { NativeMethods.ShowError(StartupFailure.Message(e, LogFile.Path), StartupFailure.Caption); }
        catch (Exception shown) { LogFile.Error(shown); }
        await ShutDownAsync();
    }

    /// <summary>An enabled Start at login entry left by a build elsewhere now starts this one.</summary>
    private static void RepairStartAtLogin()
    {
        try
        {
            if (StartupRegistration.RepairAtLaunch()) LogFile.Write("Start at login now points at this copy of Passthrough");
        }
        catch (Exception e)
        {
            LogFile.Error(e); // not worth failing startup over
        }
    }

    private void LogChanges(SessionState state)
    {
        foreach (var line in SessionLog.Changes(_logged, state)) LogFile.Write(line);
        _logged = state;
    }

    private void ToggleFlyout() => _flyout?.ToggleFromTray();

    private void ShowSettings()
    {
        if (_session is null || _flyout is null || _shuttingDown) return;
        if (_settings is null)
        {
            _settings = new SettingsWindow(_flyout.ViewModel, _remote);
            _settings.Closed += (_, _) => _settings = null;
        }
        _settings.BringToFront();
    }

    private async void Quit()
    {
        try
        {
            await ShutDownAsync();
        }
        catch (Exception e)
        {
            LogFile.Error(e);
            Exit();
        }
    }

    /// <summary>Stops the session (waiting at most <see cref="QuitLimit"/>), closes the windows and the icon, releases the mutex and exits.</summary>
    private async Task ShutDownAsync()
    {
        if (_shuttingDown) return;
        _shuttingDown = true;
        try
        {
            if (_session is not null) await _session.DisposeAsync().AsTask().WaitAsync(QuitLimit);
            // Phones are dropped and every session ends (each transcript finished): nothing runs once Passthrough is gone.
            if (_remote is not null) await Task.Run(_remote.Dispose).WaitAsync(QuitLimit);
        }
        catch (TimeoutException)
        {
            LogFile.Write($"the session did not stop within {QuitLimit.TotalSeconds:0} seconds; quitting anyway");
        }
        catch (Exception e)
        {
            LogFile.Error(e);
        }
        Try(() => _settings?.Close());
        Try(() =>
        {
            _flyout?.AllowClose();
            _flyout?.Close();
        });
        Try(() => _tray?.Dispose());
        Try(() => _singleInstance?.ReleaseMutex());
        _singleInstance?.Dispose();
        _singleInstance = null;
        LogFile.Flush();
        Exit();
    }

    private static void Try(Action step)
    {
        try { step(); }
        catch (Exception e) { LogFile.Error(e); }
    }
}
