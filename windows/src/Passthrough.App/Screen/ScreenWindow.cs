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
/// committed text through a hidden text box (so dead keys and input methods compose here), Send clipboard and Copy
/// from Mac, full screen. A lost connection dims the last picture and redials at 0, 2 and 5 s without asking again.
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

    private readonly Grid _stage = new() { Background = new SolidColorBrush(Colors.Black) };
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
    private bool _pinching;
    private int _toastId;

    public ScreenWindow(ReachableComputer computer, IComputerIdentity identity, Func<Task<bool>> confirm)
    {
        _computer = computer;
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
        Closed += (_, _) => Stop(Phase.Closed);
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

        var bar = new Grid { Padding = new Thickness(12, 6, 12, 6), ColumnSpacing = 8 };
        bar.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        bar.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        bar.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var left = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 12 };
        left.Children.Add(_subtitle);
        left.Children.Add(_toast);
        bar.Children.Add(left);
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
        buttons.Children.Add(send);
        buttons.Children.Add(copy);
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
        _stage.SizeChanged += (_, _) => PlacePointer();
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
        return root;
    }

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
                    _ui.TryEnqueue(() => { if (generation == _generation) _path = ready.Path; });
                    shell!.RequestScreen(video: true);
                    break;
                case ShellClientEvent.Screen screen:
                    screenGiven = true;
                    var codecs = SafeCodecs(); // probed off the UI thread
                    _ui.TryEnqueue(() => StartStream(generation, screen, codecs));
                    break;
                case ShellClientEvent.Failed failed:
                    _ui.TryEnqueue(() => { if (generation == _generation) Fail(ScreenFrame.Refusal(failed.Reason, _name)); });
                    shell!.Disconnect();
                    break;
                case ShellClientEvent.Disconnected d when !screenGiven:
                    LogFile.Write($"screen: no connection ({d.Error?.GetType().Name ?? "clean"})");
                    _ui.TryEnqueue(() => { if (generation == _generation && _phase is Phase.Connecting or Phase.Reconnecting) Lost(); });
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
        var sides = DisplayArea.FindAll().Select(d => Math.Max(d.OuterBounds.Width, d.OuterBounds.Height));
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
    }

    private void Lost()
    {
        if (_redial < Redials.Length)
        {
            var delay = Redials[_redial++];
            _phase = Phase.Reconnecting;
            _picture.Opacity = 0.4;
            Status("Reconnecting…", retry: false);
            var generation = _generation;
            _ = Task.Delay(delay).ContinueWith(_ => _ui.TryEnqueue(() =>
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
    }

    private void Stop(Phase phase)
    {
        StopStream();
        _phase = phase;
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
        var id = ++_toastId;
        _toast.Text = text;
        await Task.Delay(TimeSpan.FromSeconds(4));
        if (id == _toastId) _toast.Text = "";
    }

    // MARK: IScreenView

    public void Sized(int width, int height)
    {
        _streamWidth = width;
        _streamHeight = height;
        if (_sized) return;
        _sized = true;
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
    }

    public void Viewers(IReadOnlyList<string> names)
    {
        _viewers = names;
        ShowSubtitle();
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
        var action = ScreenKeys.Down(vk, held, Keyboard.Unshifted(vk), ctrlIsCommand: false, altGr: Keyboard.AltGr(), composing: _composing);
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

    private void ToggleFullScreen()
    {
        AppWindow.SetPresenter(AppWindow.Presenter.Kind == AppWindowPresenterKind.FullScreen ? AppWindowPresenterKind.Overlapped : AppWindowPresenterKind.FullScreen);
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
