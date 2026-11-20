using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Passthrough.App.Platform;
using Passthrough.App.Storage;
using Passthrough.Core.Control;
using Passthrough.Core.Protocol;
using Passthrough.Core.Session;
using Passthrough.Core.Storage;
using Passthrough.Core.Transport;

namespace Passthrough.App;

/// <summary>Starts the session and the tray icon. There are no windows until the icon is clicked.</summary>
public partial class App : Application
{
    private Mutex? _singleInstance;
    private HostSession? _session;
    private TrayIcon? _tray;
    private FlyoutWindow? _flyout;
    private SettingsWindow? _settings;

    public App()
    {
        InitializeComponent();
        UnhandledException += (_, e) => LogFile.Error(e.Exception);
    }

    protected override async void OnLaunched(LaunchActivatedEventArgs args)
    {
        // One copy per Windows user session; a second launch just exits.
        _singleInstance = new Mutex(initiallyOwned: true, @"Local\Passthrough.App", out var isFirst);
        if (!isFirst)
        {
            Exit();
            return;
        }

        try
        {
            var settings = new JsonSettingsStore(PhysicalFileSystem.Instance, Path.Combine(AppFolder.Path, "settings.json"));
            var secrets = new DpapiSecretStore(Path.Combine(AppFolder.Path, "secrets"));
            var runner = new ProcessRunner();
            var locator = new AdbLocator(Environment.GetEnvironmentVariable, File.Exists, ";", "adb.exe", '\\');
            var directory = new DeviceDirectory(new IDeviceWatcher[]
            {
                new UsbMuxWatcher(new UsbMuxClient(ByteStreamConnector.Tcp("127.0.0.1", 27015)), TimeProvider.System),
                new AdbWatcher(new AdbClient(ByteStreamConnector.Tcp("127.0.0.1", 5037)), locator, runner, TimeProvider.System),
            });
            directory.Error += LogFile.Error; // watcher failures (adb that won't start, a daemon that falls silent), once each

            _session = new HostSession(
                directory, secrets, settings, Environment.MachineName,
                (device, identity) => new ControlClient(
                    ct => device.Connect(ProtocolConstants.ControlPort, ct), identity, device.Kind.Label(), TimeProvider.System),
                TimeProvider.System);
            _session.Error += LogFile.Error;
            _session.Log += LogFile.Write;

            var androidEnabled = settings.Get("androidEnabled") != "false";
            var viewModel = new SessionViewModel(_session, DispatcherQueue.GetForCurrentThread(), androidEnabled);
            _flyout = new FlyoutWindow(viewModel, ShowSettings, Quit);
            _tray = new TrayIcon(() => _flyout.ShowAtTray(), ShowSettings, Quit);

            await _session.StartAsync();
        }
        catch (Exception e)
        {
            LogFile.Error(e);
        }
    }

    private void ShowSettings()
    {
        if (_session is null || _flyout is null) return;
        if (_settings is null)
        {
            _settings = new SettingsWindow(_flyout.ViewModel);
            _settings.Closed += (_, _) => _settings = null;
        }
        _settings.Activate();
    }

    private async void Quit()
    {
        try
        {
            if (_session is not null) await _session.DisposeAsync();
        }
        catch (Exception e)
        {
            LogFile.Error(e);
        }
        _flyout?.AllowClose();
        _settings?.Close();
        _tray?.Dispose();
        Exit();
    }
}
