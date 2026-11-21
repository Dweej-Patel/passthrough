using Microsoft.UI;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Passthrough.App.Platform;
using Passthrough.Core.Desktop;
using Passthrough.Core.Presentation;
using Windows.Graphics;

namespace Passthrough.App;

/// <summary>
/// The tray flyout: a small borderless acrylic window above the taskbar, as tall as what it shows, that stays above
/// other windows and hides itself when it loses focus. Its size and place come from Core's
/// <see cref="FlyoutPlacement"/>, and the icon toggles it through <see cref="FlyoutToggle"/>.
/// </summary>
public sealed partial class FlyoutWindow : Window
{
    private readonly Action _openSettings;
    private readonly Action _quit;
    private readonly FlyoutToggle _toggle = new(TimeProvider.System);
    private bool _quitting;
    /// <summary>The work area the flyout was last opened in; it is fitted to it again when its content changes.</summary>
    private RectInt32 _area;
    /// <summary>The content's height when last measured, so the next opening starts at the right size.</summary>
    private int? _contentHeightDip;

    public FlyoutWindow(SessionViewModel viewModel, Action openSettings, Action quit)
    {
        ViewModel = viewModel;
        _openSettings = openSettings;
        _quit = quit;
        InitializeComponent();

        if (AppWindow.Presenter is OverlappedPresenter presenter)
        {
            presenter.IsResizable = false;
            presenter.IsMaximizable = false;
            presenter.IsMinimizable = false;
            // Above the other windows while it is up: it is gone as soon as it loses focus (see ShowAtTray).
            presenter.IsAlwaysOnTop = true;
            presenter.SetBorderAndTitleBar(hasBorder: true, hasTitleBar: false);
        }
        AppWindow.IsShownInSwitchers = false;
        AppWindow.SetIcon(AppIcon.Path);
        // What the Windows 11 tray flyouts are made of; where it isn't supported the window keeps its plain background.
        SystemBackdrop = new DesktopAcrylicBackdrop();
        // A phone arriving, a code box or a hint appearing changes how tall the content is.
        Body.SizeChanged += (_, _) => FitIfOpen();
        HintsBox.SizeChanged += (_, _) => FitIfOpen();
        ViewModel.PropertyChanged += (_, _) => DispatcherQueue.TryEnqueue(FitIfOpen);
        AppWindow.Closing += (_, args) =>
        {
            // Closing hides: the window is reused until the app quits.
            if (_quitting) return;
            args.Cancel = true;
            AppWindow.Hide();
        };
        Activated += (_, args) =>
        {
            if (args.WindowActivationState != WindowActivationState.Deactivated)
            {
                // The bindings first run when the window is first activated, which can collapse parts of it.
                DispatcherQueue.TryEnqueue(FitIfOpen);
                return;
            }
            if (!AppWindow.IsVisible) return;
            AppWindow.Hide();
            _toggle.HiddenByDeactivation();
        };
    }

    public SessionViewModel ViewModel { get; }

    private async void OnNoticeOk(object sender, RoutedEventArgs e) => await Answer(sender, act: false);

    private async void OnNoticeAction(object sender, RoutedEventArgs e) => await Answer(sender, act: true);

    private async Task Answer(object sender, bool act)
    {
        if (((FrameworkElement)sender).DataContext is not NoticeRow row || ViewModel.AnswerNotice is not { } answer) return;
        try { await answer(row.Notice, act); }
        catch (Exception ex) { Platform.LogFile.Error(ex); }
    }

    /// <summary>Lets the window really close, for quitting.</summary>
    public void AllowClose() => _quitting = true;

    /// <summary>The tray icon was clicked: open the flyout, or close it if it is open (or was just closed by that click).</summary>
    public void ToggleFromTray()
    {
        if (_toggle.ShouldShowOnClick(AppWindow.IsVisible)) ShowAtTray();
        else AppWindow.Hide();
    }

