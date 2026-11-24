using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.WindowsRuntime;
using Microsoft.UI;
using Microsoft.UI.Input;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Passthrough.App.Platform;
using Passthrough.Core.Client;
using Passthrough.Core.Screen;
using Passthrough.Core.Trust;
using Passthrough.Media;
using Passthrough.Windows.ClipSync;
using Passthrough.Windows.Iroh;
using Windows.ApplicationModel.DataTransfer;
using Windows.Graphics;
using Windows.Graphics.Imaging;
using Windows.Storage.Streams;

namespace Passthrough.App.Screen;

/// <summary>
/// A Mac's screen in a window (stage 8 b2–b4): Windows Hello for every window, then a connection of its own (the shell
/// client, signed with this PC's identity), <c>screenVideo</c>, and the stream decoded by <see cref="ScreenPipeline"/>.
/// The picture keeps its shape in any window size; the pointer is drawn over it, not in it. Pointer, wheel (Ctrl+wheel
/// pinches), keys (the table in <see cref="ScreenKeys"/>, through XAML key events: the Windows key stays on this PC),
/// committed text through a hidden text box (so dead keys and input methods compose here). Full screen fills the
/// monitor with the picture and nothing else: the Mac is asked for a display in the screen's own shape, and a small
/// bar (pin, the Mac's name, minimise, restore, close) comes down from the top edge only when the pointer touches it
/// or there is something to say. While the
/// picture is live the two clipboards sync on a connection of their own (<see cref="ClipSyncViewer"/>: Ctrl+C here,
/// ⌘V there and back, files included) and files dropped on the picture land at that point on the Mac; with Sync
/// clipboard off, or a Mac that can't, Send clipboard and Copy from Mac take its place. A lost connection dims the last
/// picture and redials at 0, 2 and 5 s without asking again.
/// </summary>
internal sealed class ScreenWindow : Window, IScreenView
{
    private const int MinWidthDip = 480, MinHeightDip = 300;
    private static readonly TimeSpan[] Redials = [TimeSpan.Zero, TimeSpan.FromSeconds(2), TimeSpan.FromSeconds(5)];

    private readonly ReachableComputer _computer;
    private readonly IComputerIdentity _identity;
    private readonly Func<Task<bool>> _confirm;
    private readonly string _name;
    private readonly Microsoft.UI.Dispatching.DispatcherQueue _ui;

