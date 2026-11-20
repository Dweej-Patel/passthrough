using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Passthrough.App.Platform;
using Passthrough.Core.Desktop;
using Passthrough.Core.Presentation;
using Windows.Graphics;

namespace Passthrough.App;

/// <summary>
/// The tray flyout: a small borderless window above the taskbar that hides itself when it loses focus. Its size and
/// place come from Core's <see cref="FlyoutPlacement"/>, and the icon toggles it through <see cref="FlyoutToggle"/>.
/// </summary>
public sealed partial class FlyoutWindow : Window
{
    private readonly Action _openSettings;
    private readonly Action _quit;
    private readonly FlyoutToggle _toggle = new(TimeProvider.System);
    private bool _quitting;

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
            presenter.SetBorderAndTitleBar(hasBorder: true, hasTitleBar: false);
        }
        AppWindow.IsShownInSwitchers = false;
        AppWindow.Closing += (_, args) =>
        {
            // Closing hides: the window is reused until the app quits.
            if (_quitting) return;
            args.Cancel = true;
            AppWindow.Hide();
        };
        Activated += (_, args) =>
        {
            if (args.WindowActivationState != WindowActivationState.Deactivated || !AppWindow.IsVisible) return;
            AppWindow.Hide();
            _toggle.HiddenByDeactivation();
        };
    }

    public SessionViewModel ViewModel { get; }

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
    /// clicked), sized for that monitor's DPI, and brings it forward.
    /// </summary>
    private void ShowAtTray()
    {
        var cursor = NativeMethods.CursorPosition();
        var area = DisplayArea.GetFromPoint(new PointInt32(cursor.X, cursor.Y), DisplayAreaFallback.Primary).WorkArea;
        var scale = FlyoutPlacement.ScaleFromDpi(NativeMethods.DpiAt(cursor));
        var r = FlyoutPlacement.Place(new PixelRect(area.X, area.Y, area.Width, area.Height), scale);
        AppWindow.MoveAndResize(new RectInt32(r.X, r.Y, r.Width, r.Height));
        AppWindow.Show();
        Activate();
    }

    private async void OnPairClick(object sender, RoutedEventArgs e)
    {
        var row = (PhoneRow)((FrameworkElement)sender).DataContext;
        await SubmitAsync(row);
    }

    private async void OnCodeKeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (e.Key != Windows.System.VirtualKey.Enter) return;
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