    /// <summary>
    /// Places the window at the bottom right of the work area of the monitor under the cursor (the one whose taskbar was
    /// clicked), sized for that monitor's DPI and for its content, and brings it in front of the other windows. The
    /// window is moved onto that monitor first, so the DPI read from its own handle is that monitor's; it is sized after
    /// that move, so a size Windows suggests when the DPI changes (WM_DPICHANGED, which WinUI applies) is replaced by
    /// this one.
    /// </summary>
    private void ShowAtTray()
    {
        var cursor = NativeMethods.CursorPosition();
        _area = DisplayArea.GetFromPoint(new PointInt32(cursor.X, cursor.Y), DisplayAreaFallback.Primary).WorkArea;
        AppWindow.Move(new PointInt32(_area.X, _area.Y));
        Place(_contentHeightDip);
        if (AppWindow.Presenter is OverlappedPresenter shown) shown.IsAlwaysOnTop = true;
        AppWindow.Show();
        // Laid out now, so the height is right before the first frame is drawn.
        Root.UpdateLayout();
        Fit();
        Activate();
        // It hides when it loses focus, so it may only stay above the other windows if it got the focus. When Windows
        // refuses that (an elevated or hung app is in front), it is an ordinary window that the icon closes.
        var front = NativeMethods.BringToFront(Win32Interop.GetWindowFromWindowId(AppWindow.Id));
        if (AppWindow.Presenter is OverlappedPresenter presenter) presenter.IsAlwaysOnTop = front;
    }

    private void FitIfOpen()
    {
        // Layout and view-model callbacks can still arrive once the window has been closed for quitting.
        if (!_quitting && AppWindow.IsVisible) Fit();
    }

    /// <summary>Makes the window as tall as its content wants at the window's width (the list scrolls past the limit).</summary>
    private void Fit()
    {
        var scale = Scale();
        var chrome = AppWindow.Size.Height - AppWindow.ClientSize.Height;
        Root.Measure(new global::Windows.Foundation.Size(AppWindow.ClientSize.Width / scale, double.PositiveInfinity));
        var height = (int)Math.Ceiling(Root.DesiredSize.Height + chrome / scale);
        // That measure was a question, not the layout: have the next pass measure for the real size again.
        Root.InvalidateMeasure();
        if (height == _contentHeightDip) return;
        _contentHeightDip = height;
        Place(height);
    }

    private void Place(int? contentHeightDip)
    {
        var r = FlyoutPlacement.Place(new PixelRect(_area.X, _area.Y, _area.Width, _area.Height), Scale(), contentHeightDip);
        AppWindow.MoveAndResize(new RectInt32(r.X, r.Y, r.Width, r.Height));
    }

    private double Scale() => FlyoutPlacement.ScaleFromDpi(NativeMethods.DpiOf(Win32Interop.GetWindowFromWindowId(AppWindow.Id)));

    private async void OnPairClick(object sender, RoutedEventArgs e)
    {
        var row = (PhoneRow)((FrameworkElement)sender).DataContext;
        await SubmitAsync(row);
    }

    private async void OnCodeKeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (e.Key != global::Windows.System.VirtualKey.Enter) return;
        e.Handled = true;
        var box = (TextBox)sender;
        var row = (PhoneRow)box.DataContext;
        row.Code = box.Text; // the binding may not have pushed the last keystroke yet
        await SubmitAsync(row);
    }

    private async Task SubmitAsync(PhoneRow row)
    {
        try
        {
            if (!row.CanPair) return;
            if (PairingCode.Normalize(row.Code) is not { } code)
            {
                row.CodeProblem = PairingCode.NotSixDigits;
                return;
            }
            // Cleared only once the session took it for this row's phone; otherwise the code stays to try again.
            if (await ViewModel.SubmitCodeAsync(row, code) && PairingCode.Normalize(row.Code) == code) row.Code = "";
        }
        catch (Exception ex) { LogFile.Error(ex); }
    }

    private async void OnUseClick(object sender, RoutedEventArgs e)
    {
        var row = (PhoneRow)((FrameworkElement)sender).DataContext;
        try { await ViewModel.UseAsync(row.Id); }
        catch (Exception ex) { LogFile.Error(ex); }
    }

    private async void OnRetryClick(object sender, RoutedEventArgs e)
    {
        var row = (PhoneRow)((FrameworkElement)sender).DataContext;
        try { await ViewModel.RetryAsync(row.Id); }
        catch (Exception ex) { LogFile.Error(ex); }
    }

    private void OnSettingsClick(object sender, RoutedEventArgs e)
    {
        AppWindow.Hide();
        _openSettings();
    }

    private void OnQuitClick(object sender, RoutedEventArgs e) => _quit();
}