    private readonly PointerStage _stage = new() { Background = new SolidColorBrush(Colors.Black) };
    private readonly Image _picture = new() { Stretch = Stretch.Uniform };
    private readonly Canvas _overlay = new() { IsHitTestVisible = false };
    private readonly Image _pointer = new() { Visibility = Visibility.Collapsed, IsHitTestVisible = false };
    private readonly TextBox _typing = new()
    {
        Width = 1, Height = 1, MinWidth = 1, MinHeight = 1, Opacity = 0.01, Padding = new Thickness(0), BorderThickness = new Thickness(0),
        IsSpellCheckEnabled = false, IsTextPredictionEnabled = false, AcceptsReturn = false,
    };
    private readonly TextBlock _subtitle = new() { Opacity = 0.75, VerticalAlignment = VerticalAlignment.Center, TextTrimming = TextTrimming.CharacterEllipsis };
    private readonly StackPanel _status = new() { Spacing = 12, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
    private readonly TextBlock _statusText = new() { TextWrapping = TextWrapping.WrapWholeWords, TextAlignment = TextAlignment.Center, MaxWidth = 420, Foreground = new SolidColorBrush(Colors.White) };
    private readonly Button _retry = new() { Content = "Try again", HorizontalAlignment = HorizontalAlignment.Center };
    private readonly TextBlock _toast = new() { Opacity = 0.85, VerticalAlignment = VerticalAlignment.Center };
    private readonly ScrollScale _scroll = new();
    private readonly Stopwatch _sinceMove = Stopwatch.StartNew();

    private enum Phase { Locked, Connecting, Live, Reconnecting, Failed, Closed }
    private Phase _phase = Phase.Locked;
    private ShellClient? _shell;
    private ScreenVideoClient? _client;
    private ScreenPipeline? _pipeline;
    private ShellPath? _path;
    private WriteableBitmap? _bitmap;
    private int _streamWidth, _streamHeight;
    private bool _sized;
    private int _redial;
    private int _generation;
    private bool _gotScreen;
    private byte _buttons;
    private bool _composing;
    private bool _active;
    private bool _minimized;
    private IReadOnlyList<string> _viewers = [];
    private (double X, double Y, bool Visible)? _remotePointer;
    private (double X, double Y)? _localPointer;
    private (int Width, int Height, int HotX, int HotY)? _shape;
    private DispatcherQueueTimerWrapper? _pinchEnd;
    private DispatcherQueueTimerWrapper? _refit;
    private DispatcherQueueTimerWrapper? _fitRefused;
    private ScreenFit? _lastFitted;
    private (int Width, int Height, int Space)? _lastFit;

    /// <summary>
    /// How long the Mac's own display must stay the answer before a fitted one counts as refused: the Mac says
    /// <c>fitted</c> for every capture it starts, so an answer to an earlier ask can come just after Fit to window is clicked.
    /// </summary>
    private static readonly TimeSpan RefusedAfter = TimeSpan.FromSeconds(2);
    private bool _pinching;
    private bool _fit;
    private readonly Passthrough.Core.Storage.ISettingsStore? _settings;
    private readonly Microsoft.UI.Xaml.Controls.Primitives.ToggleButton _fitButton = new() { Content = "Fit to window" };

    /// <summary>After the window stops changing size for this long, the Mac is asked for a display in its new shape (each ask is a new display there).</summary>
    private static readonly TimeSpan RefitAfter = TimeSpan.FromMilliseconds(500);

    private string FitKey => "screen.fit." + _computer.HostId;
    private int _toastId;

    // Full screen: the picture alone, with a bar at the top centre that comes when called.
    private static readonly TimeSpan BarStays = TimeSpan.FromSeconds(2.5);
    private bool _fullScreen;
    private bool _barPinned;
    private bool _overBar;
    private Grid? _toolbar;
    private StackPanel? _toolbarStatus;
    private readonly Border _connectionBar = new()
    {
        Visibility = Visibility.Collapsed, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Top,
        Padding = new Thickness(8, 4, 8, 4), CornerRadius = new CornerRadius(0, 0, 8, 8),
        Background = new SolidColorBrush(global::Windows.UI.Color.FromArgb(0xF2, 0x2B, 0x2B, 0x2B)),
    };
    private readonly StackPanel _connectionStatus = new() { Orientation = Orientation.Horizontal, Spacing = 8, VerticalAlignment = VerticalAlignment.Center };
    private DispatcherQueueTimerWrapper? _barHide;

    /// <summary>
    /// Ctrl acts as ⌘ (and Alt as ⌃), so Ctrl+C and Ctrl+V copy and paste on the Mac as they do here: on unless turned
    /// off, for this window and ones opened later. Off: by position, Alt is ⌘ and Ctrl is ⌃.
    /// </summary>
    internal const string CtrlIsCommandKey = "screen.ctrlIsCommand";
    private bool _ctrlIsCommand;
    private readonly Microsoft.UI.Xaml.Controls.Primitives.ToggleButton _ctrlButton = new() { Content = "Ctrl acts as ⌘" };

    // Clipboard sync (a connection of its own beside the screen's, while the picture is live)
    internal const string ClipSyncKey = "screen.clipSync";
    private static readonly TimeSpan ClipRetryNoView = TimeSpan.FromSeconds(1.5), ClipRetry = TimeSpan.FromSeconds(3), ClipSettled = TimeSpan.FromSeconds(10);
    private const int ClipTriesInARow = 5;
    private readonly Microsoft.UI.Xaml.Controls.Primitives.ToggleButton _clipButton = new() { Content = "Sync clipboard" };
    private Button? _sendButton, _copyButton;
    private ClipSyncViewer? _clipViewer;
    private ShellClient? _clipShell;
    private bool _clipOn;
    private bool _clipActive;
    private int _clipTries;
    private int _clipGeneration;
    private Stopwatch? _clipSince;
    private bool _clipHeld;
    /// <summary>The buttons a clipboard sync line asks with (Send / Don't send, Stop), beside it.</summary>
    private readonly StackPanel _clipActions = new() { Orientation = Orientation.Horizontal, Spacing = 6, VerticalAlignment = VerticalAlignment.Center };

    public ScreenWindow(ReachableComputer computer, IComputerIdentity identity, Func<Task<bool>> confirm, Passthrough.Core.Storage.ISettingsStore? settings = null)
    {
        _computer = computer;
        _settings = settings;
        _fit = settings?.Get(FitKey) == "true";
        _clipOn = settings?.Get(ClipSyncKey) != "false";
        _ctrlIsCommand = settings?.Get(CtrlIsCommandKey) != "false";
        _identity = identity;
        _confirm = confirm;
        _name = ScreenFrame.Clean(computer.Credential.MacName);
        _ui = Microsoft.UI.Dispatching.DispatcherQueue.GetForCurrentThread();
        Title = _name;
        AppWindow.SetIcon(AppIcon.Path);
        var hwnd = Win32Interop.GetWindowFromWindowId(AppWindow.Id);
        var scale = NativeMethods.DpiOf(hwnd) / 96.0;
        if (AppWindow.Presenter is OverlappedPresenter presenter)
        {
            presenter.PreferredMinimumWidth = (int)(MinWidthDip * scale);
            presenter.PreferredMinimumHeight = (int)(MinHeightDip * scale);
        }
        AppWindow.Resize(new SizeInt32((int)(1024 * scale), (int)(680 * scale)));
        Content = Build();
        Activated += (_, e) =>
        {
            _active = e.WindowActivationState != WindowActivationState.Deactivated;
            if (!_active) ReleaseButtons();
            PlaceTaskbar();
            PlacePointer(); // this PC's own pointer comes back when the window isn't the one in front
            ShowSubtitle();
        };
        AppWindow.Changed += (_, e) =>
        {
            if (!e.DidPresenterChange && !e.DidSizeChange && !e.DidVisibilityChange) return;
            var minimized = AppWindow.Presenter is OverlappedPresenter { State: OverlappedPresenterState.Minimized } || !AppWindow.IsVisible;
            if (minimized == _minimized) return;
            _minimized = minimized;
            _client?.Relayout(Layout());
        };
        Closed += (_, _) =>
        {
            Stop(Phase.Closed);
            ShowOwnCursor(true);
            if (_fullScreen)
            {
                TaskbarKeeper.FullScreenEnded();
                TaskbarKeeper.BringBack();
            }
        };
    }

    private UIElement Build()
    {
        var copy = ToolButton("Copy from Mac", "Presses ⌘C on the Mac and puts what it copied on this PC's clipboard");
        copy.Click += (_, _) => { _client?.CopySelection(); _typing.Focus(FocusState.Programmatic); };
        var send = ToolButton("Send clipboard", "Puts the text on this PC's clipboard on the Mac's clipboard");
        send.Click += async (_, _) => await SendClipboardAsync();
        var full = ToolButton("Full screen", "Full screen (Ctrl+Alt+Break). Esc goes to the Mac.");
        full.Click += (_, _) => ToggleFullScreen();
        _retry.Click += async (_, _) => await StartAsync();
        AutomationName(_retry, "Try again");
        (_sendButton, _copyButton) = (send, copy);
        _ctrlButton.IsChecked = _ctrlIsCommand;
        ToolTipService.SetToolTip(_ctrlButton, "On: Ctrl is the Mac's ⌘, so Ctrl+C, Ctrl+V and Ctrl+Z work there as they do here, and Alt is ⌃. Off: Alt is ⌘ and Ctrl is ⌃, as the keys sit on a Mac keyboard. The Windows key is ⌥ either way.");
        AutomationName(_ctrlButton, "Ctrl acts as Command");
        _ctrlButton.Click += (_, _) =>
        {
            _ctrlIsCommand = _ctrlButton.IsChecked == true;
            try { _settings?.Set(CtrlIsCommandKey, _ctrlIsCommand ? "true" : "false"); }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException or InvalidOperationException) { LogFile.Error(e); } // not remembered, still done
            _typing.Focus(FocusState.Programmatic);
        };
        _clipButton.IsChecked = _clipOn;
        ToolTipService.SetToolTip(_clipButton, "What you copy here is on the Mac's clipboard and what's copied there is on this PC's: text, pictures and files. Drop files on the picture to put them where you let go. It applies to this window and to ones opened later.");
        AutomationName(_clipButton, "Sync clipboard");
        _clipButton.Click += (_, _) =>
        {
            _clipOn = _clipButton.IsChecked == true;
            try { _settings?.Set(ClipSyncKey, _clipOn ? "true" : "false"); }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException or InvalidOperationException) { LogFile.Error(e); } // not remembered, still done
            _clipTries = 0;
            if (_clipOn) StartClipSync(); else StopClipSync(forget: true);
            _typing.Focus(FocusState.Programmatic);
        };
        _fitButton.IsChecked = _fit;
        ToolTipService.SetToolTip(_fitButton, "The Mac makes a display in this window's shape, so its picture fills the window. The Mac's own screen shows that display while you're here.");
        AutomationName(_fitButton, "Fit to window");
        _fitButton.Click += (_, _) =>
        {
            _fit = _fitButton.IsChecked == true;
            try { _settings?.Set(FitKey, _fit ? "true" : "false"); }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException or InvalidOperationException) { LogFile.Error(e); } // not remembered, still done
            _client?.Relayout(Layout());
            _typing.Focus(FocusState.Programmatic);
        };

        var bar = new Grid { Padding = new Thickness(12, 6, 12, 6), ColumnSpacing = 8 };
        _toolbar = bar;
        bar.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        bar.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        bar.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var left = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 12 };
        _toolbarStatus = left;
        left.Children.Add(_subtitle);
        left.Children.Add(_toast);
        left.Children.Add(_clipActions);
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetLiveSetting(_toast, Microsoft.UI.Xaml.Automation.Peers.AutomationLiveSetting.Polite);
        bar.Children.Add(left);
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
        buttons.Children.Add(_ctrlButton);
        buttons.Children.Add(_clipButton);
        buttons.Children.Add(send);
        buttons.Children.Add(copy);
        buttons.Children.Add(_fitButton);
        buttons.Children.Add(full);
        Grid.SetColumn(buttons, 2);
        bar.Children.Add(buttons);

        _status.Children.Add(_statusText);
        _status.Children.Add(_retry);
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetLiveSetting(_statusText, Microsoft.UI.Xaml.Automation.Peers.AutomationLiveSetting.Polite);
        _overlay.Children.Add(_pointer);
        _overlay.Children.Add(_typing);
        _stage.Children.Add(_picture);
        _stage.Children.Add(_overlay);
        _stage.Children.Add(_status);
        _stage.PointerPressed += OnPointerPressed;
        _stage.PointerMoved += OnPointerMoved;
        _stage.PointerReleased += OnPointerReleased;
        _stage.PointerCaptureLost += (_, _) => ReleaseButtons();
        _stage.PointerExited += (_, _) => { _localPointer = null; PlacePointer(); };
        _stage.PointerWheelChanged += OnWheel;
        _stage.AllowDrop = true;
        _stage.DragOver += OnDragOver;
        _stage.Drop += OnDrop;
        _stage.SizeChanged += (_, _) =>
        {
            PlacePointer();
            if (!FitsWindow || _client is null) return;
            // Dragging the edge sends one ask, when it stops: each is a new display on the Mac.
            Refit();
        };
        _typing.PreviewKeyDown += OnKeyDown;
        _typing.PreviewKeyUp += OnKeyUp;
        _typing.TextChanged += OnTyped;
        _typing.TextCompositionStarted += (_, _) => _composing = true;
        _typing.TextCompositionEnded += (_, _) => { _composing = false; OnTyped(null, null); };
        _typing.LostFocus += (_, _) => { if (_composing) { _composing = false; _typing.Text = ""; } };

        var root = new Grid { Background = new SolidColorBrush(Colors.Black), RequestedTheme = ElementTheme.Dark };
        root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        root.Children.Add(bar);
        Grid.SetRow(_stage, 1);
        root.Children.Add(_stage);
        Grid.SetRowSpan(_connectionBar, 2);
        _connectionBar.Child = BuildConnectionBar();
        _connectionBar.PointerEntered += (_, _) => { _overBar = true; RevealBar(); };
        _connectionBar.PointerExited += (_, _) => { _overBar = false; RevealBar(); };
        root.Children.Add(_connectionBar);
        return root;
    }

    /// <summary>The picture takes the window's shape: asked for with Fit to window, and always in full screen.</summary>
    private bool FitsWindow => _fit || _fullScreen;

    /// <summary>
    /// Asks the Mac for the display this window wants now (its own shape with Fit to window or in full screen, else
    /// the Mac's own), once things have stopped changing: each ask can make a new display there, so dragging an edge,
    /// or going into full screen and straight out again, sends one ask or none.
    /// </summary>
    private void Refit()
    {
        _refit ??= new DispatcherQueueTimerWrapper(_ui, RefitAfter, () => { if (!_minimized) _client?.Relayout(Layout()); });
        _refit.Restart();
    }

    // MARK: Full screen

    /// <summary>Full screen's bar, as Remote Desktop's: pin, the computer's name, what clipboard sync has to say, minimise, restore, close.</summary>
    private UIElement BuildConnectionBar()
    {
        Button Icon(string glyph, string name, Action click)
        {
            var b = new Button { Content = new FontIcon { Glyph = glyph, FontSize = 12 }, Padding = new Thickness(8, 4, 8, 4), Background = new SolidColorBrush(Colors.Transparent), BorderThickness = new Thickness(0) };
            ToolTipService.SetToolTip(b, name);
            AutomationName(b, name);
            b.Click += (_, _) => click();
            return b;
        }
        var pin = new Microsoft.UI.Xaml.Controls.Primitives.ToggleButton
        {
            Content = new FontIcon { Glyph = "\uE718", FontSize = 12 }, Padding = new Thickness(8, 4, 8, 4), BorderThickness = new Thickness(0),
        };
        ToolTipService.SetToolTip(pin, "Keep this bar on screen");
        AutomationName(pin, "Keep this bar on screen");
        pin.Click += (_, _) => { _barPinned = pin.IsChecked == true; RevealBar(); _typing.Focus(FocusState.Programmatic); };
        var panel = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4 };
        panel.Children.Add(pin);
        panel.Children.Add(new TextBlock { Text = _name, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(6, 0, 10, 0), MaxWidth = 280, TextTrimming = TextTrimming.CharacterEllipsis });
        panel.Children.Add(_connectionStatus);
        panel.Children.Add(Icon("\uE921", "Minimize", () => ShowWindow(Win32Interop.GetWindowFromWindowId(AppWindow.Id), 6 /* SW_MINIMIZE */)));
        panel.Children.Add(Icon("\uE923", "Leave full screen (Ctrl+Alt+Break)", ToggleFullScreen));
        panel.Children.Add(Icon("\uE8BB", "Close", Close));
        return panel;
    }

    /// <summary>Shows full screen's bar; it goes again in a moment unless pinned, under the pointer, or saying something.</summary>
    private void RevealBar()
    {
        if (!_fullScreen) return;
        _connectionBar.Visibility = Visibility.Visible;
        _barHide ??= new DispatcherQueueTimerWrapper(_ui, BarStays, () =>
        {
            if (!_fullScreen) return;
            if (_barPinned || _overBar || _toast.Text.Length > 0 || _clipActions.Children.Count > 0) { _barHide!.Restart(); return; }
            _connectionBar.Visibility = Visibility.Collapsed;
        });
        _barHide.Restart();
    }

    /// <summary>The line beside the subtitle (in full screen, in its bar, which comes down to say it).</summary>
    private void SetToast(string text)
    {
        _toast.Text = text;
        if (text.Length > 0) RevealBar();
    }

    [DllImport("user32.dll")] private static extern bool ShowWindow(IntPtr window, int command);

    private static Button ToolButton(string text, string tip)
    {
        var b = new Button { Content = text };
        ToolTipService.SetToolTip(b, tip);
        AutomationName(b, text);
        return b;
    }

    private static void AutomationName(UIElement e, string name) => Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(e, name);

    public void BringToFront()
    {
        Activate();
        NativeMethods.BringToFront(Win32Interop.GetWindowFromWindowId(AppWindow.Id));
    }

    // MARK: Phases

    /// <summary>Asks Windows Hello (every window, and again after a failure that needs a click), then connects.</summary>
    public async Task StartAsync()
    {
        if (_phase is Phase.Connecting or Phase.Live or Phase.Closed) return;
        Status($"Confirm it's you to see and control {_name}'s screen.", retry: false);
        _phase = Phase.Locked;
        BringToFront();
        bool ok;
        try { ok = await _confirm(); }
        catch (Exception e) when (e is COMException or UnauthorizedAccessException) { ok = false; }
        if (_phase == Phase.Closed) return;
        if (!ok)
        {
            _phase = Phase.Failed;
            Status($"Confirm it's you to see and control {_name}'s screen.", retry: true, retryText: "Confirm");
            return;
        }
        _redial = 0;
        Connect();
    }

    private void Connect()
    {
        _phase = _gotScreen ? Phase.Reconnecting : Phase.Connecting;
        Status(_gotScreen ? "Reconnecting…" : $"Connecting to {_name}…", retry: false);
        _picture.Opacity = _gotScreen ? 0.4 : 1;
        var generation = ++_generation;
        var c = _computer.Credential;
        var credential = new ShellCredential(c.MacID, c.MacName, c.CertSHA256, Convert.FromBase64String(c.ShellKey), c.PhoneID, c.Port, c.Addresses,
            c.IrohID, c.IrohRelay, c.RelayToken, _computer.HostKind);
        var screenGiven = false;
        ShellClient? shell = null;
        shell = new ShellClient(credential, new PinnedTlsDialer(), new IrohShellDialer(), e =>
        {
            switch (e)
            {
                case ShellClientEvent.Ready ready:
                    OnUi(() => { if (generation == _generation) _path = ready.Path; });
                    shell!.RequestScreen(video: true);
                    break;
                case ShellClientEvent.Screen screen:
                    screenGiven = true;
                    var codecs = SafeCodecs(); // probed off the UI thread
                    OnUi(() => StartStream(generation, screen, codecs));
                    break;
                case ShellClientEvent.Failed failed:
                    OnUi(() => { if (generation == _generation) Fail(ScreenFrame.Refusal(failed.Reason, _name)); });
                    shell!.Disconnect();
                    break;
                case ShellClientEvent.Disconnected d when !screenGiven:
                    LogFile.Write($"screen: no connection ({d.Error?.GetType().Name ?? "clean"})");
                    OnUi(() => { if (generation == _generation && _phase is Phase.Connecting or Phase.Reconnecting) Lost(); });
                    break;
            }
        }, identity: _identity);
        _shell = shell;
        shell.Connect();
    }

    private static ScreenCodecs SafeCodecs()
    {
        try { return VideoDecoder.Decodable(); }
        catch (Exception e) when (e is COMException or DllNotFoundException) { return ScreenCodecs.H264; }
    }

    private ScreenVideoClient.Layout Layout()
    {
        if (FitsWindow)
        {
            // Minimised or not laid out yet, the stage has no size: the last shape is kept, so only the rate changes.
            if (!_minimized && _stage.ActualWidth >= 1 && _stage.ActualHeight >= 1)
                _lastFit = ScreenFrame.Fitted(_stage.ActualWidth, _stage.ActualHeight, _stage.XamlRoot?.RasterizationScale ?? 1);
            if (_lastFit is var (width, height, space))
                return new ScreenVideoClient.Layout(width, height, ScreenFit.Device, _minimized ? 15 : 60, Space: space);
        }
        // By index, never enumerated: the list DisplayArea.FindAll returns can't be cast to IEnumerable by the WinRT
        // projection (InvalidCastException, E_NOINTERFACE), so foreach or LINQ over it throws.
        var areas = DisplayArea.FindAll();
        var sides = new List<int>();
        for (var i = 0; i < areas.Count; i++) sides.Add(Math.Max(areas[i].OuterBounds.Width, areas[i].OuterBounds.Height));
        var side = ScreenFrame.RequestedSide(sides);
        return new ScreenVideoClient.Layout(side, side, ScreenFit.Mac, _minimized ? 15 : 60);
    }

    private void StartStream(int generation, ShellClientEvent.Screen screen, ScreenCodecs codecs)
    {
        if (generation != _generation || _phase == Phase.Closed)
        {
            _ = screen.Stream.DisposeAsync().AsTask();
            return;
        }
        _shell = null;
        _pipeline?.Dispose();
        var pipeline = new ScreenPipeline(_ui, this);
        var client = new ScreenVideoClient(screen.Stream.Stream, screen.InitialBytes, Layout(), codecs, pipeline, owner: screen.Stream);
        pipeline.Attach(client);
        _pipeline = pipeline;
        _client = client;
        _gotScreen = true;
        _phase = Phase.Live;
        _redial = 0;
        client.Start();
        HideStatus();
        _picture.Opacity = 1;
        _typing.Focus(FocusState.Programmatic);
        ShowSubtitle();
        _clipTries = 0;
        StartClipSync();
    }

    /// <summary>
    /// Runs on the window's thread. Anything thrown there is logged and ends the view with a sentence: an exception
    /// left in a dispatcher callback ends the whole app, and Windows keeps no trace of where.
    /// </summary>
    private void OnUi(Action action) => _ui.TryEnqueue(() =>
    {
        try { action(); }
        catch (Exception e) when (e is not OutOfMemoryException)
        {
            LogFile.Error(e);
            LogFile.Flush();
            try { if (_phase != Phase.Closed) Fail($"{_name}'s screen couldn't be shown on this PC."); }
            catch (Exception again) when (again is not OutOfMemoryException) { LogFile.Error(again); }
        }
    });

    private void Lost()
    {
        if (_redial < Redials.Length)
        {
            var delay = Redials[_redial++];
            _phase = Phase.Reconnecting;
            _picture.Opacity = 0.4;
            Status("Reconnecting…", retry: false);
            var generation = _generation;
            _ = Task.Delay(delay).ContinueWith(_ => OnUi(() =>
            {
                if (generation == _generation && _phase == Phase.Reconnecting) Connect();
            }), TaskScheduler.Default);
            return;
        }
        Fail(_gotScreen ? $"The connection to {_name} was lost." : $"Couldn't reach {_name}. Check that it's awake and Remote Shell is on there.");
    }

    private void Fail(string message)
    {
        StopStream();
        _phase = Phase.Failed;
        _picture.Opacity = 0.4;
        Status(message, retry: true);
        ShowSubtitle();
    }

    private void StopStream()
    {
        _generation++;
        var client = _client;
        _client = null;
        _pipeline?.Dispose();
        _pipeline = null;
        if (client is not null) _ = client.DisposeAsync().AsTask();
        _shell?.Disconnect();
        _shell = null;
        _buttons = 0;
        // Sync lasts only while the picture is live; what was received stays for pasting until the window closes.
        StopClipSync(forget: false);
    }

    private void Stop(Phase phase)
    {
        StopStream();
        _phase = phase;
        if (phase == Phase.Closed)
        {
            _clipViewer?.Dispose();
            _clipViewer = null;
        }
    }

    // MARK: Clipboard sync

    /// <summary>Asks the Mac for clipboard sync on a connection of its own, once the picture is live.</summary>
    private void StartClipSync()
    {
        if (!_clipOn || _phase != Phase.Live || _clipShell is not null || _clipActive) return;
        _clipTries++;
        var generation = ++_clipGeneration;
        var c = _computer.Credential;
        var credential = new ShellCredential(c.MacID, c.MacName, c.CertSHA256, Convert.FromBase64String(c.ShellKey), c.PhoneID, c.Port, c.Addresses,
            c.IrohID, c.IrohRelay, c.RelayToken, _computer.HostKind);
        var handed = false;
        ShellClient? shell = null;
        shell = new ShellClient(credential, new PinnedTlsDialer(), new IrohShellDialer(), e =>
        {
            switch (e)
            {
                case ShellClientEvent.Ready:
                    shell!.RequestClipSync();
                    break;
                case ShellClientEvent.ClipSync sync:
                    handed = true;
                    OnUi(() => BeginClipSync(generation, sync));
                    break;
                case ShellClientEvent.ClipSyncRefused refused:
                    shell!.Disconnect();
                    OnUi(() => ClipSyncRefused(generation, refused.Reason));
                    break;
                case ShellClientEvent.Disconnected when !handed:
                    OnUi(() =>
                    {
                        if (generation != _clipGeneration || _clipShell is null) return;
                        _clipShell = null;
                        RetryClipSync(ClipRetry);
                    });
                    break;
            }
        }, identity: _identity);
        _clipShell = shell;
        shell.Connect();
    }

    private void BeginClipSync(int generation, ShellClientEvent.ClipSync sync)
    {
        if (generation != _clipGeneration || !_clipOn || _phase != Phase.Live)
        {
            _ = sync.Stream.DisposeAsync().AsTask();
            return;
        }
        _clipShell = null; // it let go of the stream
        _clipViewer ??= new ClipSyncViewer(_name, status => OnUi(() => ShowClipStatus(status)), LogFile.Write);
        _clipActive = true;
        _clipSince = Stopwatch.StartNew();
        ShowClipButtons();
        _clipViewer.Start(sync.Stream.Stream, sync.InitialBytes, sync.Stream, ended: () => OnUi(() =>
        {
            if (generation != _clipGeneration) return;
            _clipActive = false;
            ShowClipButtons();
            // The cap counts tries in a row that didn't get through: one that lasted a while starts the count again.
            if (_clipSince is { } since && since.Elapsed >= ClipSettled) _clipTries = 0;
            RetryClipSync(ClipRetry);
        }));
    }

    private void ClipSyncRefused(int generation, Passthrough.Core.Shell.ShellError reason)
    {
        if (generation != _clipGeneration) return;
        _clipShell = null;
        switch (reason)
        {
            // The view's start hadn't reached it yet: ask again shortly.
            case Passthrough.Core.Shell.ShellError.NoScreenView: RetryClipSync(ClipRetryNoView); break;
            case Passthrough.Core.Shell.ShellError.ClipSyncOff:
                Toast($"{_name} has clipboard sync turned off. Once it's on there, turn Sync clipboard off and on here.");
                break;
            case Passthrough.Core.Shell.ShellError.ClipSyncUnavailable:
                Toast($"{_name} can't share its clipboard right now. Send clipboard and Copy from Mac still work.");
                break;
            case Passthrough.Core.Shell.ShellError.NotAllowed or Passthrough.Core.Shell.ShellError.ScreenNotAllowed or Passthrough.Core.Shell.ShellError.ScreenOnly:
                Toast($"{_name} doesn't let this PC share its clipboard. Send clipboard and Copy from Mac still work.");
                break;
            default:
                // An older build knows no clipSync and answers bad_request.
                Toast($"{_name} can't sync the clipboard (update Passthrough there). Send clipboard and Copy from Mac still work.");
                break;
        }
    }

    private void RetryClipSync(TimeSpan after)
    {
        if (!_clipOn || _phase != Phase.Live) return;
        if (_clipTries >= ClipTriesInARow)
        {
            Toast($"Clipboard sync with {_name} stopped. Turn Sync clipboard off and on to try again.");
            return;
        }
        var generation = _clipGeneration;
        _ = Task.Delay(after).ContinueWith(_ => OnUi(() => { if (generation == _clipGeneration) StartClipSync(); }), TaskScheduler.Default);
    }

    /// <summary>Ends the sync and its connection. With <paramref name="forget"/> (turned off) what was received goes too.</summary>
    private void StopClipSync(bool forget)
    {
        _clipGeneration++;
        _clipShell?.Disconnect();
        _clipShell = null;
        _clipViewer?.Stop(forget);
        _clipActive = false;
        ShowClipButtons();
        if (_clipHeld) ShowClipStatus(null);
    }

    /// <summary>While sync runs, Ctrl+C and ⌘V do the work: the two buttons give way to it.</summary>
    private void ShowClipButtons()
    {
        var visibility = _clipActive ? Visibility.Collapsed : Visibility.Visible;
        if (_sendButton is not null) _sendButton.Visibility = visibility;
        if (_copyButton is not null) _copyButton.Visibility = visibility;
    }

    /// <summary>
    /// What sync is doing, beside the subtitle: a line that stays until replaced (with its buttons, when it asks
    /// something), or one that goes after a few seconds.
    /// </summary>
    private void ShowClipStatus(ClipStatus? status)
    {
        if (_phase == Phase.Closed) return;
        _clipActions.Children.Clear();
        if (status is null)
        {
            if (_clipHeld) { _toastId++; SetToast(""); }
            _clipHeld = false;
            return;
        }
        _clipHeld = status.Hold;
        if (!status.Hold) { Toast(status.Text); return; }
        _toastId++;
        SetToast(status.Text);
        foreach (var action in status.Actions)
        {
            var button = new Button { Content = action.Label, Padding = new Thickness(10, 2, 10, 2) };
            AutomationName(button, action.Label);
            button.Click += (_, _) =>
            {
                // Answered: the question goes at once; what happens next says itself.
                _clipActions.Children.Clear();
                _toastId++;
                SetToast("");
                _clipHeld = false;
                action.Run();
                _typing.Focus(FocusState.Programmatic);
            };
            _clipActions.Children.Add(button);
        }
    }

    private void OnDragOver(object sender, DragEventArgs e)
    {
        var point = e.GetPosition(_stage);
        var inside = ScreenFrame.StreamPoint(point.X, point.Y, PictureRect()).Inside;
        // Taken whenever the picture is live, so a drop while sync isn't running can say why nothing went.
        e.AcceptedOperation = _phase == Phase.Live && inside && e.DataView.Contains(StandardDataFormats.StorageItems)
            ? DataPackageOperation.Copy : DataPackageOperation.None;
        if (e.AcceptedOperation == DataPackageOperation.Copy) e.DragUIOverride.Caption = _clipActive ? $"Drop on {_name}" : "Clipboard sync isn't running";
        e.Handled = true;
    }

    private async void OnDrop(object sender, DragEventArgs e)
    {
        try
        {
            if (!e.DataView.Contains(StandardDataFormats.StorageItems)) return;
            if (!_clipActive || _clipViewer is not { } viewer)
            {
                Toast(_clipOn ? $"Clipboard sync with {_name} isn't running, so files can't go there." : $"Turn on Sync clipboard to drop files on {_name}.");
                return;
            }
            var point = e.GetPosition(_stage);
            var at = ScreenFrame.StreamPoint(point.X, point.Y, PictureRect());
            if (!at.Inside) return;
            var deferral = e.GetDeferral();
            List<string> paths;
            try { paths = [.. (await e.DataView.GetStorageItemsAsync()).Select(i => i.Path).Where(p => !string.IsNullOrEmpty(p))]; }
            finally { deferral.Complete(); }
            if (paths.Count == 0) { Toast("Those can't be sent: only files and folders on this PC."); return; }
            viewer.Drop(paths, (ushort)Math.Round(Math.Clamp(at.X, 0, 1) * 65535), (ushort)Math.Round(Math.Clamp(at.Y, 0, 1) * 65535));
        }
        catch (Exception x) when (x is COMException or UnauthorizedAccessException or InvalidOperationException) { Toast("Those files couldn't be read."); }
        catch (Exception x) when (x is not OutOfMemoryException) { LogFile.Error(x); LogFile.Flush(); } // async void: anything left here would end the app
    }

    private void Status(string text, bool retry, string retryText = "Try again")
    {
        _statusText.Text = text;
        _retry.Content = retryText;
        AutomationName(_retry, retryText);
        _retry.Visibility = retry ? Visibility.Visible : Visibility.Collapsed;
        _status.Visibility = Visibility.Visible;
    }

    private void HideStatus() => _status.Visibility = Visibility.Collapsed;

    private void ShowSubtitle()
    {
        if (_phase != Phase.Live) { _subtitle.Text = ""; return; }
        var path = _path switch { ShellPath.Relay => "through a relay", ShellPath.Direct => "direct", _ => null };
        var parts = new List<string>();
        if (_active) parts.Add($"Keys go to {_name}");
        if (path is not null) parts.Add(path);
        if (_viewers.Count > 0) parts.Add($"{string.Join(", ", _viewers.Select(ScreenFrame.Clean))} {(_viewers.Count == 1 ? "is" : "are")} also viewing");
        if (_active) parts.Add("The Windows key stays on this PC");
        _subtitle.Text = string.Join(" · ", parts);
    }

    private async void Toast(string text)
    {
        // A passing line replaces a held one, and its buttons with it.
        _clipActions.Children.Clear();
        _clipHeld = false;
        var id = ++_toastId;
        SetToast(text);
        await Task.Delay(TimeSpan.FromSeconds(4));
        if (id == _toastId) SetToast("");
    }

    // MARK: IScreenView

    public void Sized(int width, int height)
    {
        _streamWidth = width;
        _streamHeight = height;
        if (_sized) return;
        _sized = true;
        if (_fit) return; // the stream follows the window, not the other way round
        // First size: the stream's shape fitted in 80% of the work area.
        var work = DisplayArea.GetFromWindowId(AppWindow.Id, DisplayAreaFallback.Nearest).WorkArea;
        var barHeight = (int)(44 * NativeMethods.DpiOf(Win32Interop.GetWindowFromWindowId(AppWindow.Id)) / 96.0);
        var fit = Math.Min(work.Width * 0.8 / width, (work.Height * 0.8 - barHeight) / height);
        var w = (int)(width * fit);
        var h = (int)(height * fit) + barHeight;
        if (AppWindow.Presenter is OverlappedPresenter { State: OverlappedPresenterState.Restored })
            AppWindow.MoveAndResize(new RectInt32(work.X + (work.Width - w) / 2, work.Y + (work.Height - h) / 2, w, h));
    }

    public void PictureReady()
    {
        if (_pipeline?.TakePicture() is not { } picture) return;
        using (picture)
        {
            if (_bitmap is null || _bitmap.PixelWidth != picture.Width || _bitmap.PixelHeight != picture.Height)
            {
                _bitmap = new WriteableBitmap(picture.Width, picture.Height);
                _picture.Source = _bitmap;
            }
            picture.Bgra.CopyTo(0, _bitmap.PixelBuffer, 0, picture.Length);
            _bitmap.Invalidate();
            _pipeline?.Shown(picture);
        }
    }

    public void Cursor(double x, double y, bool visible)
    {
        _remotePointer = (x, y, visible);
        PlacePointer();
    }

    public async void CursorShape(int width, int height, int hotX, int hotY, byte[] png)
    {
        try
        {
            using var stream = new InMemoryRandomAccessStream();
            await stream.WriteAsync(png.AsBuffer());
            stream.Seek(0);
            // The PNG decoder only, and its real size checked before any pixel is asked for (Core read it from the header too).
            var decoder = await BitmapDecoder.CreateAsync(BitmapDecoder.PngDecoderId, stream);
            if (decoder.PixelWidth is < 1 or > ScreenVideoClient.MaxCursorSide || decoder.PixelHeight is < 1 or > ScreenVideoClient.MaxCursorSide) return;
            using var bitmap = await decoder.GetSoftwareBitmapAsync(BitmapPixelFormat.Bgra8, BitmapAlphaMode.Premultiplied);
            var source = new SoftwareBitmapSource();
            await source.SetBitmapAsync(bitmap);
            _pointer.Source = source;
            _shape = (width, height, hotX, hotY);
            PlacePointer();
        }
        catch (Exception e) when (e is COMException or ArgumentException or InvalidOperationException) { } // the last shape stays
        catch (Exception e) when (e is not OutOfMemoryException) { LogFile.Error(e); LogFile.Flush(); } // async void: anything left here would end the app
    }

    public void Viewers(IReadOnlyList<string> names)
    {
        _viewers = names;
        ShowSubtitle();
    }

    public void Fitted(ScreenFit fit)
    {
        _lastFitted = fit;
        if (!_fit || fit == ScreenFit.Device) return;
        // Asked for a display in this window's shape and told the Mac's own: a refusal (another view has the one it can
        // make, or macOS wouldn't) only if that is still the answer in a moment, not the answer to an earlier ask.
        _fitRefused ??= new DispatcherQueueTimerWrapper(_ui, RefusedAfter, () =>
        {
            if (!_fit || _lastFitted != ScreenFit.Mac || _phase != Phase.Live) return;
            // The choice is kept for next time; this view shows what it was given, and asks for it at full size.
            _fit = false;
            _fitButton.IsChecked = false;
            _client?.Relayout(Layout());
            Toast($"{_name} couldn't make a display for this window. Showing its own.");
        });
        _fitRefused.Restart();
    }

    public void MovedAway(string to)
    {
        if (_phase != Phase.Live) return;
        Fail($"{ScreenFrame.Clean(to)} took over this view of {_name}'s screen.");
    }

    public void Copied(ScreenCopyResult result)
    {
        switch (result)
        {
            case ScreenCopyResult.Text t:
                var package = new DataPackage();
                package.SetText(t.Value);
                try
                {
                    Clipboard.SetContentWithOptions(package, new ClipboardContentOptions { IsRoamable = false, IsAllowedInHistory = true });
                    Toast("Copied from the Mac.");
                }
                catch (COMException) { Toast("This PC's clipboard is busy. Try again."); }
                break;
            case ScreenCopyResult.TooLong: Toast("That's too much text to copy."); break;
            case ScreenCopyResult.NotText: Toast("What was copied isn't text."); break;
            default: Toast("Nothing was copied."); break;
        }
    }

    public void StreamClosed(Exception? error)
    {
        if (_phase != Phase.Live) return;
        switch (error)
        {
            case null: return;
            case DecodeException: Fail("This PC couldn't decode the picture."); break;
            case MalformedStreamException:
                LogFile.Write($"screen: malformed stream ({error.Message})");
                Fail($"The picture from {_name} couldn't be shown.");
                break;
            default:
                StopStream();
                Lost();
                break;
        }
    }

    // MARK: Pointer and wheel

    private (double X, double Y, double Width, double Height) PictureRect() =>
        ScreenFrame.Picture(_stage.ActualWidth, _stage.ActualHeight, _streamWidth, _streamHeight);

    private static byte Buttons(PointerPointProperties p) =>
        (byte)((p.IsLeftButtonPressed ? 1 : 0) | (p.IsMiddleButtonPressed ? 2 : 0) | (p.IsRightButtonPressed ? 4 : 0));

    private void OnPointerPressed(object sender, PointerRoutedEventArgs e)
    {
        if (_client is null) return;
        var point = e.GetCurrentPoint(_stage);
        var at = ScreenFrame.StreamPoint(point.Position.X, point.Position.Y, PictureRect());
        _typing.Focus(FocusState.Pointer);
        // A press outside the picture is not a click.
        if (!at.Inside && _buttons == 0) return;
        var buttons = e.Pointer.PointerDeviceType == PointerDeviceType.Mouse ? Buttons(point.Properties) : (byte)1;
        _buttons = buttons;
        _stage.CapturePointer(e.Pointer);
        _client.Pointer(at.X, at.Y, buttons);
        e.Handled = true;
    }

    private void OnPointerMoved(object sender, PointerRoutedEventArgs e)
    {
        var point = e.GetCurrentPoint(_stage);
        var rect = PictureRect();
        var at = ScreenFrame.StreamPoint(point.Position.X, point.Position.Y, rect);
        _localPointer = at.Inside ? (point.Position.X, point.Position.Y) : null;
        // Full screen's bar comes down when the pointer touches the top edge.
        if (_fullScreen && point.Position.Y <= 2) RevealBar();
        PlacePointer();
        if (_client is null) return;
        var buttons = _buttons == 0 ? (byte)0 : e.Pointer.PointerDeviceType == PointerDeviceType.Mouse ? Buttons(point.Properties) : (byte)1;
        // Moves off the picture only while dragging; at most one every 8 ms, but a button change always.
        if (!at.Inside && _buttons == 0) return;
        if (buttons == _buttons && _sinceMove.ElapsedMilliseconds < 8) return;
        _sinceMove.Restart();
        _buttons = buttons;
        _client.Pointer(at.X, at.Y, buttons);
    }

    private void OnPointerReleased(object sender, PointerRoutedEventArgs e)
    {
        if (_client is null || _buttons == 0) return;
        var point = e.GetCurrentPoint(_stage);
        var at = ScreenFrame.StreamPoint(point.Position.X, point.Position.Y, PictureRect());
        _buttons = e.Pointer.PointerDeviceType == PointerDeviceType.Mouse ? Buttons(point.Properties) : (byte)0;
        _client.Pointer(at.X, at.Y, _buttons);
        if (_buttons == 0) _stage.ReleasePointerCapture(e.Pointer);
        e.Handled = true;
    }

    /// <summary>On losing capture or focus every held button is let go, in one message.</summary>
    private void ReleaseButtons()
    {
        if (_buttons == 0 || _client is null) { _buttons = 0; return; }
        _buttons = 0;
        var p = _localPointer is { } l ? ScreenFrame.StreamPoint(l.X, l.Y, PictureRect()) : (0.5, 0.5, false);
        _client.Pointer(p.Item1, p.Item2, 0);
    }

    private void OnWheel(object sender, PointerRoutedEventArgs e)
    {
        if (_client is null) return;
        var point = e.GetCurrentPoint(_stage);
        var rect = PictureRect();
        var at = ScreenFrame.StreamPoint(point.Position.X, point.Position.Y, rect);
        if (!at.Inside) return;
        e.Handled = true;
        var delta = point.Properties.MouseWheelDelta;
        if (e.KeyModifiers.HasFlag(global::Windows.System.VirtualKeyModifiers.Control))
        {
            // Ctrl+wheel, which is also how Windows delivers a touchpad pinch: the Mac's magnify.
            if (!_pinching) { _client.Gesture(ScreenGesture.Magnify, ScreenGesturePhase.Began, 0); _pinching = true; }
            _client.Gesture(ScreenGesture.Magnify, ScreenGesturePhase.Changed, delta / 1200.0);
            _pinchEnd ??= new DispatcherQueueTimerWrapper(_ui, ScrollScale.Pause, () =>
            {
                _pinching = false;
                _client?.Gesture(ScreenGesture.Magnify, ScreenGesturePhase.Ended, 0);
            });
            _pinchEnd.Restart();
            return;
        }
        _client.Pointer(at.X, at.Y, _buttons);
        var perView = _streamWidth > 0 ? _streamWidth / Math.Max(rect.Width, 1) : 1;
        var (dx, dy) = _scroll.Wheel(delta, point.Properties.IsHorizontalMouseWheel, perView, Stopwatch.GetTimestamp());
        _client.Scroll(dx, dy);
    }

    /// <summary>The Mac's pointer shape where this PC's pointer is (it leads the echo), else where the Mac says.</summary>
    private void PlacePointer()
    {
        PlaceMacPointer();
        // One pointer, not two: while the Mac's is drawn where this PC's is, this PC's own is hidden.
        ShowOwnCursor(!(_active && _localPointer is not null && _pointer.Visibility == Visibility.Visible));
    }

    private bool _ownCursorHidden;
    private InputCursor? _blankCursor;
    private bool _blankCursorTried;

    /// <summary>
    /// Hides or shows this PC's pointer over the picture. WinUI takes its pointer input without window messages, so the
    /// shape can't be taken away the Win32 way (ShowCursor, or answering WM_SETCURSOR, do nothing here): the picture is
    /// given a pointer shape of its own that draws nothing, from Assetslank-cursor.dll (WinUI has no "none").
    /// </summary>
    private void ShowOwnCursor(bool show)
    {
        if (show != _ownCursorHidden) return;
        _ownCursorHidden = !show;
        _stage.Show(show ? null : BlankCursor());
    }

    private InputCursor? BlankCursor()
    {
        if (_blankCursorTried) return _blankCursor;
        _blankCursorTried = true;
        var module = Path.Combine(AppContext.BaseDirectory, "Assets", "blank-cursor.dll");
        try
        {
            // WinUI finds the module among those already loaded (it doesn't load it: asked for one that isn't, it
            // answers "resource name not found"), so it is loaded here first. It holds one cursor and no code.
            if (LoadLibraryExW(module, IntPtr.Zero, 0) == IntPtr.Zero) throw new IOException($"error {Marshal.GetLastWin32Error()} loading it");
            _blankCursor = InputDesktopResourceCursor.CreateFromModule(module, 1);
        }
        catch (Exception e) when (e is COMException or ArgumentException or IOException or UnauthorizedAccessException)
        {
            LogFile.Write($"screen: this PC's pointer stays visible over the picture (the blank pointer didn't load: {e.GetType().Name} {e.HResult:X8} {e.Message})");
        }
        return _blankCursor;
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr LoadLibraryExW(string name, IntPtr file, uint flags);

    /// <summary>The stage, with the one thing a Grid keeps to itself: the pointer shape shown over it.</summary>
    private sealed class PointerStage : Grid
    {
        public void Show(InputCursor? cursor) => ProtectedCursor = cursor;
    }

    private void PlaceMacPointer()
    {
        var rect = PictureRect();
        if (_shape is not { } shape || _streamWidth == 0 || _remotePointer is { Visible: false } || _pointer.Source is null)
        {
            _pointer.Visibility = Visibility.Collapsed;
            return;
        }
        (double X, double Y) tip;
        if (_localPointer is { } local) tip = local;
        else if (_remotePointer is { } remote) tip = (rect.X + remote.X * rect.Width, rect.Y + remote.Y * rect.Height);
        else { _pointer.Visibility = Visibility.Collapsed; return; }
        var scale = rect.Width / _streamWidth;
        _pointer.Width = shape.Width * scale;
        _pointer.Height = shape.Height * scale;
        Canvas.SetLeft(_pointer, tip.X - shape.HotX * scale);
        Canvas.SetTop(_pointer, tip.Y - shape.HotY * scale);
        _pointer.Visibility = Visibility.Visible;
        // The input method's candidate window opens at the pointer.
        Canvas.SetLeft(_typing, tip.X);
        Canvas.SetTop(_typing, tip.Y);
    }

    // MARK: Keys and text

    private void OnKeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (_client is null) return;
        var vk = (int)e.Key;
        var held = Keyboard.Held();
        if (vk == ScreenKeys.VkCancel && held.HasFlag(PcModifiers.Ctrl) && held.HasFlag(PcModifiers.Alt) || vk == ScreenKeys.VkPause && held.HasFlag(PcModifiers.Ctrl) && held.HasFlag(PcModifiers.Alt))
        {
            ToggleFullScreen();
            e.Handled = true;
            return;
        }
        var action = ScreenKeys.Down(vk, held, Keyboard.Unshifted(vk), ctrlIsCommand: _ctrlIsCommand, altGr: Keyboard.AltGr(), composing: _composing);
        switch (action)
        {
            case ScreenKeyAction.Key k: _client.Key(k.Keysym, k.Modifiers); e.Handled = true; break;
            case ScreenKeyAction.Function f: _client.Function(f.Down); e.Handled = true; break;
            case ScreenKeyAction.Nothing: e.Handled = true; break;
            case ScreenKeyAction.Local: ReleaseFunction(); break;
        }
    }

    private void OnKeyUp(object sender, KeyRoutedEventArgs e)
    {
        if (_client is null) return;
        if (ScreenKeys.Up((int)e.Key) is ScreenKeyAction.Function f) { _client.Function(f.Down); e.Handled = true; }
    }

    private void ReleaseFunction() => _client?.Function(false);

    /// <summary>Committed text goes to the Mac and the box is emptied; a composition stays here until it ends.</summary>
    private void OnTyped(object? sender, TextChangedEventArgs? e)
    {
        if (_composing || _typing.Text.Length == 0) return;
        var text = _typing.Text;
        _typing.Text = "";
        _client?.Text(text);
    }

    // MARK: Clipboard and full screen

    private async Task SendClipboardAsync()
    {
        if (_client is null) return;
        try
        {
            var content = Clipboard.GetContent();
            if (!content.Contains(StandardDataFormats.Text)) { Toast("There's no text on the clipboard."); return; }
            var text = await content.GetTextAsync();
            if (string.IsNullOrEmpty(text)) { Toast("There's no text on the clipboard."); return; }
            Toast(_client.Clipboard(text) ? "Sent to the Mac's clipboard." : "That's too much text to send (64 KB at most).");
        }
        catch (COMException) { Toast("This PC's clipboard is busy. Try again."); }
        _typing.Focus(FocusState.Programmatic);
    }

    private DispatcherQueueTimerWrapper? _taskbarBehind;

    /// <summary>
    /// In full screen and in front, the taskbar on this window's monitor goes behind it; in full screen but with another
    /// window in front, the taskbar is where it always is, so that window has it.
    /// </summary>
    private void PlaceTaskbar()
    {
        if (!_fullScreen || _phase == Phase.Closed) return;
        if (_active) TaskbarKeeper.SendBehind(Win32Interop.GetWindowFromWindowId(AppWindow.Id));
        else TaskbarKeeper.BringBack();
    }

    /// <summary>
    /// Full screen and back. In full screen the toolbar goes, the picture has the whole monitor, and the Mac is asked
    /// for a display in the monitor's shape whatever Fit to window says; leaving it, Fit to window's own choice holds again.
    /// </summary>
    private void ToggleFullScreen()
    {
        var entering = AppWindow.Presenter.Kind != AppWindowPresenterKind.FullScreen;
        AppWindow.SetPresenter(entering ? AppWindowPresenterKind.FullScreen : AppWindowPresenterKind.Overlapped);
        _fullScreen = entering;
        // Windows takes its taskbar off the top for a full-screen window; the keeper mustn't put it back over the picture.
        if (entering) TaskbarKeeper.FullScreenBegan(); else TaskbarKeeper.FullScreenEnded();
        // And Windows is told outright: left to notice by itself, it does so only when the window next comes forward,
        // and the taskbar stays over the picture until then. Once the window has its new size, so it is taken at its word.
        var window = Win32Interop.GetWindowFromWindowId(AppWindow.Id);
        _ui.TryEnqueue(Microsoft.UI.Dispatching.DispatcherQueuePriority.Low, () => TaskbarKeeper.MarkFullScreen(window, _fullScreen));
        // Telling it isn't enough on every Windows: the taskbar still sat over the picture until the window next came
        // forward. So it is put behind this window here, once the window has its full-screen size.
        if (entering)
        {
            _taskbarBehind ??= new DispatcherQueueTimerWrapper(_ui, TimeSpan.FromMilliseconds(200), PlaceTaskbar);
            _taskbarBehind.Restart();
        }
        else TaskbarKeeper.BringBack();
        if (_toolbar is not null) _toolbar.Visibility = entering ? Visibility.Collapsed : Visibility.Visible;
        // What clipboard sync says, and its buttons, are shown wherever there is a bar to show them in.
        var (from, to) = entering ? (_toolbarStatus, _connectionStatus) : (_connectionStatus, _toolbarStatus);
        foreach (var element in new UIElement[] { _toast, _clipActions })
        {
            from?.Children.Remove(element);
            if (to is not null && !to.Children.Contains(element)) to.Children.Add(element);
        }
        if (entering)
        {
            // Shown for a moment, so it's known to be there; the stage's new size asks the Mac for a display to match.
            RevealBar();
            Refit();
        }
        else
        {
            _connectionBar.Visibility = Visibility.Collapsed;
            Refit();
        }
        _typing.Focus(FocusState.Programmatic);
    }

    /// <summary>A one-shot timer that can be pushed back.</summary>
    private sealed class DispatcherQueueTimerWrapper
    {
        private readonly Microsoft.UI.Dispatching.DispatcherQueueTimer _timer;

        public DispatcherQueueTimerWrapper(Microsoft.UI.Dispatching.DispatcherQueue queue, TimeSpan after, Action fire)
        {
            _timer = queue.CreateTimer();
            _timer.Interval = after;
            _timer.IsRepeating = false;
            _timer.Tick += (_, _) => fire();
        }

        public void Restart()
        {
            _timer.Stop();
            _timer.Start();
        }
    }

    /// <summary>This PC's keyboard state, read where the key event is handled.</summary>
    private static class Keyboard
    {
        private const int VkLControl = 0xA2, VkRMenu = 0xA5;

        public static PcModifiers Held()
        {
            var m = PcModifiers.None;
            if (Down(ScreenKeys.VkShift)) m |= PcModifiers.Shift;
            if (Down(ScreenKeys.VkControl)) m |= PcModifiers.Ctrl;
            if (Down(ScreenKeys.VkMenu)) m |= PcModifiers.Alt;
            if (Down(ScreenKeys.VkLWin) || Down(ScreenKeys.VkRWin)) m |= PcModifiers.Windows;
            return m;
        }

        /// <summary>Right Alt with the left Ctrl Windows adds for it: this layout's AltGr.</summary>
        public static bool AltGr() => Down(VkRMenu) && Down(VkLControl);

        /// <summary>The character the key types unshifted on this PC's layout (never ToUnicodeEx, which disturbs dead keys).</summary>
        public static char Unshifted(int vk)
        {
            var c = MapVirtualKeyExW((uint)vk, 2, GetKeyboardLayout(0)) & 0x7FFF; // the high bit marks a dead key
            return (char)c;
        }

        private static bool Down(int vk) => (GetKeyState(vk) & 0x8000) != 0;

        [DllImport("user32.dll")] private static extern short GetKeyState(int vk);
        [DllImport("user32.dll")] private static extern uint MapVirtualKeyExW(uint code, uint mapType, IntPtr layout);
        [DllImport("user32.dll")] private static extern IntPtr GetKeyboardLayout(uint thread);
    }
}
