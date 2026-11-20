using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Passthrough.App.Platform;
using Windows.Graphics;

namespace Passthrough.App;

/// <summary>The tray flyout: a small borderless window above the taskbar that hides itself when it loses focus.</summary>
public sealed partial class FlyoutWindow : Window
{
    private const int WidthDip = 360;
    private const int HeightDip = 480;
    private const int MarginDip = 12;

    private readonly Action _openSettings;
    private readonly Action _quit;
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
            if (args.WindowActivationState == WindowActivationState.Deactivated) AppWindow.Hide();
        };
    }

    public SessionViewModel ViewModel { get; }

    /// <summary>Lets the window really close, for quitting.</summary>
    public void AllowClose() => _quitting = true;

    /// <summary>Places the window at the bottom right of the work area (above the taskbar) and brings it forward.</summary>
    public void ShowAtTray()
    {
        var scale = Content.XamlRoot?.RasterizationScale ?? 1.0;
        var width = (int)(WidthDip * scale);
        var height = (int)(HeightDip * scale);
        var margin = (int)(MarginDip * scale);
        var area = DisplayArea.GetFromWindowId(AppWindow.Id, DisplayAreaFallback.Primary).WorkArea;
        AppWindow.MoveAndResize(new RectInt32(
            area.X + area.Width - width - margin, area.Y + area.Height - height - margin, width, height));
        AppWindow.Show();
        Activate();
    }

    private async void OnPairClick(object sender, RoutedEventArgs e)
    {
        var row = (PhoneRow)((FrameworkElement)sender).DataContext;
        var code = row.Code.Trim();
        if (code.Length != 6 || !code.All(char.IsAsciiDigit)) return;
        row.Code = "";
        try { await ViewModel.SubmitCodeAsync(code); }
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
